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
      before = Thread.list.size
      described_class.new(db)
      expect(Thread.list.size).to eq(before)
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
      expect(log.string).not_to include("SECRET9")
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
  end
end
