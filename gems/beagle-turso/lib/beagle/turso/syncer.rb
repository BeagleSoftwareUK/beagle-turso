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

      # Backoff stops growing past interval * 2**MAX_EXPONENT (max_backoff
      # caps it long before), so a long outage never builds a bignum.
      MAX_EXPONENT = 32

      # How often a final push polls for an in-flight cycle to finish.
      LOCK_POLL = 0.005

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
      # #status, reported to on_error/logger, then re-raised. If the message
      # carried credentials, both on_error and the caller get a copy of the
      # error (same class and backtrace) with the redacted message instead.
      def sync_now
        cycle(pull: @pull)
      end

      def status
        @state_lock.synchronize do
          Status.new(
            running: loop_running?,
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

      # True while the background thread is alive and not stopping. A loop
      # thread that died (e.g. on_error raised a non-StandardError) is not
      # running.
      def running?
        @state_lock.synchronize { loop_running? }
      end

      # Stops the loop, waits for a cycle in flight on any other thread
      # (the loop or a concurrent sync_now), then, if final_push and the
      # deadline allows, pushes once more. Waits at most `timeout` seconds in
      # total: an in-flight push or pull cannot be interrupted, so if the
      # deadline passes first this returns anyway with status.syncing true and
      # the work finishes in the background. Called from inside a cycle (from
      # on_error), it cannot wait for that cycle and skips the final push.
      # Never closes the database. Idempotent.
      def stop(timeout: 10, final_push: true)
        unless timeout.is_a?(Numeric) && timeout >= 0
          raise ArgumentError, "timeout must be a non-negative number of seconds"
        end

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
        join_quietly(@thread, deadline) if @thread && @thread != Thread.current
        # Inside a cycle (stop from on_error) this thread holds the cycle lock,
        # so waiting for it would only burn the deadline.
        unless @cycle_lock.owned? || loop_alive?
          if final_push && remaining(deadline).positive?
            pusher = Thread.new do
              cycle(pull: false, wait_until: deadline)
            rescue StandardError
              nil # already recorded, logged and reported by cycle
            end
            join_quietly(pusher, deadline)
          elsif lock_by(deadline)
            @cycle_lock.unlock # only waiting for the in-flight cycle
          end
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

      # Caller holds @state_lock.
      def loop_running?
        !!@thread&.alive? && !@stopping
      end

      # Joins a helper thread until the deadline. A thread that died from an
      # exception re-raises it here; stop must still finish, so log it.
      def join_quietly(thread, deadline)
        thread.join(remaining(deadline))
      rescue Exception => e # rubocop:disable Lint/RescueException
        raise if thread.alive? # not the thread's death: e.g. an interrupt aimed at us

        safe_warn("beagle-turso syncer thread died (#{e.class}): #{Redaction.message(e.message)}")
      end

      # Takes the cycle lock, waiting for an in-flight cycle until the
      # deadline. False if the deadline passed first.
      def lock_by(deadline)
        until @cycle_lock.try_lock
          left = remaining(deadline)
          return false unless left.positive?

          sleep([LOCK_POLL, left].min)
        end
        true
      end

      def remaining(deadline)
        [deadline - monotonic_now, 0].max
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # One push (then pull) under the cycle lock. Without wait_until it never
      # waits (returns :busy); with it, it waits for the lock until then.
      def cycle(pull:, wait_until: nil)
        locked = wait_until ? lock_by(wait_until) : @cycle_lock.try_lock
        return :busy unless locked

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
          reported = record_failure(e)
          raise e if reported.equal?(e)

          raise reported, cause: nil # the cause would carry the unredacted original
        ensure
          begin
            set_syncing(false)
          ensure
            @cycle_lock.unlock
          end
        end
      end

      def set_syncing(value)
        @state_lock.synchronize { @syncing = value }
      end

      # Records, logs and reports a failure. Returns the error to hand on:
      # the original, or a redacted copy if its message carried credentials.
      def record_failure(error)
        message = Redaction.message(error.message).freeze
        @state_lock.synchronize do
          @consecutive_failures += 1
          @last_error_class = error.class.to_s
          @last_error_message = message
          @last_error_at = Time.now
        end
        safe_warn("beagle-turso sync failed (#{error.class}): #{message}")
        reported = redacted_error(error, message)
        notify(reported)
        reported
      end

      def redacted_error(error, message)
        return error if message == error.message

        copy = begin
          error.exception(message)
        rescue StandardError
          nil
        end
        copy = Error.new(message) unless copy.is_a?(Exception) && copy.message == message
        copy.set_backtrace(error.backtrace) if copy.backtrace.nil? && error.backtrace
        copy
      end

      def notify(error)
        @on_error&.call(error, status)
      rescue StandardError => e
        safe_warn("beagle-turso syncer on_error raised (#{e.class}): #{Redaction.message(e.message)}")
      end

      # A broken logger must not skip on_error or replace the sync error.
      def safe_warn(message)
        @logger&.warn(message)
      rescue StandardError
        nil
      end

      # Delay before the next attempt after `failures` consecutive failures:
      # interval * 2**failures, capped at max_backoff, then spread by ±JITTER.
      def retry_delay(failures)
        base = [@interval * (2**[failures, MAX_EXPONENT].min), @max_backoff].min
        base * (1 + @random.rand(-JITTER..JITTER))
      end
    end
  end
end
