require "beagle/turso"
require "timeout"
require "tmpdir"
require "open3"
require "rbconfig"

module StatementGvlSpec
  LONG_SQL = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 3000000) SELECT count(*) FROM c".freeze

  class << self
    attr_accessor :long_sql_time
  end
end

RSpec.describe "GVL release during statements" do
  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  around do |ex|
    Dir.mktmpdir("bt_stmt_gvl") do |dir|
      @dir = dir
      ex.run
    end
  end

  def open_db = Beagle::Turso::Database.open_local(File.join(@dir, "t.db"))

  # How long LONG_SQL takes on its own; measured once per process. The specs
  # that depend on a long statement skip, rather than fail, on a machine where
  # it is too quick to observe.
  def long_sql_time
    StatementGvlSpec.long_sql_time ||= begin
      conn = Beagle::Turso::Database.open_local(":memory:").connect
      started = now
      conn.query(StatementGvlSpec::LONG_SQL, [])
      now - started
    end
  end

  def require_long_sql!
    skip "LONG_SQL took #{long_sql_time.round(3)} s (< 0.3 s) on this machine" if long_sql_time < 0.3
  end

  def require_worker_pool!
    require "async"
    # Same guard as spec/gvl_spec.rb: blocking_operation_wait exists only when
    # the scheduler has a worker pool (io-event >= 1.11).
    skip "io-event has no WorkerPool" unless defined?(Async::Scheduler::WorkerPool) && Async::Scheduler::WorkerPool
    skip "Ruby #{RUBY_VERSION} ignores RB_NOGVL_OFFLOAD_SAFE (needs >= 3.4)" if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.4")
  end

  # Runs the block on a fresh thread under an explicit worker-pool scheduler,
  # so the result doesn't depend on ASYNC_SCHEDULER_WORKER_POOL or load order.
  def with_worker_pool_scheduler(&blk)
    Thread.new do
      scheduler = Async::Scheduler.new(worker_pool: true)
      Fiber.set_scheduler(scheduler)
      scheduler.run(&blk)
    end.join
  end

  # Runs LONG_SQL under the worker-pool scheduler beside a 10 ms ticker fiber.
  # Returns [ticks, elapsed].
  def ticks_during_long_query(conn)
    ticks = 0
    elapsed = nil
    with_worker_pool_scheduler do
      ticker = Async { loop { ticks += 1; sleep 0.01 } }
      started = now
      conn.query(StatementGvlSpec::LONG_SQL, [])
      elapsed = now - started
      ticker.stop
    end
    [ticks, elapsed]
  end

  it "lets other threads run during a long query" do
    require_long_sql!
    conn = open_db.connect
    ticks = 0
    ticker = Thread.new { loop { ticks += 1; Thread.pass } }
    expect(conn.query(StatementGvlSpec::LONG_SQL, [])).to eq([[3_000_000]])
    ticker.kill.join
    expect(ticks).to be > 1_000
  end

  it "keeps an Async reactor responsive during a long query" do
    require_worker_pool!
    require_long_sql!
    ticks, elapsed = ticks_during_long_query(open_db.connect)
    expect(ticks).to be >= 0.5 * (elapsed / 0.01)
  end

  it "a second fiber's query on its own connection completes after the long one" do
    require_worker_pool!
    require_long_sql!
    db = open_db
    conn_a = db.connect
    conn_b = db.connect
    ticks = 0
    a_done = b_done = b_result = nil
    started = nil
    Timeout.timeout(30) do
      with_worker_pool_scheduler do
        ticker = Async { loop { ticks += 1; sleep 0.01 } }
        started = now
        a = Async { conn_a.query(StatementGvlSpec::LONG_SQL, []); a_done = now }
        b = Async do
          sleep 0.05
          b_result = conn_b.query("SELECT 1", [])
          b_done = now
        end
        [a, b].each(&:wait)
        ticker.stop
      end
    end
    expect(b_result).to eq([[1]])
    expect(b_done).to be >= a_done - 0.05 # statements on one Database are serialised
    expect(ticks).to be >= 0.5 * ((a_done - started) / 0.01)
  end

  it "parallel thread inserts on separate connections never raise BusyError" do
    db = open_db
    db.connect.execute("CREATE TABLE t (n INTEGER)", [])
    threads = 8.times.map do |i|
      conn = db.connect
      Thread.new do
        200.times { |j| conn.execute("INSERT INTO t (n) VALUES (?)", [i * 1_000 + j]) }
      end
    end
    threads.each(&:join) # re-raises any BusyError
    expect(db.connect.query("SELECT count(*) FROM t", [])).to eq([[1_600]])
  end

  it "Timeout during a long query is delivered after it returns and the connection still works" do
    require_long_sql!
    conn = open_db.connect
    started = now
    expect { Timeout.timeout(0.05) { conn.query(StatementGvlSpec::LONG_SQL, []) } }.to raise_error(Timeout::Error)
    expect(now - started).to be >= long_sql_time * 0.8
    expect(conn.query("SELECT 1", [])).to eq([[1]])
  end

  describe "errors keep their class and message" do
    def error_of
      yield
      nil
    rescue => e
      [e.class, e.message]
    end

    # Each case runs once with the GVL released and once held; the class and
    # message must be identical (i.e. byte-for-byte what 0.3.0 raised).
    def both_modes(&blk)
      Beagle::Turso.statement_gvl = :release
      released = error_of(&blk)
      Beagle::Turso.statement_gvl = :hold
      held = error_of(&blk)
      [released, held]
    ensure
      Beagle::Turso.statement_gvl = :release
    end

    it "for a syntax error" do
      conn = open_db.connect
      %i[query query_result query_result_with_types execute].each do |m|
        released, held = both_modes { conn.public_send(m, "SELEC nonsense", []) }
        expect(released.first).to eq(Beagle::Turso::QueryError)
        expect(released.last).to start_with("query failed: ")
        expect(released).to eq(held)
      end
      released, held = both_modes { conn.execute_batch("SELEC nonsense;") }
      expect(released.first).to eq(Beagle::Turso::QueryError)
      expect(released).to eq(held)
    end

    it "for a UNIQUE violation" do
      conn = open_db.connect
      conn.execute("CREATE TABLE u (id INTEGER PRIMARY KEY, k TEXT UNIQUE)", [])
      conn.execute("INSERT INTO u (k) VALUES ('a')", [])
      released, held = both_modes { conn.execute("INSERT INTO u (k) VALUES ('a')", []) }
      expect(released.first).to eq(Beagle::Turso::QueryError)
      expect(released.last).to match(/UNIQUE/i)
      expect(released).to eq(held)
    end

    it "for a closed connection" do
      conn = open_db.connect
      conn.close
      %i[query query_result query_result_with_types execute].each do |m|
        released, held = both_modes { conn.public_send(m, "SELECT 1", []) }
        expect(released).to eq([Beagle::Turso::ClosedError, "database is closed"])
        expect(released).to eq(held)
      end
      expect(both_modes { conn.execute_batch("SELECT 1;") }.uniq)
        .to eq([[Beagle::Turso::ClosedError, "database is closed"]])
    end

    it "for an unsupported bind parameter (converted before the GVL is released)" do
      conn = open_db.connect
      released, held = both_modes { conn.query("SELECT ?", [Object.new]) }
      expect(released).to eq([::TypeError, "unsupported bind parameter type"])
      expect(released).to eq(held)
    end

    it "for an inherited connection in a forked child" do
      skip "fork unsupported on this platform" unless Process.respond_to?(:fork)
      conn = open_db.connect
      rd, wr = IO.pipe
      pid = fork do
        rd.close
        begin
          conn.query("SELECT 1", [])
          wr.write("no error")
        rescue Beagle::Turso::ForkedError => e
          wr.write("forked:#{e.message}")
        rescue => e
          wr.write("other #{e.class}")
        end
        wr.close
        exit!(0)
      end
      wr.close
      Timeout.timeout(10) { Process.wait(pid) }
      expect(rd.read).to match(/\Aforked:database opened in process \d+ used after fork in process \d+; open a new database in the child\z/)
      expect(conn.query("SELECT 1", [])).to eq([[1]])
    end
  end

  it "statement_gvl = :hold keeps the reactor blocked" do
    require_worker_pool!
    require_long_sql!
    begin
      Beagle::Turso.statement_gvl = :hold
      expect(Beagle::Turso.statement_gvl).to eq(:hold)
      ticks, _elapsed = ticks_during_long_query(open_db.connect)
      expect(ticks).to be < 5
    ensure
      Beagle::Turso.statement_gvl = :release
    end
    expect(Beagle::Turso.statement_gvl).to eq(:release)
  end

  it "statement_gvl rejects other values" do
    expect { Beagle::Turso.statement_gvl = :foo }
      .to raise_error(ArgumentError, "statement_gvl must be :hold or :release")
    expect(Beagle::Turso.statement_gvl).to eq(:release)
  end

  it "BEAGLE_TURSO_STATEMENT_GVL=hold is read at load" do
    lib = File.expand_path("../lib", __dir__)
    cmd = [RbConfig.ruby, "-I", lib, "-rbeagle/turso", "-e", "print Beagle::Turso.statement_gvl"]
    held, status = Open3.capture2({"BEAGLE_TURSO_STATEMENT_GVL" => "hold"}, *cmd)
    expect(status).to be_success
    expect(held).to eq("hold")
    released, status = Open3.capture2({"BEAGLE_TURSO_STATEMENT_GVL" => nil}, *cmd)
    expect(status).to be_success
    expect(released).to eq("release")
  end
end
