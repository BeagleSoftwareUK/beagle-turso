require "beagle/turso"
require "logger"
require "stringio"
require "timeout"
require_relative "support/fake_database"

RSpec.describe "Beagle::Turso::Syncer background loop" do
  let(:db) { FakeDatabase.new }
  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  def wait_for(timeout = 2) = (deadline = now + timeout; sleep 0.005 until yield || now > deadline)

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
    s = Beagle::Turso::Syncer.new(db, interval: 1)
    s.start
    s.start
    expect(Thread.list.count { _1.name == "beagle-turso-syncer" }).to eq(1)
    s.stop(final_push: false)
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
