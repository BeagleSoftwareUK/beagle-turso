# frozen_string_literal: true

require "rake"
begin
  require "rails/railtie"
rescue LoadError
  nil # not a Rails app (railties absent): no rake hook, adapter still works
end
require "active_record/connection_adapters/beagle_turso/errors"
require "active_record/connection_adapters/beagle_turso/sync_manager"

module ActiveRecord
  module ConnectionAdapters
    module BeagleTurso
      # Pushes a synced replica to Turso before and after schema-changing rake
      # tasks.
      #
      # Why: the sync engine replays each unpushed row change against the
      # CURRENT local schema when it pushes. If the table was dropped, or lost
      # columns, since the write, the remote skips the statement, commits the
      # rest of the batch anyway, and the next pull resets the replica to the
      # remote -- the write is gone on both sides. Pushing immediately before
      # the migration leaves nothing pending to be mis-replayed; pushing again
      # afterwards publishes the new schema.
      #
      # Local-only connections are never touched.
      module MigrationPush
        SKIP_ENV = "BEAGLE_TURSO_SKIP_MIGRATION_PUSH"

        # Tasks that change the schema of the primary database. Nested
        # invocations (db:migrate:redo -> db:rollback + db:migrate, db:prepare
        # -> db:schema:load, ...) push once around the outermost task only.
        #   db:migrate, db:migrate:up/down/redo, db:rollback, db:forward
        #       run migrations
        #   db:prepare  migrates, or loads the schema into a fresh database
        #   db:schema:load  drops and recreates tables from schema.rb
        # (db:setup, db:reset and db:migrate:reset reach db:schema:load or
        # db:migrate and are covered through them.)
        TASKS = %w[
          db:migrate db:migrate:up db:migrate:down db:migrate:redo
          db:rollback db:forward db:prepare db:schema:load
        ].freeze

        # Prepended onto Rake::Task so it works whatever order the Railtie and
        # ActiveRecord's own rake tasks load in.
        module TaskHook
          def execute(args = nil)
            if MigrationPush::TASKS.include?(name)
              MigrationPush.around(name) { super }
            else
              super
            end
          end
        end

        class << self
          def install!
            return if Rake::Task.ancestors.include?(TaskHook)
            Rake::Task.prepend(TaskHook)
          end

          def around(task_name)
            return yield if depth.positive? # nested task: outermost already guards

            connection = synced_connection
            return yield unless connection

            if skip?
              warn "beagle_turso: WARNING: #{SKIP_ENV}=1 -- NOT pushing pending writes to Turso around " \
                   "#{task_name}. Unpushed writes to tables altered by this task may be lost."
              return yield
            end

            push_before!(connection)
            self.depth = 1
            begin
              result = yield
            ensure
              self.depth = 0
            end
            push_after!(connection)
            result
          end

          # The primary connection when (and only when) it is a synced
          # beagle_turso replica; nil otherwise, without opening anything for
          # local-only or other-adapter apps.
          def synced_connection
            config = ::ActiveRecord::Base.configurations.find_db_config(rails_env)
            return unless config && synced_config?(config.configuration_hash)

            ::ActiveRecord::Base.connection
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

          def push_before!(connection)
            ::Beagle::Turso::SyncManager.push!(connection)
          rescue StandardError => e
            raise MigrationPushError,
              "beagle_turso: could not push pending writes to Turso before migrating " \
              "(#{describe(e)}). Fix sync first, or set #{SKIP_ENV}=1 to migrate anyway " \
              "(unpushed writes to altered tables may be lost)."
          end

          def push_after!(connection)
            ::Beagle::Turso::SyncManager.push!(connection)
          rescue StandardError => e
            raise MigrationPushError,
              "beagle_turso: the schema change was applied to the local replica but could not be pushed to " \
              "Turso (#{describe(e)}). The remote does not have it yet; fix sync and run " \
              "Beagle::Turso::SyncManager.push! before writing to the changed tables."
          end

          def describe(error)
            message = error.message
            message = ::Beagle::Turso::Redaction.message(message) if defined?(::Beagle::Turso::Redaction)
            "#{error.class}: #{message}"
          end

          def depth = Thread.current[:beagle_turso_migration_push_depth].to_i
          def depth=(value)
            Thread.current[:beagle_turso_migration_push_depth] = value
          end
        end
      end

      if defined?(::Rails::Railtie)
        class Railtie < ::Rails::Railtie
          rake_tasks { MigrationPush.install! }
        end
      end
    end
  end
end
