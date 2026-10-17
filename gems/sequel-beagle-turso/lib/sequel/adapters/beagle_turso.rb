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

    class Database < Sequel::Database
      include Sequel::SQLite::DatabaseMethods

      # The driver prefixes engine messages ("query failed: ..."); Sequel's
      # SQLite error regexps (some anchored at \A) expect the bare message.
      ENGINE_PREFIX = /\A(?:open failed|connect failed|query failed|sync failed|database is busy): /

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

      def execute_ddl(sql, opts = OPTS)
        _execute(sql, opts) { |conn| conn.execute_batch(sql) }
        nil
      end

      def execute_insert(sql, opts = OPTS)
        _execute(sql, opts) do |conn|
          conn.execute(sql, [])
          conn.last_insert_rowid
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

      def freeze
        @conversion_procs.freeze
        super
      end

      private

      def adapter_initialize
        @conversion_procs = SQLITE_TYPES.dup
        @conversion_procs["datetime"] = @conversion_procs["timestamp"] = method(:to_application_timestamp)
        set_integer_booleans
        reject_url_credentials
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

      def _execute(sql, opts)
        synchronize(opts[:server]) do |conn|
          log_connection_yield(sql, conn) { yield conn }
        end
      rescue Beagle::Turso::Error => e
        raise_error(e)
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

      # AUTOINCREMENT tables get engine bookkeeping tables in sqlite_master.
      def tables_and_views(filter, opts)
        super.reject { |name| name.to_s.start_with?("__turso_internal_") }
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
