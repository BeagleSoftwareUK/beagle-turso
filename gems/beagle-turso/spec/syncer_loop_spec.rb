require "beagle/turso"
require "logger"
require "stringio"
require "timeout"
require_relative "support/fake_database"

RSpec.describe "Beagle::Turso::Syncer background loop" do
  let(:db) { FakeDatabase.new }
  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  def wait_for(timeout = 2) = (deadline = now + timeout; sleep 0.005 until yield || now > deadline)
  def loop_thread(syncer) = syncer.instance_variable_get(:@thread)

  it "cycles on the interval once started and stops cleanly" do
    s = Beagle::Turso::Syncer.new(db, interval: 0.02)
    expect(s.running?).to be(false)
    s.start
    expect(s.running?).to be(true)
    wait_for { db.pushes >= 3 }
    expect(db.pushes).to be >= 3
    st = s.stop(final_push: false)
    expect(st.running).to be(false)
    expect(s.running?).to be(false)
  end

  it "start is idempotent and a stopped syncer cannot restart" do
    before = Thread.list
    s = Beagle::Turso::Syncer.new(db, interval: 1)
    s.start
    first = loop_thread(s)
    s.start
    expect(loop_thread(s)).to equal(first)
    expect((Thread.list - before).count { _1.name == "beagle-turso-syncer" }).to eq(1)
    s.stop(final_push: false)
    expect(first.alive?).to be(false)
    expect { s.start }.to raise_error(Beagle::Turso::Error, /stopped/)
  end

  it "stop wakes a long wait immediately" do
    s = Beagle::Turso::Syncer.new(db, interval: 60).start
    wait_for { db.pushes == 1 }
    t = now
    s.stop(final_push: false)
    expect(now - t).to be < 0.5
  end

  it "backs off after failures and resets after success" do
    failures = 3
    db.on_push = -> { if failures.positive? then failures -= 1; raise Beagle::Turso::SyncError, "x" end }
    s = Beagle::Turso::Syncer.new(db, interval: 0.01, max_backoff: 0.05, random: Random.new(2)).start
    wait_for(3) { db.pushes >= 5 }
    st = s.stop(final_push: false)
    expect(db.pushes).to be >= 5
    expect(st.consecutive_failures).to eq(0)
    expect(st.last_error_class).to eq("Beagle::Turso::SyncError")
  end

  it "final_push pushes once more on stop; final_push: false does not" do
    s = Beagle::Turso::Syncer.new(db, interval: 60).start
    wait_for { db.pushes == 1 }
    s.stop
    expect(db.pushes).to eq(2)

    db2 = FakeDatabase.new
    s2 = Beagle::Turso::Syncer.new(db2, interval: 60).start
    wait_for { db2.pushes == 1 }
    s2.stop(final_push: false)
    expect(db2.pushes).to eq(1)
  end

  it "final push also runs for a syncer that was never started" do
    Beagle::Turso::Syncer.new(db).stop
    expect(db.calls).to eq(%i[push])
  end

  it "returns at the deadline with syncing: true when a push outlasts it" do
    gate = Queue.new
    db.on_push = -> { gate.pop }
    s = Beagle::Turso::Syncer.new(db, interval: 60).start
    wait_for { s.status.syncing }
    t = now
    st = s.stop(timeout: 0.2)
    expect(now - t).to be_between(0.15, 1.0)
    expect(st.syncing).to be(true)
    gate << :go
    expect(loop_thread(s).join(2)).not_to be_nil
  end

  it "stop is idempotent" do
    s = Beagle::Turso::Syncer.new(db, interval: 60).start
    s.stop(final_push: false)
    expect { s.stop }.not_to raise_error
    expect(db.pushes).to be <= 1
  end

  it "survives a raising on_error" do
    log = StringIO.new
    calls = 0
    db.on_push = -> { raise Beagle::Turso::SyncError, "x" }
    s = Beagle::Turso::Syncer.new(db, interval: 0.01, max_backoff: 0.02, logger: Logger.new(log),
                                  on_error: ->(*) { calls += 1; raise "callback broke" }).start
    wait_for { calls >= 3 }
    s.stop(final_push: false)
    expect(calls).to be >= 3
    expect(log.string).to include("on_error raised (RuntimeError): callback broke")
  end

  it "stop from inside on_error does not deadlock (stop from inside on_error)" do
    s = nil
    db.on_push = -> { raise Beagle::Turso::SyncError, "x" }
    stopped = Queue.new
    s = Beagle::Turso::Syncer.new(db, interval: 0.01, on_error: ->(*) { stopped << s.stop(timeout: 0.5, final_push: false) })
    s.start
    st = Timeout.timeout(2) { stopped.pop }
    expect(st.running).to be(false)
    expect(loop_thread(s).join(2)).not_to be_nil
  end

  it "stop from inside on_error with final_push: true returns promptly and skips the final push" do
    s = nil
    db.on_push = -> { raise Beagle::Turso::SyncError, "x" if db.pushes == 1 }
    stopped = Queue.new
    s = Beagle::Turso::Syncer.new(db, interval: 0.01, on_error: lambda { |*|
      t = now
      st = s.stop(timeout: 1)
      stopped << [st, now - t]
    })
    s.start
    st, took = Timeout.timeout(3) { stopped.pop }
    expect(took).to be < 0.2
    expect(st.running).to be(false)
    expect(loop_thread(s).join(2)).not_to be_nil
    expect(db.pushes).to eq(1)
  end

  it "stop waits for a sync_now in flight on another thread, then pushes once more" do
    gate = Queue.new
    first = true
    db.on_push = -> { if first then first = false; gate.pop end }
    s = Beagle::Turso::Syncer.new(db, interval: 60)
    caller_thread = Thread.new { s.sync_now }
    wait_for { s.status.syncing }
    stopper = Thread.new { s.stop(timeout: 2) }
    sleep 0.1
    expect(stopper.alive?).to be(true)
    gate << :go
    st = stopper.value
    expect(caller_thread.value).to eq(:ok)
    expect(db.pushes).to eq(2)
    expect(st.syncing).to be(false)
  end

  it "stop survives a loop thread killed by a non-StandardError and still pushes" do
    db.on_push = -> { raise Beagle::Turso::SyncError, "x" if db.pushes == 1 }
    log = StringIO.new
    s = Beagle::Turso::Syncer.new(db, interval: 0.01, logger: Logger.new(log),
                                  on_error: ->(*) { raise Exception, "callback exploded" })
    previous = Thread.report_on_exception
    begin
      Thread.report_on_exception = false
      s.start
    ensure
      Thread.report_on_exception = previous
    end
    wait_for { !loop_thread(s).alive? }
    expect(s.running?).to be(false)
    expect(s.status.running).to be(false)
    st = nil
    expect { st = s.stop(timeout: 1) }.not_to raise_error
    expect(st).to be_a(Beagle::Turso::Syncer::Status)
    expect(db.pushes).to eq(2)
    expect(st.last_push_at).to be_a(Time)
    expect(log.string).to include("callback exploded")
  end

  it "rejects a bad timeout without stopping, so a later stop still pushes" do
    s = Beagle::Turso::Syncer.new(db, interval: 60).start
    wait_for { db.pushes == 1 }
    [nil, -1, "5"].each do |bad|
      expect { s.stop(timeout: bad) }.to raise_error(ArgumentError, /timeout/)
    end
    expect(s.running?).to be(true)
    st = s.stop
    expect(st.running).to be(false)
    expect(db.pushes).to eq(2)
    expect(loop_thread(s).alive?).to be(false)
  end

  it "records failures when the database is closed under it (database closed under it)" do
    db.on_push = -> { raise Beagle::Turso::ClosedError, "database is closed" }
    s = Beagle::Turso::Syncer.new(db, interval: 0.01, max_backoff: 0.02).start
    wait_for { s.status.consecutive_failures >= 2 }
    st = s.stop(timeout: 1)
    expect(st.last_error_class).to eq("Beagle::Turso::ClosedError")
    expect(st.running).to be(false)
  end
end
