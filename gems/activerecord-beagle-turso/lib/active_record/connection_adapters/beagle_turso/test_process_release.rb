# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module BeagleTurso
      # Lets `bin/rails db:test:prepare test` -- the Rails CI default -- run as
      # one command (and `db:test:prepare spec`, or any task after it that
      # starts a process of its own).
      #
      # The rake test tasks do not run the tests in the rake process:
      # Rails::TestUnit::Runner.run_from_rake starts a separate `rails test`
      # process and waits for it (rspec-rails' `spec` task does the same). A
      # local Turso database file is locked to the process that opened it --
      # SQLite lets processes share a file, Turso does not -- and
      # db:test:prepare left its connection open, so the test process could
      # not open the database:
      #
      #   open failed: Locking error: Failed locking file '.../storage/test.sqlite3'.
      #   File is locked by another process
      #
      # So when an outermost db:* task finishes, this adapter's file-backed
      # connections in the rake process are released. A pool reconnects on
      # its next use. In-memory databases are left alone (closing one would
      # destroy it, and no other process can open it anyway), as are other
      # adapters' connections.
      module TestProcessRelease
        # Prepended onto Rake::Task so it works whatever order the Railtie and
        # ActiveRecord's own rake tasks load in (same approach as MigrationPush).
        module TaskHook
          def execute(args = nil)
            if name.start_with?("db:")
              TestProcessRelease.around { super }
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

          # Releases once, when the outermost db:* task finishes: a db task
          # that invokes others (db:test:prepare -> db:test:load_schema) keeps
          # its connection until it is done.
          def around
            self.depth = depth + 1
            yield
          ensure
            self.depth = depth - 1
            release_connections! if depth.zero?
          end

          def release_connections!
            # Not loaded means nothing connected; don't load it to find out.
            return unless defined?(::ActiveRecord::Base) && !::ActiveRecord.autoload?(:Base)

            ::ActiveRecord::Base.connection_handler.connection_pool_list(:all).each do |pool|
              pool.disconnect! if releasable?(pool.db_config)
            end
          end

          def releasable?(db_config)
            db_config.adapter.to_s == "beagle_turso" && db_config.database.to_s != ":memory:"
          end

          def depth = Thread.current[:beagle_turso_test_process_release_depth].to_i
          def depth=(value)
            Thread.current[:beagle_turso_test_process_release_depth] = value
          end
        end
      end
    end
  end
end
