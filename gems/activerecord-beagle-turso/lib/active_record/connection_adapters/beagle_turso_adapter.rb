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
    # SQLite3Adapter. We swap out:
    #
    #   * +new_client+ / +connect+   : open a Beagle::Turso::Database instead of a
    #     ::SQLite3::Database, wrapped in a Client that answers the handful of
    #     lifecycle/pragma messages the SQLite3Adapter sends a raw connection.
    #   * +configure_connection+     : re-assert `PRAGMA foreign_keys = ON` through
    #     the real exec path, because the stock DEFAULT_PRAGMA setter is a no-op on
    #     our Client (SQLite defaults FKs OFF per-connection).
    #   * +perform_query+            : the single method every query flows through
    #     (see AbstractAdapter#raw_execute). Reads/RETURNING -> ActiveRecord::Result
    #     with columns+rows; writes (incl. data-modifying CTEs) -> affected-row
    #     count + last_insert_rowid.
    #   * +last_inserted_id+         : fall back to last_insert_rowid when a plain
    #     INSERT (no RETURNING) was used.
    class BeagleTursoAdapter < SQLite3Adapter
      ADAPTER_NAME = "BeagleTurso"

      # A RETURNING clause makes any write yield rows, so it routes to the read
      # (query_result) branch.
      RETURNING_REGEX = /\bRETURNING\b/i
      private_constant :RETURNING_REGEX

      # A data-modifying CTE: a leading WITH whose *main* statement -- the token
      # right after the CTE definition list's closing paren -- is INSERT / UPDATE
      # / DELETE. AR's write_query? classifies any leading WITH as a READ, so
      # without this such writes would be routed to query_result: the change still
      # persists, but the affected-row count comes back nil and a CTE-INSERT's
      # rowid is lost. The `\)\s*` anchor is deliberate -- it keeps `WITH ... SELECT`
      # reads (and DML keywords that appear inside string literals or identifiers)
      # from being misclassified as writes.
      #
      # Residual limitation: this is a heuristic, not a full SQL parse. A
      # data-modifying CTE whose main verb is not immediately preceded by the CTE
      # list's closing `)` (extremely unusual) could be missed, and a read CTE
      # containing the literal text `) UPDATE`/`) INSERT`/`) DELETE` could be
      # mis-routed. The read branch also re-captures last_insert_rowid whenever the
      # SQL mentions INSERT, so an inserted id is never silently lost even on a miss.
      DATA_MODIFYING_CTE_REGEX = /\A\s*WITH\b[\s\S]*\)\s*(?:INSERT|UPDATE|DELETE)\b/i
      private_constant :DATA_MODIFYING_CTE_REGEX

      INSERT_REGEX = /\bINSERT\b/i
      private_constant :INSERT_REGEX

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
            elsif write_statement?(sql)
              affected = raw_connection.execute(sql, params)
              @last_inserted_rowid = raw_connection.last_insert_rowid
              ::ActiveRecord::Result.empty(affected_rows: affected)
            else
              columns, rows = raw_connection.query_result(sql, params)
              # Belt-and-suspenders: a RETURNING insert lands here (id read from
              # rows by last_inserted_id), and a data-modifying CTE that slips past
              # write_statement? would too -- keep the rowid so an inserted id is
              # never silently lost even on a heuristic miss.
              @last_inserted_rowid = raw_connection.last_insert_rowid if INSERT_REGEX.match?(sql)
              ::ActiveRecord::Result.new(columns, rows)
            end

          verified!
          notification_payload[:affected_rows] = result.affected_rows
          notification_payload[:row_count]     = result.length
          result
        end

        # Route to the WRITE branch (execute -> affected count + last_insert_rowid)
        # rather than the read branch. A statement is a write when SQLite3's own
        # read/write classifier says so, OR when it is a data-modifying CTE that
        # the classifier misreads as a read (see DATA_MODIFYING_CTE_REGEX). A
        # RETURNING clause always yields rows, so it goes to the read branch even
        # though it mutates. write_query? is a pure predicate here, so calling it a
        # second time is side-effect free.
        def write_statement?(sql)
          return false if RETURNING_REGEX.match?(sql)
          write_query?(sql) || data_modifying_cte?(sql)
        end

        def data_modifying_cte?(sql)
          DATA_MODIFYING_CTE_REGEX.match?(sql)
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

        # SQLite disables foreign keys per-connection by default; stock
        # SQLite3Adapter turns them on via `raw_connection.foreign_keys = true`
        # (a DEFAULT_PRAGMA setter). On our Client that setter is a swallowed
        # no-op, so FK enforcement would silently be OFF -- a regression vs the
        # stock adapter. Re-assert it here through the real exec path.
        #
        # `super` still runs (check_version + the other DEFAULT_PRAGMA setters);
        # journal_mode/synchronous/mmap_size are moot for in-memory and remote
        # libsql, so leaving those as no-ops is fine.
        def configure_connection
          super
          @raw_connection.execute("PRAGMA foreign_keys = ON", [])
        end
    end
  end
end

ActiveRecord::ConnectionAdapters.register(
  "beagle_turso",
  "ActiveRecord::ConnectionAdapters::BeagleTursoAdapter",
  "active_record/connection_adapters/beagle_turso_adapter"
)
