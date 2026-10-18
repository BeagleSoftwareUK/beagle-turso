require "beagle/turso"
require "bigdecimal"
require "sequel/adapters/shared/sqlite"

module Sequel
  # Sequel adapter for the beagle-turso driver. SQL generation, schema parsing
  # and transactions come from Sequel's shared SQLite support; this file only
  # replaces the plumbing (connections, execution, value conversion) and
  # papers over the engine's differences from SQLite.
  module BeagleTurso
    FALSE_VALUES = (%w[0 false f no n].each(&:freeze) + [0]).freeze

    blob = Object.new
    def blob.call(s)
      Sequel::SQL::Blob.new(s.to_s)
    end

    boolean = Object.new
    def boolean.call(s)
      s = s.downcase if s.is_a?(String)
      !FALSE_VALUES.include?(s)
    end

    date = Object.new
    def date.call(s)
      case s
      when String then Sequel.string_to_date(s)
      when Integer then Date.jd(s)
      when Float then Date.jd(s.to_i)
      else raise Sequel::Error, "unhandled type when converting to date: #{s.inspect} (#{s.class.inspect})"
      end
    end

    integer = Object.new
    def integer.call(s)
      s.to_i
    end

    float = Object.new
    def float.call(s)
      s.to_f
    end

    numeric = Object.new
    def numeric.call(s)
      s = s.to_s unless s.is_a?(String)
      BigDecimal(s)
    rescue ArgumentError
      s
    end

    time = Object.new
    def time.call(s)
      case s
      when String then Sequel.string_to_time(s)
      when Integer then Sequel::SQLTime.create(s / 3600, (s % 3600) / 60, s % 60)
      when Float
        secs, frac = s.divmod(1)
        Sequel::SQLTime.create(secs / 3600, (secs % 3600) / 60, secs % 60, (frac * 1_000_000).round)
      else raise Sequel::Error, "unhandled type when converting to time: #{s.inspect} (#{s.class.inspect})"
      end
    end

    # Declared base type name (lowercase) -> converter. datetime/timestamp are
    # added per Database so Sequel's timezone settings apply.
    SQLITE_TYPES = {}
    {
      %w[date] => date,
      %w[time] => time,
      %w[bit bool boolean] => boolean,
      %w[integer smallint mediumint int bigint] => integer,
      %w[numeric decimal money] => numeric,
      %w[float double real dec fixed] + ["double precision"] => float,
      %w[blob] => blob
    }.each { |names, conv| names.each { |n| SQLITE_TYPES[n] = conv } }
    SQLITE_TYPES.freeze

    # Thread-safe retry count. Lives in an ivar of the Database, and a frozen
    # Database must still be able to count, so it can't be a plain Integer.
    class BusyCounter
      def initialize
        @mutex = Mutex.new
        @value = 0
      end

      def increment
        @mutex.synchronize { @value += 1 }
      end

      def value
        @mutex.synchronize { @value }
      end
    end
    private_constant :BusyCounter

    class Database < Sequel::Database
      include Sequel::SQLite::DatabaseMethods

      # The driver prefixes engine messages ("query failed: ..."); Sequel's
      # SQLite error regexps (some anchored at \A) expect the bare message.
      ENGINE_PREFIX = /\A(?:open failed|connect failed|query failed|sync failed|database is busy): /

      # Tables the Turso sync engine creates on a synced replica; never user tables.
      SYNC_ENGINE_TABLES = %w[turso_cdc turso_cdc_version turso_sync_last_change_id].freeze

      RETURNING_CLAUSE = /\bRETURNING\b/i

      # String literals, quoted identifiers, and comments: where the word
      # RETURNING is data, not syntax.
      NON_CODE = %r{'(?:[^']|'')*'|"(?:[^"]|"")*"|`(?:[^`]|``)*`|\[[^\]]*\]|--[^\n]*|/\*.*?\*/}m

      set_adapter_scheme :beagle_turso
      # The URL form: URI schemes can't contain "_" (see adapters/beagle-turso.rb).
      Sequel::ADAPTER_MAP[:"beagle-turso"] = self

      # Same path handling as Sequel's sqlite adapter: beagle-turso:///abs.db,
      # beagle-turso://./rel.db, beagle-turso:/ (memory).
      def self.uri_to_options(uri)
        database = if uri.host.nil?
          case uri.path
          when "/" then nil
          when nil then uri.opaque
          else uri.path
          end
        else
          "#{uri.host}#{uri.path}"
        end
        { database: database }
      end
      private_class_method :uri_to_options

      attr_reader :conversion_procs, :turso_database

      # One pooled connection. The replica itself is opened once, in
      # adapter_initialize, and shared by every connection.
      def connect(_server)
        conn = @turso_database.connect
        connection_pragmas.each { |s| log_connection_yield(s, conn) { conn.execute_batch(s) } }
        conn
      rescue Beagle::Turso::Error => e
        raise Sequel.convert_exception_class(e, Sequel::DatabaseConnectionError)
      end

      def disconnect_connection(conn)
        conn.close
      end

      # Closes pooled connections and the replica this Database opened. A
      # replica passed in as turso_database: belongs to the caller and is left
      # open. Idempotent.
      def close_replica
        disconnect
        @turso_database.close if @owns_turso_database && !@turso_database.closed?
        nil
      end

      # Row-returning SQL. Yields (and returns) [columns, decl_types, rows].
      def execute(sql, opts = OPTS)
        result = _execute(sql, opts) { |conn| conn.query_result_with_types(sql, []) }
        yield result if defined?(yield)
        result
      end

      def execute_dui(sql, opts = OPTS)
        _execute(sql, opts) { |conn| conn.execute(sql, []) }
      end

      # execute_batch runs every statement in sql. Retrying a batch after a
      # busy error could re-run a statement that already committed, so only a
      # single statement gets the busy retry; a batch runs once.
      def execute_ddl(sql, opts = OPTS)
        _execute(sql, opts, busy_retry: single_statement?(sql)) { |conn| conn.execute_batch(sql) }
        nil
      end

      # Returns the rowid of the last row inserted, or nil if none was.
      #
      # Not conn.last_insert_rowid: on a replica in MVCC journal mode with
      # change data capture on (every synced replica of a --tursodb remote)
      # the engine leaves the CDC change id there, so it is wrong
      # (tursodatabase/turso#9551). INSERT ... RETURNING is correct, so the
      # statement gets RETURNING rowid appended. rowid always exists: the
      # engine has no WITHOUT ROWID tables. Several rows (INSERT ... SELECT,
      # multi-row VALUES) return the last one, like SQLite's
      # last_insert_rowid; an insert that changed nothing (OR IGNORE, ON
      # CONFLICT DO NOTHING) returns nil. The logged SQL is the original. RETURNING
      # goes on its own line so a trailing -- comment (sql_comments) can't swallow it.
      #
      # An insert that already has RETURNING is run as is, and its first
      # column in the last row is the result. (Dataset#insert sends those
      # through fetch, and insert_select too, not through here.)
      #
      # Note: insert(select_ds) / INSERT ... SELECT materialises every
      # returned rowid just to take the last one.
      def execute_insert(sql, opts = OPTS)
        run_sql = with_returning_rowid(sql)
        _execute(sql, opts) do |conn|
          _, _, rows = conn.query_result_with_types(run_sql, [])
          rows.last&.first
        end
      end

      # SQLite stores timestamps as text, integers (unix time) or reals (julian day).
      def to_application_timestamp(s)
        case s
        when String then super
        when Integer then super(Time.at(s).to_s)
        when Float then super(DateTime.jd(s).to_s)
        else raise Sequel::Error, "unhandled type when converting to timestamp: #{s.inspect} (#{s.class.inspect})"
        end
      end

      # The engine checks a table's self-references row by row when dropping
      # it, so a self-referencing table with rows can't be dropped while
      # foreign keys are on (SQLite drops it). When nothing else could be
      # referencing the rows, drop it with foreign keys briefly off.
      def drop_table(*names)
        opts = names.last.is_a?(Hash) ? names.pop : OPTS
        names.each do |name|
          super(name, opts)
        rescue ForeignKeyConstraintViolation
          raise unless drop_self_referencing_table(name, opts)
        end
        nil
      end

      # Refused on a synced replica, see refuse_rename_when_synced.
      def rename_table(name, new_name)
        refuse_rename_when_synced("rename_table")
        super
      end

      # Sequel's check sends SELECT NULL through connection_execute_method
      # (execute_batch), which rejects any statement that returns a row.
      def valid_connection?(conn)
        sql = valid_connection_sql
        log_connection_yield(sql, conn) { conn.query(sql, []) }
        true
      rescue Sequel::DatabaseError, *database_error_classes
        false
      end

      def freeze
        @conversion_procs.freeze
        super
      end

      private

      # True if it dropped the table. PRAGMA foreign_keys is per connection and
      # ignored inside a transaction, so this needs to own the connection.
      def drop_self_referencing_table(name, opts)
        synchronize(opts[:server]) do |conn|
          return false if _trans(conn) || !self_referencing_only?(name)

          execute_ddl("PRAGMA foreign_keys = 0", opts)
          begin
            execute_ddl(drop_table_sql(name, opts), opts)
          ensure
            execute_ddl("PRAGMA foreign_keys = 1", opts)
          end
          remove_cached_schema(name)
          true
        end
      end

      # The table references itself, and no other table with rows references it.
      def self_referencing_only?(name)
        table = name.to_s
        return false unless foreign_key_list(name).any? { |fk| fk[:table].to_s == table }

        tables.reject { |t| t.to_s == table }.none? do |other|
          foreign_key_list(other).any? { |fk| fk[:table].to_s == table } && !from(other).empty?
        end
      end

      def adapter_initialize
        @conversion_procs = SQLITE_TYPES.dup
        @conversion_procs["datetime"] = @conversion_procs["timestamp"] = method(:to_application_timestamp)
        set_integer_booleans
        reject_url_credentials
        # The engine allows one writer and reports contention immediately; we
        # wait in Ruby (see retry_busy), never with PRAGMA busy_timeout, whose
        # wait holds the GVL so the lock holder can't commit.
        @busy_retries = BusyCounter.new
        @busy_timeout = typecast_value_integer(@opts.fetch(:timeout, 5000)) / 1000.0
        # Take the write lock at BEGIN, so a transaction that can't get it
        # waits there instead of failing mid-way.
        self.transaction_mode = (@opts[:transaction_mode] || :immediate).to_sym
        @turso_database, @owns_turso_database = open_turso_database
        scrub_credentials
        sqlite_version # fail fast, and avoid a surprise first query later
      end

      # Runs before a replica is opened or adopted, so it covers both paths.
      def reject_url_credentials
        return unless url_has_auth_token?(@opts[:uri].to_s)
        raise Error, "pass auth_token: as a connection option, not in the URL (URLs end up in logs)"
      end

      def url_has_auth_token?(url)
        query = URI.parse(url).query
        query && URI.decode_www_form(query).any? { |k, _| k.downcase == "auth_token" }
      rescue ArgumentError, URI::Error
        url.match?(/[?&]auth(_|%5f)token(=|&|\z)/i)
      end

      def open_turso_database
        return [@opts[:turso_database], false] if @opts[:turso_database]
        path = @opts[:database].to_s
        path = ":memory:" if path.empty?
        db = Beagle::Turso::Database.open(
          local_path: path,
          remote_url: @opts[:remote_url],
          auth_token: @opts[:auth_token],
          bootstrap_if_empty: typecast_value_boolean(@opts.fetch(:bootstrap_if_empty, true))
        )
        [db, true]
      rescue Beagle::Turso::Error => e
        raise Sequel.convert_exception_class(e, Sequel::DatabaseConnectionError)
      end

      # The replica holds the token natively; nothing on this side needs it
      # again, so don't let it sit in opts (inspect, logging, error reports).
      def scrub_credentials
        @opts.delete(:auth_token)
        if @opts[:orig_opts].is_a?(Hash)
          @opts[:orig_opts] = @opts[:orig_opts].reject { |k, _| k.to_s == "auth_token" }
        end
      end

      # Busy retries so far (for specs).
      def busy_retry_count
        @busy_retries.value
      end

      def _execute(sql, opts, busy_retry: true)
        synchronize(opts[:server]) do |conn|
          # The retry sits inside the logged block: one log line per statement,
          # at error level only if it finally fails. Inside a transaction a
          # BusyError means the transaction is dead; it must surface (and
          # roll back), not be retried.
          log_connection_yield(sql, conn) { !busy_retry || _trans(conn) ? yield(conn) : retry_busy { yield conn } }
        end
      rescue Beagle::Turso::Error => e
        raise_error(e)
      end

      # Conservative: a ";" inside a string literal also counts as a second
      # statement, which only costs that statement its busy retry.
      def single_statement?(sql)
        !sql.strip.sub(/;\s*\z/, "").include?(";")
      end

      # Same as the shared version, but the BEGIN is retried inside its log
      # entry (one line, not one per attempt).
      def begin_new_transaction(conn, opts)
        mode = opts[:mode] || @transaction_mode
        sql = Sequel::SQLite::DatabaseMethods::TRANSACTION_MODE[mode] or
          raise Error, "transaction :mode must be one of: :deferred, :immediate, :exclusive, nil"
        log_connection_yield(sql, conn) { retry_busy { conn.execute_batch(sql) } }
        set_transaction_isolation(conn, opts)
      end

      # Retries a statement that lost the single-writer race, with capped
      # exponential backoff, for up to timeout: ms. sleep releases the GVL and
      # yields to a fiber scheduler, so the writer holding the lock can finish.
      def retry_busy
        deadline = nil
        delay = 0.002
        begin
          yield
        rescue Beagle::Turso::BusyError => e
          raise if e.message.include?("snapshot is stale")

          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          deadline ||= now + @busy_timeout
          raise if now + delay > deadline

          @busy_retries.increment
          sleep delay
          delay = [delay * 2, 0.1].min
          retry
        end
      end

      # Sequel runs BEGIN/COMMIT/SAVEPOINT with conn.public_send(method, sql):
      # one argument. Connection#execute takes (sql, params); execute_batch(sql)
      # takes one.
      def connection_execute_method
        :execute_batch
      end

      def database_error_classes
        [Beagle::Turso::Error]
      end

      def database_specific_error_class(exception, opts)
        return DatabaseDisconnectError if disconnect_error?(exception, opts)

        if exception.is_a?(Beagle::Turso::BusyError)
          return exception.message.include?("snapshot is stale") ? SerializationFailure : DatabaseLockTimeout
        end

        message = exception.message.sub(ENGINE_PREFIX, "")
        database_error_regexps.each { |regexp, klass| return klass if regexp.match?(message) }
        nil
      end

      # A closed or fork-inherited connection is dead: let the pool drop it.
      def disconnect_error?(exception, opts)
        exception.is_a?(Beagle::Turso::ClosedError) || exception.is_a?(Beagle::Turso::ForkedError) || super
      end

      # Only reads @opts: Sequel calls this before adapter_initialize.
      def connection_pool_default_options
        o = super
        memory = @opts[:database].to_s.empty? || @opts[:database] == ":memory:"
        memory && !@opts[:turso_database] ? o.merge(max_connections: 1) : o
      end

      def dataset_class_default
        Dataset
      end

      # The engine reports `to` as "" (SQLite: NULL) for a foreign key that
      # references the parent's primary key implicitly. Sequel would turn that
      # into a bogus column and break table rebuilds in alter_table.
      def _foreign_key_list_ds(table)
        super.with_row_proc(lambda do |row|
          row[:to] = nil if row[:to] == ""
          row
        end)
      end

      # For DEFAULT (expr) SQLite reports dflt_value as expr; the engine keeps
      # the parentheses. A default that isn't parenthesised is a literal, and
      # no literal starts with "(", so dropping one outer pair is exact. The
      # engine also writes a negative number as "- 1" (SQLite: "-1"), which
      # Sequel can't parse into a Ruby default.
      def _parse_pragma_ds(table_name, opts)
        super.with_row_proc(lambda do |row|
          d = row[:dflt_value]
          if d.is_a?(String)
            d = d[1...-1] if d.start_with?("(") && d.end_with?(")")
            row[:dflt_value] = d.sub(/\A-\s+(?=\d)/, "-")
          end
          row
        end)
      end

      # Sequel's version turns foreign keys off, rebuilds in a transaction and
      # turns them back on, each through its own pool checkout. PRAGMA
      # foreign_keys is per connection, so on a warm pool those can land on
      # different connections: the rebuild runs with foreign keys on, and a
      # connection is left with them off. Hold one connection throughout.
      def apply_alter_table(table, ops)
        synchronize { super }
      end

      # Sequel rebuilds a table by renaming it to a backup, creating the new
      # table, copying and dropping the backup. The engine ignores
      # legacy_alter_table and rewrites other tables' foreign keys (and views)
      # to the backup name, and on a synced replica a RENAME never reaches the
      # remote at all. So rebuild without any RENAME: copy the rows to a backup
      # table made from the new definition, drop the original, recreate it,
      # copy back, drop the backup. Nothing refers to the backup name. (Used
      # for every rebuild, local or synced, so there is one code path.)
      def duplicate_table(table, opts = OPTS)
        rename, create, insert, drop, *rest = super
        qt = quote_schema_table(table)
        bt = drop.to_s.delete_prefix("DROP TABLE ")
        create_prefix = "CREATE TABLE #{qt}("
        insert_prefix = "INSERT INTO #{qt}("
        unless rename == "ALTER TABLE #{qt} RENAME TO #{bt}" && create.start_with?(create_prefix) &&
            insert.start_with?(insert_prefix) && insert.end_with?(" FROM #{bt}")
          raise Error, "unexpected table rebuild SQL from Sequel #{Sequel::VERSION}; cannot rebuild #{qt}"
        end

        columns = insert.delete_prefix(insert_prefix).delete_suffix(" FROM #{bt}")
        new_cols = columns.split(") SELECT ", 2).first
        [
          "CREATE TABLE #{bt}(#{create.delete_prefix(create_prefix)}",
          "INSERT INTO #{bt}(#{columns} FROM #{qt}",
          "DROP TABLE #{qt}",
          create,
          "INSERT INTO #{qt}(#{new_cols}) SELECT #{new_cols} FROM #{bt}",
          "DROP TABLE #{bt}",
          *rest
        ]
      end

      # AUTOINCREMENT tables get engine bookkeeping tables in sqlite_master.
      def tables_and_views(filter, opts)
        super.reject do |name|
          name = name.to_s
          name.start_with?("__turso_internal_") || SYNC_ENGINE_TABLES.include?(name)
        end
      end

      # sql with RETURNING rowid added, unless it has a RETURNING clause. The
      # clause goes at the end of the statement: before a trailing ";" and any
      # trailing comment (a "--" comment would otherwise swallow it). Literals,
      # quoted identifiers and comments are masked first, so "RETURNING"
      # inside data doesn't count as a clause.
      def with_returning_rowid(sql)
        # Comments become spaces (they aren't part of the statement), literals
        # and identifiers become "x" (they are).
        masked = sql.gsub(NON_CODE) { |m| (m.start_with?("--", "/*") ? " " : "x") * m.length }
        return sql if RETURNING_CLAUSE.match?(masked)

        at = masked.sub(/;\s*\z/, "").rstrip.length
        "#{sql[0, at]} RETURNING rowid#{sql[at..]}"
      end

      # The engine doesn't capture ALTER TABLE ... RENAME TO / RENAME COLUMN
      # for sync (turso_core translate/alter.rs emits no CDC for them), so on
      # a synced replica the remote never sees the rename and every later
      # write to the table is lost on push.
      def refuse_rename_when_synced(what)
        return unless @turso_database.synced?

        raise Error, "#{what} is refused on a synced replica: the Turso sync engine does not replicate " \
          "ALTER TABLE ... RENAME TO / RENAME COLUMN to the remote, so later writes to the table would be " \
          "lost on push (no upstream fix yet). Create the new table, copy the rows and drop the old one, " \
          "or run the rename against the remote database directly."
      end

      def alter_table_sql(table, op)
        # On a synced replica, native DROP COLUMN loses unpushed rows and
        # RENAME COLUMN never reaches the remote (the engine doesn't capture
        # them), so both go through the RENAME-free rebuild.
        if @turso_database.synced?
          case op[:op]
          when :drop_column
            ocp = lambda { |oc| oc.delete_if { |c| c.to_s == op[:name].to_s } }
            return duplicate_table(table, old_columns_proc: ocp) { |cols| cols.delete_if { |s| s[:name].to_s == op[:name].to_s } }
          when :rename_column
            return rebuild_renaming_column(table, op)
          end
        end
        super
      end

      # Column rename as a rebuild. Sequel's fallback renames the column first
      # and then looks up UNIQUE constraints and indexes by the old name, so it
      # loses them. Take them before the rebuild and replay them with the new
      # name: inline/composite UNIQUE (autoindexes) become column or table
      # constraints, every other index mentioning the column is recreated.
      def rebuild_renaming_column(table, op)
        old = op[:name].to_s
        new = op[:new_name]
        rn = ->(cols) { cols.map { |c| c.to_s == old ? new : c } }
        pks = schema(table).select { |_, c| c[:primary_key] }.map { |n, _| n.to_s }
        auto_all = indexes(table, only_autocreated: true)
        auto = auto_all.values.select { |h| h[:unique] && h[:columns].map(&:to_s) != pks }
        single = auto.select { |h| h[:columns].length == 1 }.map { |h| rn.(h[:columns]).first.to_s }
        constraints = auto.select { |h| h[:columns].length > 1 }.map { |h| { type: :unique, columns: rn.(h[:columns]) } }
        named = indexes(table).select { |n, h| !auto_all.key?(n) && h[:columns].map(&:to_s).include?(old) }

        ncp = ->(nc) { nc.map! { |c| c.to_s == old ? new : c } }
        sqls = duplicate_table(table, new_columns_proc: ncp, no_unique: true, constraints: constraints) do |cols|
          cols.each do |c|
            c[:name] = new if c[:name].to_s == old
            c[:unique] = true if single.include?(c[:name].to_s) && !c[:primary_key]
          end
        end
        sqls + named.map { |name, h| alter_table_sql(table, h.merge(op: :add_index, name: name, columns: rn.(h[:columns]))) }
      end

      def support_without_rowid?
        false
      end
    end

    class Dataset < Sequel::Dataset
      include Sequel::SQLite::DatasetMethods

      def fetch_rows(sql)
        execute(sql) do |columns, decl_types, rows|
          cps = db.conversion_procs
          cols = columns.each_with_index.map { |c, i| [output_identifier(c), cps[base_type_name(decl_types[i])]] }
          self.columns = cols.map(&:first)
          rows.each do |values|
            row = {}
            cols.each_with_index do |(name, conv), i|
              v = values[i]
              row[name] = conv && !v.nil? ? conv.call(v) : v
            end
            yield row
          end
        end
      end

      private

      # "decimal(10,2)" -> "decimal"; nil (expression columns) stays nil.
      def base_type_name(t)
        (t =~ /\A(.*?)\(/ ? Regexp.last_match(1) : t).downcase if t
      end
    end
  end
end
