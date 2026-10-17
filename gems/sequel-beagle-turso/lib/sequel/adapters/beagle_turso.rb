require "beagle/turso"
require "bigdecimal"
require "sequel/adapters/shared/sqlite"

module Sequel
  # Sequel adapter for the beagle-turso driver. SQL generation, schema parsing
  # and transactions come from Sequel's shared SQLite support; this file only
  # replaces the plumbing (connections, execution, value conversion) and
  # papers over the engine's differences from SQLite.
  module BeagleTurso
    # Value conversion by declared type (filled in by Task 2).
    SQLITE_TYPES = {}.freeze

    class Database < Sequel::Database
      include Sequel::SQLite::DatabaseMethods

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

      private

      def adapter_initialize
        @conversion_procs = SQLITE_TYPES.dup
        @turso_database, @owns_turso_database = open_turso_database
        scrub_credentials
        sqlite_version # fail fast, and avoid a surprise first query later
      end

      def open_turso_database
        return [@opts[:turso_database], false] if @opts[:turso_database]
        if @opts[:uri].to_s.match?(/[?&]auth_token=/)
          raise Error, "pass auth_token: as a connection option, not in the URL (URLs end up in logs)"
        end

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

      # Only reads @opts: Sequel calls this before adapter_initialize.
      def connection_pool_default_options
        o = super
        memory = @opts[:database].to_s.empty? || @opts[:database] == ":memory:"
        memory && !@opts[:turso_database] ? o.merge(max_connections: 1) : o
      end

      def dataset_class_default
        Dataset
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
