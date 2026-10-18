# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module BeagleTurso
      # Raised instead of running a schema change that the Turso sync engine
      # cannot replicate. On a synced replica, `ALTER TABLE ... RENAME TO` and
      # `RENAME COLUMN` are not captured for sync (engine 0.8.3), so the remote
      # never sees them and every later write to the renamed table or column is
      # lost on push.
      class UnsupportedOnSyncedReplica < ::ActiveRecord::ActiveRecordError; end

      # Raised by the db:migrate family of rake tasks when pending writes could
      # not be pushed to Turso before (or after) a migration.
      class MigrationPushError < ::ActiveRecord::ActiveRecordError; end
    end
  end
end
