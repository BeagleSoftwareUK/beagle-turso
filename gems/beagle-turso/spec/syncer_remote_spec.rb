require "beagle/turso"

RSpec.describe "Syncer against a real remote" do
  let(:url) { ENV["TURSO_DATABASE_URL"] }
  let(:token) { ENV["TURSO_AUTH_TOKEN"] }
  let(:path) { "/tmp/bt_syncer_#{Process.pid}_#{rand(1_000_000)}.db" }
  before { skip "no TURSO creds" if url.to_s.empty? || token.to_s.empty? }
  after { Dir.glob("#{path}*").each { |f| File.delete(f) rescue nil } }

  it "pushes a write in the background and reports a clean status" do
    db = Beagle::Turso::Database.open(local_path: path, remote_url: url, auth_token: token)
    conn = db.connect
    conn.execute("CREATE TABLE IF NOT EXISTS syncer_probe (marker TEXT)", [])
    marker = "syncer-#{Process.pid}-#{rand(1_000_000)}"
    conn.execute("INSERT INTO syncer_probe VALUES (?)", [marker])

    s = Beagle::Turso::Syncer.new(db, interval: 0.2).start
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    sleep 0.05 until s.status.last_push_at || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    st = s.stop(timeout: 10)
    db.close

    expect(st.last_push_at).to be_a(Time)
    expect(st.consecutive_failures).to eq(0)
    expect(st.destination).to eq(Beagle::Turso::Redaction.host(url))
    expect(st.to_h.values.compact.map(&:to_s).join(" ")).not_to include(token)

    fresh = Beagle::Turso::Database.open(local_path: "#{path}-fresh", remote_url: url, auth_token: token)
    fresh.pull
    n = fresh.connect.query("SELECT count(*) FROM syncer_probe WHERE marker = ?", [marker]).first.first
    fresh.close
    expect(n).to eq(1)
  end
end
