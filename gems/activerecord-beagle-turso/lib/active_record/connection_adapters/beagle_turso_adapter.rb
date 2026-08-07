# frozen_string_literal: true

require "active_record"
require "active_record/connection_adapters/sqlite3_adapter"
require "beagle/turso"

module ActiveRecord
  module ConnectionAdapters
    # = ActiveRecord Beagle Turso Adapter
    #
    # Subclasses the stock SQLite3Adapter and reroutes only its raw-execution
    # seam (+perform_query+) onto a beagle-turso Connection. beagle-turso is a
    # libsql/Turso driver: it speaks a SQLite-compatible dialect but has its own
    # native handle rather than the +sqlite3+ gem's +::SQLite3::Database+.
    #
    # Everything ActiveRecord relies on above the raw connection -- SQL
    # generation, quoting, schema introspection (PRAGMA table_xinfo,
    # sqlite_master), type mapping, transactions -- is inherited unchanged from
    # SQLite3Adapter. We swap out three things:
    #
    #   * +new_client+ / +connect+ : open a Beagle::Turso::Database instead of a
    #     ::SQLite3::Database, wrapped in a Client that answers the handful of
    #     lifecycle/pragma messages the SQLite3Adapter sends a raw connection.
    #   * +perform_query+          : the single method every query flows through
    #     (see AbstractAdapter#raw_execute). Reads/RETURNING -> ActiveRecord::Result
    #     with columns+rows; writes -> affected-row count + last_insert_rowid.
    #   * +last_inserted_id+       : fall back to last_insert_rowid when a plain
    #     INSERT (no RETURNING) was used.
    class BeagleTursoAdapter < SQLite3Adapter
      ADAPTER_NAME = "BeagleTurso"

      RETURNING_REGEX = /\bRETURNING\b/i
      private_constant :RETURNING_REGEX

      class << self
        # Open a beagle-turso Database (synced remote when +remote_url+ is
        # present, otherwise local/in-memory) and wrap it so the SQLite3Adapter
        # can drive it as a raw connection.
        def new_client(config)
          database =
            if config[:remote_url]
              Beagle::Turso::Database.open(
                local_path: config[:database].to_s,
                remote_url: config[:remote_url],
                auth_token: config[:auth_token],
                bootstrap_if_empty: config.fetch(:bootstrap_if_empty, true)
              )
            else
              Beagle::Turso::Database.open_local(config[:database].to_s)
            end
          Client.new(database)
        end
      end

      # Adapts a Beagle::Turso::Database + its connected Connection to the subset
      # of the +sqlite3+ gem's Database surface that SQLite3Adapter pokes at.
      #
      # The execution methods (+query_result+, +execute+, +execute_batch+,
      # +last_insert_rowid+) are the real work. The rest are shims: the adapter's
      # +configure_connection+ sets PRAGMAs via +raw_connection.foo = value+ and
      # calls a couple of sqlite3-specific lifecycle methods that libsql neither
      # needs nor supports; we accept and no-op those so connect/configure runs
      # cleanly.
      class Client
        attr_reader :database, :connection

        def initialize(database)
          @database   = database
          @connection = database.connect
        end

        # --- execution surface used by BeagleTursoAdapter#perform_query ---
        def query_result(sql, params) = connection.query_result(sql, params)
        def execute(sql, params)      = connection.execute(sql, params)
        def execute_batch(sql)        = connection.execute_batch(sql)
        def last_insert_rowid         = connection.last_insert_rowid

        # --- sync passthrough (Database-level) ---
        def push = database.push
        def pull = database.pull

        # --- sqlite3-gem lifecycle shims the SQLite3Adapter drives ---
        # configure_connection only touches this when config[:timeout] is set.
        def busy_handler_timeout=(_)
          nil
        end
        # connected? => !(@raw_connection.nil? || @raw_connection.closed?)
        def closed? = false
        # beagle-turso has no explicit close; GC reclaims the native handle.
        def close = nil
        # SQLite3Adapter#reconnect calls this when reusing a live connection.
        def rollback = execute("ROLLBACK", [])

        # configure_connection applies DEFAULT_PRAGMAS via `raw_connection.foo = v`.
        # libsql manages journalling/locking itself, so accept and ignore them.
        def method_missing(name, *args)
          name.to_s.end_with?("=") ? nil : super
        end

        def respond_to_missing?(name, include_private = false)
          name.to_s.end_with?("=") || super
        end
      end

      private
        # The single seam. AbstractAdapter#raw_execute funnels every statement
        # here and expects an ActiveRecord::Result back, with the notification
        # payload's affected_rows/row_count filled in. cast_result (inherited)
        # returns the Result untouched and affected_rows (inherited) reads
        # Result#affected_rows, so building the Result correctly is all we need.
        def perform_query(raw_connection, sql, binds, type_casted_binds, prepare:, notification_payload:, batch: false)
          params = type_casted_binds || []

          result =
            if batch
              raw_connection.execute_batch(sql)
              ::ActiveRecord::Result.empty
            elsif returning_query?(sql)
              columns, rows = raw_connection.query_result(sql, params)
              ::ActiveRecord::Result.new(columns, rows)
            else
              affected = raw_connection.execute(sql, params)
              @last_inserted_rowid = raw_connection.last_insert_rowid
              ::ActiveRecord::Result.empty(affected_rows: affected)
            end

          verified!
          notification_payload[:affected_rows] = result.affected_rows
          notification_payload[:row_count]     = result.length
          result
        end

        # A statement returns rows when it is a read (SELECT/PRAGMA/WITH/...,
        # decided by SQLite3's own read/write classifier) or when it carries a
        # RETURNING clause (INSERT/UPDATE/DELETE ... RETURNING). write_query? is
        # a pure predicate here, so calling it a second time is side-effect free.
        def returning_query?(sql)
          !write_query?(sql) || RETURNING_REGEX.match?(sql)
        end

        # For INSERT ... RETURNING "id" the id arrives in the result rows (super).
        # For a plain INSERT (RETURNING unsupported) the result is empty, so fall
        # back to the rowid captured in perform_query's write branch.
        def last_inserted_id(result)
          super || @last_inserted_rowid
        end

        # Open the beagle-turso connection. Mirrors SQLite3Adapter#connect but
        # without its ::SQLite3-specific ConnectionNotEstablished rescue.
        def connect
          @raw_connection = self.class.new_client(@connection_parameters)
        end
    end
  end
end

ActiveRecord::ConnectionAdapters.register(
  "beagle_turso",
  "ActiveRecord::ConnectionAdapters::BeagleTursoAdapter",
  "active_record/connection_adapters/beagle_turso_adapter"
)
