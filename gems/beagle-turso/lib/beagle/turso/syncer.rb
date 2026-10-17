module Beagle
  module Turso
    # Keeps a synced Database's remote copy current: runs push (then pull) on
    # a background thread, backs off on failure, reports status, and pushes
    # one last time on stop. Framework-neutral and opt-in: nothing runs until
    # #start, and it never closes the database (its owner does, after #stop).
    #
    # push/pull release the GVL (see the README), so the syncer's thread does
    # not stall other Ruby threads or a fiber scheduler's reactor.
    class Syncer
      Status = Data.define(
        :running, :syncing,
        :last_push_at, :last_pull_at,
        :last_error_class, :last_error_message, :last_error_at,
        :consecutive_failures, :destination
      )

      # Retry delays are spread by ±JITTER so restarted processes don't retry
      # in lockstep.
      JITTER = 0.2

      def initialize(database, interval: 30, pull: true, max_backoff: 300, on_error: nil, logger: nil, random: Random.new)
        unless database.synced?
          raise NotSyncedError, "Syncer needs a synced database (opened with remote_url: and auth_token:)"
        end
        raise ArgumentError, "interval must be positive" unless interval.positive?
        raise ArgumentError, "max_backoff must be at least interval" if max_backoff < interval

        @database = database
        @interval = interval
        @pull = pull
        @max_backoff = max_backoff
        @on_error = on_error
        @logger = logger
        @random = random

        @cycle_lock = Mutex.new # held for the whole of one push/pull cycle
        @state_lock = Mutex.new # guards the fields below and the wake-up signal
        @wake = ConditionVariable.new
        @thread = nil
        @stopping = false
        @stopped = false
        @syncing = false
        @last_push_at = nil
        @last_pull_at = nil
        @last_error_class = nil
        @last_error_message = nil
        @last_error_at = nil
        @consecutive_failures = 0
      end

      # Runs one cycle on the calling thread. Returns :ok, or :busy (without
      # waiting) when another cycle is in progress. A failure is recorded in
      # #status, reported to on_error/logger, then re-raised.
      def sync_now
        cycle(pull: @pull)
      end

      def status
        @state_lock.synchronize do
          Status.new(
            running: !@thread.nil? && !@stopping,
            syncing: @syncing,
            last_push_at: @last_push_at,
            last_pull_at: @last_pull_at,
            last_error_class: @last_error_class,
            last_error_message: @last_error_message,
            last_error_at: @last_error_at,
            consecutive_failures: @consecutive_failures,
            destination: @database.remote_host
          )
        end
      end

      # --- background loop (Task 4) ---

      private

      def cycle(pull:)
        return :busy unless @cycle_lock.try_lock

        begin
          set_syncing(true)
          @database.push
          @state_lock.synchronize { @last_push_at = Time.now }
          if pull
            @database.pull
            @state_lock.synchronize { @last_pull_at = Time.now }
          end
          @state_lock.synchronize { @consecutive_failures = 0 }
          :ok
        rescue StandardError => e
          record_failure(e)
          raise
        ensure
          set_syncing(false)
          @cycle_lock.unlock
        end
      end

      def set_syncing(value)
        @state_lock.synchronize { @syncing = value }
      end

      def record_failure(error)
        message = Redaction.message(error.message)
        @state_lock.synchronize do
          @consecutive_failures += 1
          @last_error_class = error.class.name
          @last_error_message = message
          @last_error_at = Time.now
        end
        @logger&.warn("beagle-turso sync failed (#{error.class.name}): #{message}")
        notify(error)
      end

      def notify(error)
        @on_error&.call(error, status)
      rescue StandardError => e
        @logger&.warn("beagle-turso syncer on_error raised (#{e.class.name}): #{Redaction.message(e.message)}")
      end

      # Delay before the next attempt after `failures` consecutive failures:
      # interval * 2**failures, capped at max_backoff, then spread by ±JITTER.
      def retry_delay(failures)
        base = [@interval * (2**failures), @max_backoff].min
        base * (1 + @random.rand(-JITTER..JITTER))
      end
    end
  end
end
