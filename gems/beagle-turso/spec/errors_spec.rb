require "beagle/turso"

RSpec.describe "exception classes" do
  it "roots every driver error at Beagle::Turso::Error, a RuntimeError" do
    %i[OpenError ConnectError QueryError SyncError NotSyncedError BusyError
       ClosedError ForkedError].each do |name|
      expect(Beagle::Turso.const_get(name).ancestors).to include(Beagle::Turso::Error, RuntimeError)
    end
  end

  it "raises NotSyncedError with the 0.1 message on local-only push/pull" do
    db = Beagle::Turso::Database.open_local(":memory:")
    expect { db.push }.to raise_error(Beagle::Turso::NotSyncedError, "sync failed: push() on a local-only database")
    expect { db.pull }.to raise_error(Beagle::Turso::NotSyncedError, "sync failed: pull() on a local-only database")
  end

  it "raises QueryError for bad SQL" do
    conn = Beagle::Turso::Database.open_local(":memory:").connect
    expect { conn.query("SELEC nonsense", []) }.to raise_error(Beagle::Turso::QueryError)
  end

  it "raises ClosedError after close" do
    db = Beagle::Turso::Database.open_local(":memory:")
    conn = db.connect
    conn.close
    db.close
    expect { db.connect }.to raise_error(Beagle::Turso::ClosedError)
    expect { conn.query("SELECT 1", []) }.to raise_error(Beagle::Turso::ClosedError)
  end

  it "still raises Ruby's TypeError for an unsupported bind parameter (0.1.x compatible)" do
    conn = Beagle::Turso::Database.open_local(":memory:").connect
    expect { conn.query("SELECT ?", [Object.new]) }.to raise_error(::TypeError, /unsupported bind parameter type/)
  end

  it "keeps every 0.1.x driver error rescuable as RuntimeError" do
    db = Beagle::Turso::Database.open_local(":memory:")
    expect { db.push }.to raise_error(RuntimeError)
    expect { db.connect.query("SELEC nonsense", []) }.to raise_error(RuntimeError)
  end

  it "raises OpenError for an unusable remote URL" do
    expect {
      Beagle::Turso::Database.open(local_path: "/tmp/bt_err_#{Process.pid}.db", remote_url: "not-a-scheme://x", auth_token: "t")
    }.to raise_error(Beagle::Turso::OpenError)
  end
end
