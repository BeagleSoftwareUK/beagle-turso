# frozen_string_literal: true

require "active_record/connection_adapters/beagle_turso/errors"
require "active_record/connection_adapters/beagle_turso/sync_manager"
require "active_record/connection_adapters/beagle_turso/test_process_release"

module ActiveRecord
  module ConnectionAdapters
    module BeagleTurso
      # Pushes a synced replica to Turso before and after schema-changing rake
      # tasks, when (and only when) a migration is actually going to run.
      #
      # Why: the sync engine replays each unpushed row change against the
      # CURRENT local schema when it pushes. If the table was dropped, or lost
      # columns, since the write, the remote skips the statement, commits the
      # rest of the batch anyway, and the next pull resets the replica to the
      # remote -- the write is gone on both sides. Pushing immediately before
      # the migration leaves nothing pending to be mis-replayed; pushing again
      # afterwards publishes the new schema. (A copy-table migration on a table
      # with rows makes that second push fail once, spuriously, for the same
      # reason; the data is all on the remote and a retry succeeds.)
      #
      # Local-only connections are never touched.
      module MigrationPush
        SKIP_ENV = "BEAGLE_TURSO_SKIP_MIGRATION_PUSH"

        # Pushes only when a migration is pending (or the database is not
        # initialised): db:prepare runs on every container boot in Rails 8 and
        # must not need the network when there is nothing to do.
        CHECKED_TASKS = %w[db:migrate db:prepare].freeze

        # Tasks that always run a specific migration, so always push.
        ALWAYS_TASKS = %w[
          db:migrate:up db:migrate:down db:migrate:redo db:rollback db:forward
        ].freeze

        # db:schema:load has no effect with this adapter (Rails raises
        # DatabaseNotSupported for it) but is listed so that it is guarded if
        # that ever changes.
        SCHEMA_TASKS = %w[db:schema:load].freeze

        # Prepended onto Rake::Task so it works whatever order the Railtie and
        # ActiveRecord's own rake tasks load in.
        module TaskHook
          def execute(args = nil)
            if name.start_with?("db:") && MigrationPush.guarded?(name)
              MigrationPush.around(name) { super }
            else
              super
            end
          end
        end

        class << self
          def install!
            return if ::Rake::Task.ancestors.include?(TaskHook)
            ::Rake::Task.prepend(TaskHook)
          end

          # "db:migrate", "db:migrate:primary", "db:rollback:primary", ...
          # The suffix is the PRIMARY config's own name, never hard-coded.
          def guarded?(task_name)
            base = base_task(task_name)
            base && (CHECKED_TASKS + ALWAYS_TASKS + SCHEMA_TASKS).include?(base)
          end

          def base_task(task_name)
            all = CHECKED_TASKS + ALWAYS_TASKS + SCHEMA_TASKS
            return task_name if all.include?(task_name)

            name = primary_config&.name
            return unless name && task_name.end_with?(":#{name}")

            base = task_name.delete_suffix(":#{name}")
            base if all.include?(base)
          end

          def around(task_name)
            return yield if depth.positive? # nested task: the outermost one guards

            config = primary_config
            return yield unless config && synced_config?(config.configuration_hash)

            if skip?
              warn "beagle_turso: WARNING: #{SKIP_ENV}=1 -- NOT pushing pending writes to Turso around " \
                   "#{task_name}. Unpushed writes to tables altered by this task may be lost."
              return yield
            end

            existing = local_database_exists?(config.configuration_hash)
            if CHECKED_TASKS.include?(base_task(task_name)) && existing
              return yield unless migration_pending?
            end

            # A replica that does not exist yet has nothing local to push.
            push_before! if existing
            self.depth = 1
            begin
              result = yield
            ensure
              self.depth = 0
            end
            push_after!
            result
          end

          def primary_config
            ::ActiveRecord::Base.configurations.find_db_config(rails_env)
          rescue StandardError
            nil
          end

          def synced_config?(hash)
            hash[:adapter].to_s == "beagle_turso" && !hash[:remote_url].to_s.empty? && !hash[:auth_token].to_s.empty?
          end

          def skip?
            ENV[SKIP_ENV] == "1"
          end

          private

          def rails_env
            defined?(::Rails) && ::Rails.respond_to?(:env) ? ::Rails.env.to_s : (ENV["RAILS_ENV"] || "development")
          end

          def local_database_exists?(hash)
            path = hash[:database].to_s
            return false if path.empty? || path == ":memory:"

            root = defined?(::Rails) && ::Rails.respond_to?(:root) ? ::Rails.root : nil
            File.exist?(root ? File.expand_path(path, root.to_s) : path)
          end

          # True when a migration is pending, or the schema is not initialised
          # (no schema_migrations table reads as everything pending). Any
          # trouble answering counts as pending: the guard then runs.
          def migration_pending?
            connection.pool.migration_context.needs_migration?
          rescue StandardError
            true
          end

          # Re-resolved on every use: multi-database tasks swap connection pools
          # (with_temporary_pool), so a connection held across the task could
          # belong to a pool that is gone. lease_connection does not raise under
          # permanent_connection_checkout = :disallowed, as .connection does.
          def connection
            ::ActiveRecord::Base.lease_connection
          end

          def push_before!
            ::Beagle::Turso::SyncManager.push!(connection)
          rescue StandardError => e
            raise MigrationPushError.new(
              "beagle_turso: could not push pending writes to Turso before migrating (#{describe(e)}). " \
              "Fix sync first, or set #{SKIP_ENV}=1 to migrate anyway (unpushed writes to altered tables " \
              "may be lost)."
            ), cause: nil
          end

          # A copy-table migration on a table with rows (change_column*,
          # remove_column, add_foreign_key, add_timestamps, ...) makes the first
          # push after it fail with a parse error even though the remote ends up
          # with everything (sync engine bug A); the second push succeeds. So
          # retry once before reporting a failure.
          def push_after!
            ::Beagle::Turso::SyncManager.push!(connection)
          rescue StandardError => first
            begin
              ::Beagle::Turso::SyncManager.push!(connection)
              warn "beagle_turso: WARNING: the push after the migration failed once (#{describe(first)}) and " \
                   "succeeded on retry. This is expected after a migration that copies a table (sync engine " \
                   "quirk); no data was lost."
            rescue StandardError => second
              raise MigrationPushError.new(
                "beagle_turso: the schema change was applied to the local replica, but pushing it to Turso " \
                "failed twice (#{describe(first)}; then #{describe(second)}). The remote may not have the " \
                "new schema yet: check sync, then run Beagle::Turso::SyncManager.push!."
              ), cause: nil
            end
          end

          def describe(error)
            message = error.message
            message = ::Beagle::Turso::Redaction.message(message) if defined?(::Beagle::Turso::Redaction)
            prefix = error.class.name.to_s.end_with?("OpenError") ? "could not open the synced replica: " : ""
            "#{error.class}: #{prefix}#{message}"
          end

          def depth = Thread.current[:beagle_turso_migration_push_depth].to_i
          def depth=(value)
            Thread.current[:beagle_turso_migration_push_depth] = value
          end
        end
      end

      if defined?(::Rails::Railtie)
        class Railtie < ::Rails::Railtie
          rake_tasks do
            require "rake"
            MigrationPush.install!
            TestProcessRelease.install!
          end
        end
      end
    end
  end
end
