require "beagle/turso"

RSpec.describe "synced mode" do
  it "pushes a local write and a fresh replica pulls it" do
    url = ENV["TURSO_DATABASE_URL"]
    token = ENV["TURSO_AUTH_TOKEN"]
    skip "no TURSO creds" if url.nil? || url.empty? || token.nil? || token.empty?

    marker = "gem-#{Process.pid}-#{rand(1_000_000)}"
    a = "/tmp/bt_a_#{marker}.db"
    b = "/tmp/bt_b_#{marker}.db"

    da = Beagle::Turso::Database.open(local_path: a, remote_url: url, auth_token: token)
    ca = da.connect
    ca.execute("CREATE TABLE IF NOT EXISTS m (name TEXT)", [])
    ca.execute("INSERT INTO m (name) VALUES (?)", [marker])
    expect(da.push).to be_nil

    db = Beagle::Turso::Database.open(local_path: b, remote_url: url, auth_token: token)
    db.pull
    n = db.connect.query("SELECT count(*) FROM m WHERE name = ?", [marker]).first.first
    expect(n).to eq(1)
  end

  it "raises when push/pull is called on a local-only database" do
    db = Beagle::Turso::Database.open_local(":memory:")
    expect { db.push }.to raise_error(RuntimeError, /push/)
    expect { db.pull }.to raise_error(RuntimeError, /pull/)
  end
end
