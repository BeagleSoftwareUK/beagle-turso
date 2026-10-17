require "beagle/turso"
require "logger"
require "stringio"
require_relative "support/fake_database"

RSpec.describe Beagle::Turso::Syncer do
  let(:db) { FakeDatabase.new }

  describe ".new" do
    it "rejects a local-only database" do
      expect { described_class.new(FakeDatabase.new(synced: false)) }
        .to raise_error(Beagle::Turso::NotSyncedError, /synced database/)
    end

    it "rejects a non-positive interval or a cap below the interval" do
      expect { described_class.new(db, interval: 0) }.to raise_error(ArgumentError)
      expect { described_class.new(db, interval: 10, max_backoff: 5) }.to raise_error(ArgumentError)
    end

    it "starts no thread" do
      before = Thread.list
      s = described_class.new(db)
      expect(s.instance_variable_get(:@thread)).to be_nil
      expect((Thread.list - before).none? { _1.name == "beagle-turso-syncer" }).to be(true)
      expect(s.running?).to be(false)
    end
  end

  describe "#sync_now" do
    it "pushes then pulls and records both timestamps" do
      s = described_class.new(db)
      expect(s.sync_now).to eq(:ok)
      expect(db.calls).to eq(%i[push pull])
      st = s.status
      expect(st.last_push_at).to be_a(Time)
      expect(st.last_pull_at).to be_a(Time)
      expect(st.consecutive_failures).to eq(0)
      expect(st.syncing).to be(false)
      expect(st.destination).to eq("db-acme.turso.io")
    end

    it "skips pull when pull: false" do
      described_class.new(db, pull: false).sync_now
      expect(db.calls).to eq(%i[push])
    end

    it "skips the pull when the push fails, records the failure and re-raises" do
      db.on_push = -> { raise Beagle::Turso::SyncError, "sync failed: boom" }
      s = described_class.new(db)
      expect { s.sync_now }.to raise_error(Beagle::Turso::SyncError)
      expect(db.calls).to eq(%i[push])
      st = s.status
      expect(st.consecutive_failures).to eq(1)
      expect(st.last_error_class).to eq("Beagle::Turso::SyncError")
      expect(st.last_error_message).to eq("sync failed: boom")
      expect(st.last_error_at).to be_a(Time)
      expect(st.last_push_at).to be_nil
    end

    it "resets the failure count on success but keeps the last error" do
      fail_once = true
      db.on_push = -> { if fail_once then fail_once = false; raise Beagle::Turso::SyncError, "x" end }
      s = described_class.new(db)
      expect { s.sync_now }.to raise_error(Beagle::Turso::SyncError)
      expect(s.sync_now).to eq(:ok)
      expect(s.status.consecutive_failures).to eq(0)
      expect(s.status.last_error_class).to eq("Beagle::Turso::SyncError")
    end

    it "returns :busy without waiting while another cycle runs (concurrent sync_now)" do
      gate = Queue.new
      db.on_push = -> { gate.pop }
      s = described_class.new(db)
      first = Thread.new { s.sync_now }
      Thread.pass until s.status.syncing
      results = 3.times.map { Thread.new { s.sync_now } }.map(&:value)
      gate << :go
      expect(first.value).to eq(:ok)
      expect(results).to all(eq(:busy))
      expect(db.pushes).to eq(1)
    end

    it "redacts failure text in status, log and on_error" do
      db.on_push = -> { raise Beagle::Turso::SyncError, "sync failed: libsql://db-acme.turso.io/v1?authToken=SECRET9" }
      log = StringIO.new
      seen = nil
      s = described_class.new(db, logger: Logger.new(log), on_error: ->(e, st) { seen = st })
      expect { s.sync_now }.to raise_error(Beagle::Turso::SyncError)
      expect(s.status.last_error_message).to eq("sync failed: libsql://db-acme.turso.io")
      expect(seen.last_error_message).to eq("sync failed: libsql://db-acme.turso.io")
      expect(log.string).to include("sync failed: libsql://db-acme.turso.io")
      expect(log.string.include?("SECRET9")).to be(false)
    end

    it "passes the error and a frozen status to on_error" do
      db.on_push = -> { raise Beagle::Turso::SyncError, "x" }
      got = nil
      s = described_class.new(db, on_error: ->(e, st) { got = [e, st] })
      expect { s.sync_now }.to raise_error(Beagle::Turso::SyncError)
      expect(got[0]).to be_a(Beagle::Turso::SyncError)
      expect(got[1]).to be_frozen
      expect(got[1].consecutive_failures).to eq(1)
    end

    it "hands on_error and the caller a redacted copy of the error, same class and backtrace" do
      db.on_push = -> { raise Beagle::Turso::SyncError, "sync failed: libsql://h.io/x?authToken=SECRETZ" }
      seen = nil
      s = described_class.new(db, on_error: ->(e, _) { seen = e })
      raised = begin
        s.sync_now
        nil
      rescue Beagle::Turso::SyncError => e
        e
      end
      expect(raised).to be_a(Beagle::Turso::SyncError)
      expect(seen).to be_a(Beagle::Turso::SyncError)
      expect(raised.message.include?("SECRETZ")).to be(false)
      expect(seen.message.include?("SECRETZ")).to be(false)
      expect(raised.message).to eq("sync failed: libsql://h.io")
      expect(raised.cause).to be_nil
      expect(raised.backtrace).to be_an(Array)
      expect(raised.backtrace.join("\n")).to include("fake_database.rb")
    end

    it "passes the original error through when there is nothing to redact" do
      original = Beagle::Turso::SyncError.new("sync failed: boom")
      db.on_push = -> { raise original }
      seen = nil
      s = described_class.new(db, on_error: ->(e, _) { seen = e })
      expect { s.sync_now }.to raise_error { |e| expect(e).to equal(original) }
      expect(seen).to equal(original)
    end

    it "still reports to on_error and re-raises the sync error when the logger raises" do
      bad_logger = Class.new { def warn(*) = raise(IOError, "closed stream") }.new
      db.on_push = -> { raise Beagle::Turso::SyncError, "real failure" }
      calls = 0
      s = described_class.new(db, logger: bad_logger, on_error: ->(*) { calls += 1 })
      expect { s.sync_now }.to raise_error(Beagle::Turso::SyncError, "real failure")
      expect(calls).to eq(1)
      expect(s.status.consecutive_failures).to eq(1)
    end

    it "records a frozen message and names anonymous error classes" do
      anon = Class.new(StandardError)
      db.on_push = -> { raise anon, "x" }
      s = described_class.new(db)
      expect { s.sync_now }.to raise_error(anon)
      st = s.status
      expect(st.last_error_message).to be_frozen
      expect(st.last_error_class).to be_a(String)
      expect(st.last_error_class).to start_with("#<Class:")
    end

    it "releases the cycle lock even if clearing the syncing flag raises" do
      s = described_class.new(db)
      armed = true
      allow(s).to receive(:set_syncing).and_wrap_original do |m, value|
        m.call(value)
        if !value && armed
          armed = false
          raise "flag update failed"
        end
      end
      expect { s.sync_now }.to raise_error(RuntimeError, "flag update failed")
      expect(s.status.syncing).to be(false)
      expect(s.sync_now).to eq(:ok)
    end
  end

  describe "#status" do
    it "is a frozen snapshot with no credentials" do
      st = described_class.new(db).status
      expect(st).to be_frozen
      expect(st.to_h.values.compact.map(&:to_s).join(" ")).not_to match(/token/i)
    end
  end

  describe "retry delay" do
    let(:s) { described_class.new(db, interval: 10, max_backoff: 100, random: Random.new(1)) }

    it "doubles per consecutive failure within ±20% jitter" do
      [[1, 20], [2, 40], [3, 80]].each do |n, base|
        d = s.send(:retry_delay, n)
        expect(d).to be_between(base * 0.8, base * 1.2)
      end
    end

    it "caps at max_backoff (±20%)" do
      expect(s.send(:retry_delay, 10)).to be_between(80, 120)
    end

    it "clamps the exponent so a long outage builds no bignum" do
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(s.send(:retry_delay, 1_000_000_000)).to be_between(80, 120)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t).to be < 0.1
    end
  end
end
