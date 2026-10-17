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

      # Starts the background thread. Idempotent while running. A stopped
      # syncer cannot be restarted; create a new one.
      def start
        @state_lock.synchronize do
          raise Error, "syncer has been stopped; create a new one" if @stopped
          return self if @thread

          @thread = Thread.new { run_loop }
          @thread.name = "beagle-turso-syncer"
        end
        self
      end

      def running?
        @state_lock.synchronize { !@thread.nil? && !@stopping }
      end

      # Stops the loop and, if final_push and the deadline allows, pushes once
      # more. Waits at most `timeout` seconds in total: an in-flight push or
      # pull cannot be interrupted, so if the deadline passes first this
      # returns anyway with status.syncing true and the work finishes in the
      # background. Never closes the database. Idempotent.
      def stop(timeout: 10, final_push: true)
        first = @state_lock.synchronize do
          next false if @stopped

          @stopped = true
          @stopping = true
          @wake.broadcast
          true
        end
        return status unless first

        deadline = monotonic_now + timeout
        # Joining our own thread (stop called from on_error) would raise; that
        # thread exits by itself once the callback returns.
        @thread.join(remaining(deadline)) if @thread && @thread != Thread.current
        if final_push && !loop_alive? && remaining(deadline).positive?
          pusher = Thread.new do
            cycle(pull: false)
          rescue StandardError
            nil # already recorded, logged and reported by cycle
          end
          pusher.join(remaining(deadline))
        end
        status
      end

      private

      def run_loop
        loop do
          return if @state_lock.synchronize { @stopping }

          delay =
            begin
              cycle(pull: @pull)
              @interval
            rescue StandardError
              retry_delay(@state_lock.synchronize { @consecutive_failures })
            end

          @state_lock.synchronize do
            return if @stopping

            @wake.wait(@state_lock, delay)
          end
        end
      end

      def loop_alive?
        @thread&.alive? && @thread != Thread.current
      end

      def remaining(deadline)
        [deadline - monotonic_now, 0].max
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

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
