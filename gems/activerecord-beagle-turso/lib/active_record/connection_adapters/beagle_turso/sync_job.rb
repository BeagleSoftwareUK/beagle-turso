# frozen_string_literal: true

require "active_record/connection_adapters/beagle_turso/sync_manager"

module ActiveRecord
  module ConnectionAdapters
    module BeagleTurso
      # Thin Solid Queue recurring job: on each run, it just delegates to
      # Beagle::Turso::SyncManager.sync! (push local writes, then pull remote
      # ones) against the app's default AR connection. No retry/backoff logic
      # here -- Solid Queue's own job-failure handling covers that, and
      # SyncManager itself carries no state between runs.
      #
      # Wire it up via config/recurring.yml (see
      # config/recurring.yml.example alongside this file), scheduled at
      # whatever cadence database.yml's +sync_interval:+ documents for the
      # target environment. This gem does not read recurring.yml or generate
      # it -- add the entry to the host app's own file.
      #
      # This gem does not declare a hard dependency on `activejob` (a Rails
      # app using Solid Queue already has it loaded by the time this file is
      # required). When ActiveJob is present, SyncJob subclasses
      # ActiveJob::Base as Solid Queue expects; otherwise it falls back to a
      # plain class with the same #perform, so requiring this file never
      # raises a LoadError on its own.
      sync_job_superclass = defined?(::ActiveJob::Base) ? ::ActiveJob::Base : Object

      class SyncJob < sync_job_superclass
        def perform
          ::Beagle::Turso::SyncManager.sync!
        end
      end
    end
  end
end
