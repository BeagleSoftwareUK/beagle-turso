require "beagle/turso"

RSpec.describe "close releases the database" do
  # Local, no-credentials coverage of the close contract: close is idempotent
  # and closed? flips. Always runs.
  it "closes a local database and reports closed?" do
    db = Beagle::Turso::Database.open_local(":memory:")
    conn = db.connect
    expect(db.closed?).to be(false)
    expect(conn.closed?).to be(false)

    conn.close
    expect(conn.closed?).to be(true)

    db.close
    expect(db.closed?).to be(true)

    # Idempotent: a second close must not raise.
    expect { conn.close }.not_to raise_error
    expect { db.close }.not_to raise_error
  end

  # Regression: a *synced* Database opens a server-side sync session. Before the
  # fix there was no explicit close, so each open leaked a session on the remote
  # until it reported "database is busy". This proves close releases the session,
  # so a fresh open + connect on the same local_path succeeds instead of failing
  # busy. Gated on TURSO creds exactly like sync_spec.rb; skips cleanly when
  # unset (the controller runs the live synced verification separately).
  it "releases a synced session so the next open on the same path is not busy" do
    url = ENV["TURSO_DATABASE_URL"]
    token = ENV["TURSO_AUTH_TOKEN"]
    skip "no TURSO creds" if url.nil? || url.empty? || token.nil? || token.empty?

    marker = "close-#{Process.pid}-#{rand(1_000_000)}"
    path = "/tmp/bt_close_#{marker}.db"

    db1 = Beagle::Turso::Database.open(local_path: path, remote_url: url, auth_token: token)
    conn1 = db1.connect
    conn1.execute("CREATE TABLE IF NOT EXISTS m (name TEXT)", [])
    conn1.execute("INSERT INTO m (name) VALUES (?)", [marker])
    db1.push
    db1.close
    expect(db1.closed?).to be(true)

    # If close did not release the remote sync session, this second open on the
    # same local_path would eventually report "database is busy".
    db2 = Beagle::Turso::Database.open(local_path: path, remote_url: url, auth_token: token)
    conn2 = db2.connect
    n = conn2.query("SELECT count(*) FROM m WHERE name = ?", [marker]).first.first
    expect(n).to eq(1)
    db2.close
  end
end
