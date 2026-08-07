# frozen_string_literal: true

module Beagle
  module Turso
    # Drives a synced beagle-turso database's `push`/`pull` from the
    # ActiveRecord layer, given an AR connection using +adapter: beagle_turso+
    # (see BeagleTursoAdapter). It is a thin delegator: all the real sync work
    # -- WAL-frame push/pull against the remote Turso database -- happens in
    # Beagle::Turso::Database#push/#pull (native, via beagle_turso_core). This
    # module only reaches +connection.raw_connection+ (the adapter's +Client+,
    # see BeagleTursoAdapter::Client) and calls through.
    #
    # Intended as the callback a Solid Queue recurring job invokes on a timer
    # (see ActiveRecord::ConnectionAdapters::BeagleTurso::SyncJob) -- not a
    # sync engine in its own right. It does not schedule itself, retry, queue
    # writes, or track sync state; scheduling is Solid Queue's job (see
    # config/recurring.yml.example alongside this file).
    #
    # == database.yml keys this depends on
    #
    # A connection is "synced" -- i.e. what +push!+/+pull!+ operate on --
    # only when its +database.yml+ entry carries BOTH of:
    #
    #   remote_url:  # the Turso database's libsql:// URL
    #   auth_token:  # its auth token
    #
    # (See BeagleTursoAdapter.new_client.) A third key, +sync_interval:+, is
    # NOT read by this adapter or by SyncManager -- it exists purely as a
    # documented convention for how often a host app's config/recurring.yml
    # should invoke SyncJob; keep the two in sync by hand (or via ERB) since
    # Solid Queue's recurring.yml is not sourced from database.yml. Example:
    #
    #   # config/database.yml
    #   production:
    #     adapter: beagle_turso
    #     database: storage/production.sqlite3
    #     remote_url: <%= Rails.application.credentials.dig(:turso, :prod_url) %>
    #     auth_token: <%= Rails.application.credentials.dig(:turso, :prod_token) %>
    #     sync_interval: 30 # seconds -- informational; wire it into recurring.yml yourself
    #
    # Never log +remote_url+/+auth_token+ -- Rails masks +password+-ish keys
    # in some diagnostics, but these are custom keys, so it doesn't cover them
    # automatically. Source them from encrypted credentials or ENV (as
    # BeagleTursoAdapter's callers already do) and don't pass them through
    # anything that inspects/logs config (e.g. don't log +connection_config+).
    module SyncManager
      # Raised by +push!+/+pull!+/+sync!+ when the given connection is
      # local-only (its database.yml entry has no +remote_url+/+auth_token+,
      # so BeagleTursoAdapter opened it via +Database.open_local+). The
      # underlying Client#push/#pull already raise a bare RuntimeError for
      # this (see Beagle::Turso::Database#push/#pull); SyncManager re-raises
      # it as this distinct, documented type so callers can rescue it
      # specifically instead of matching on the driver's message text. A
      # genuine sync failure against a real remote (network error, auth
      # failure, etc.) is NOT reclassified -- it propagates as whatever error
      # the driver raised, unchanged.
      class NotSyncedError < StandardError; end

      # Matches only the driver's local-only wording (see
      # beagle_turso_core's `Error::Sync` in `Database::push`/`Database::pull`)
      # so a real sync failure -- which also surfaces as a RuntimeError, just
      # with different text -- is never misreported as "not synced".
      LOCAL_ONLY_MESSAGE_REGEX = /on a local-only database/i
      private_constant :LOCAL_ONLY_MESSAGE_REGEX

      module_function

      # Push this connection's local writes to its remote Turso database.
      def push!(connection = ActiveRecord::Base.connection)
        reraise_local_only { connection.raw_connection.push }
      end

      # Pull remote writes down into this connection's local replica.
      # Returns the driver's own true/false (whether anything changed).
      def pull!(connection = ActiveRecord::Base.connection)
        reraise_local_only { connection.raw_connection.pull }
      end

      # Push, then pull. Pushing first means this replica's own writes reach
      # the remote before it re-syncs down, so afterwards this connection is
      # caught up with both its own writes (now durable remotely) and
      # whatever else landed on the remote from other replicas. Call push!
      # or pull! directly when only one direction is wanted.
      def sync!(connection = ActiveRecord::Base.connection)
        push!(connection)
        pull!(connection)
      end

      def reraise_local_only
        yield
      rescue RuntimeError => e
        raise e unless LOCAL_ONLY_MESSAGE_REGEX.match?(e.message)

        raise NotSyncedError,
          "#{e.message} -- this connection is local-only; configure remote_url: " \
          "and auth_token: in database.yml to enable sync"
      end
      private_class_method :reraise_local_only
    end
  end
end
