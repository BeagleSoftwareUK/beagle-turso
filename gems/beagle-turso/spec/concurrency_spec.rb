require "beagle/turso"

RSpec.describe "concurrency contract" do
  def tmp
    path = "/tmp/bt_cc_#{Process.pid}_#{rand(1_000_000)}.db"
    (@tmp_paths ||= []) << path
    path
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  after { Array(@tmp_paths).each { |p| Dir.glob("#{p}*").each { |f| File.delete(f) rescue nil } } }

  it "serves threads that each own a connection to one database" do
    db = Beagle::Turso::Database.open_local(tmp)
    db.connect.execute("CREATE TABLE t (n INTEGER)", [])
    4.times.map { |i|
      Thread.new { c = db.connect; 100.times { |j| c.execute("INSERT INTO t VALUES (?)", [i * 1000 + j]) } }
    }.each(&:join)
    expect(db.connect.query("SELECT count(*) FROM t", [])).to eq([[400]])
  end

  it "serializes threads sharing one connection" do
    conn = Beagle::Turso::Database.open_local(tmp).connect
    conn.execute("CREATE TABLE t (n INTEGER)", [])
    4.times.map { |i|
      Thread.new { 100.times { |j| conn.execute("INSERT INTO t VALUES (?)", [i * 1000 + j]) } }
    }.each(&:join)
    expect(conn.query("SELECT count(*) FROM t", [])).to eq([[400]])
  end

  describe "against a real remote" do
    let(:url) { ENV["TURSO_DATABASE_URL"] }
    let(:token) { ENV["TURSO_AUTH_TOKEN"] }
    before { skip "no TURSO creds" if url.to_s.empty? || token.to_s.empty? }

    it "keeps closed?, connect and queries fast while another thread pushes" do
      db = Beagle::Turso::Database.open(local_path: tmp, remote_url: url, auth_token: token)
      conn = db.connect
      conn.execute("CREATE TABLE IF NOT EXISTS cc (payload TEXT)", [])
      200.times { conn.execute("INSERT INTO cc VALUES (?)", ["x" * 1024]) }

      push_time = nil
      pusher = Thread.new { t = now; db.push; push_time = now - t }
      worst = { closed: 0.0, connect: 0.0, query: 0.0 }
      while pusher.alive?
        t = now; db.closed?; worst[:closed] = [worst[:closed], now - t].max
        t = now; db.connect.close; worst[:connect] = [worst[:connect], now - t].max
        t = now; conn.query("SELECT count(*) FROM cc", []); worst[:query] = [worst[:query], now - t].max
      end
      pusher.join
      puts "C1/C2 push=#{push_time.round(3)}s worst=#{worst.transform_values { _1.round(4) }}"

      expect(worst[:closed]).to be < 0.05
      # Synced connect waits inside turso for an in-flight push (engine behaviour, not our locks); the GVL is released while it waits.
      expect(worst[:connect]).to be < push_time + 0.1
      # C1: record the query figure in Task 8's README text. If it is about
      # push_time, the engine serializes queries behind push: STOP and report.
      expect(worst[:query]).to be < [push_time * 0.5, 0.05].max
      db.close
    end

    it "lets close race an in-flight push without crashing" do
      db = Beagle::Turso::Database.open(local_path: tmp, remote_url: url, auth_token: token)
      db.connect.execute("CREATE TABLE IF NOT EXISTS cc (payload TEXT)", [])
      pusher = Thread.new { db.push; :pushed rescue $! }
      sleep 0.01
      db.close
      result = pusher.value
      expect(result == :pushed || result.is_a?(Beagle::Turso::Error)).to be(true)
      expect { db.push }.to raise_error(Beagle::Turso::ClosedError)
    end
  end
end
