require "beagle/turso"
require "timeout"
require_relative "support/stalled_remote"

RSpec.describe "GVL release during network waits" do
  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  it "lets other Ruby threads run while a synced open waits on the network" do
    StalledRemote.url do |url|
      ticks = 0
      ticker = Thread.new { loop { ticks += 1; Thread.pass } }
      started = now
      StalledRemote.open_against(url)
      elapsed = now - started
      ticker.kill.join

      expect(elapsed).to be >= StalledRemote::STALL * 0.8 # it really waited on the network
      expect(ticks).to be > 1_000                          # and the GVL was free meanwhile
    end
  end

  it "keeps an Async reactor responsive during a synced open (fiber scheduler offload)" do
    ENV["ASYNC_SCHEDULER_WORKER_POOL"] ||= "true" # switch per Task 1 F3
    require "async"
    # blocking_operation_wait is prepended onto each scheduler instance only when
    # a worker pool exists, so test for the pool (io-event >= 1.11), not the method.
    skip "io-event has no WorkerPool" unless defined?(Async::Scheduler::WorkerPool) && Async::Scheduler::WorkerPool

    StalledRemote.url do |url|
      ticks = 0
      Sync do |task|
        expect(Fiber.scheduler).to respond_to(:blocking_operation_wait)
        ticker = task.async { loop { ticks += 1; sleep 0.01 } }
        StalledRemote.open_against(url)
        ticker.stop
      end
      # ~1 s of stall at 10 ms per tick; a held reactor yields ~0.
      expect(ticks).to be >= 40
    end
  end

  it "raises a Timeout during a local open without leaking the opened database" do
    # The interrupt is raised by rb_nogvl after the call returned; the database
    # it opened must be dropped (not leaked by a longjmp over Rust frames).
    path = StalledRemote.tmp_path
    th = Thread.new { Thread.current.report_on_exception = false; Beagle::Turso::Database.open_local(path) }
    th.raise(Timeout::Error) # may land before, during or after the open
    begin
      th.join
    rescue Timeout::Error
      nil # either outcome is fine; what matters is the reopen below
    end
    db = Beagle::Turso::Database.open_local(path)
    expect(db.connect).to be_a(Beagle::Turso::Connection)
    db.close
  end

  it "delivers a Timeout raised during the wait once the native call returns" do
    # No unblocking function: the interrupt is deferred, not lost.
    StalledRemote.url do |url|
      started = now
      expect {
        Timeout.timeout(0.2) { StalledRemote.open_against(url) }
      }.to raise_error(Timeout::Error)
      expect(now - started).to be >= StalledRemote::STALL * 0.8
    end
  end
end
