require "rbconfig"

RSpec.describe "Sequel::BeagleTurso single-writer handling" do
  let(:db) { Sequel.connect(adapter: :beagle_turso, database: tmp_db, max_connections: 4) }
  after { db.close_replica }
  before { db.create_table(:t) { Integer :n } }

  it "defaults explicit transactions to BEGIN IMMEDIATE" do
    sqls = []
    logger = Object.new
    logger.define_singleton_method(:info) { |m| sqls << m }
    %i[debug warn error].each { |l| logger.define_singleton_method(l) { |*| } }
    db.loggers << logger
    db.transaction { db[:t].insert(n: 1) }
    expect(sqls.any? { |s| s.include?("BEGIN IMMEDIATE") }).to be(true)
  end

  it "concurrent autocommit writers all succeed" do
    4.times.map { |k| Thread.new { 50.times { |i| db[:t].insert(n: k * 100 + i) } } }.each(&:join)
    expect(db[:t].count).to eq(200)
  end

  it "concurrent transactions all succeed (the second waits at BEGIN)" do
    4.times.map do |k|
      Thread.new do
        db.transaction do
          db[:t].insert(n: k)
          sleep 0.05
        end
      end
    end.each(&:join)
    expect(db[:t].count).to eq(4)
  end

  it "gives up after timeout: ms with DatabaseLockTimeout" do
    holder = db.turso_database.connect
    holder.execute_batch("BEGIN IMMEDIATE")
    fast = Sequel.connect(adapter: :beagle_turso, turso_database: db.turso_database, timeout: 150)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { fast[:t].insert(n: 1) }.to raise_error(Sequel::DatabaseLockTimeout)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
    expect(elapsed).to be_between(0.1, 1.0)
    holder.execute_batch("ROLLBACK")
    holder.close
    fast.disconnect
  end

  it "does not hold the GVL while waiting (other threads keep running)" do
    holder = db.turso_database.connect
    holder.execute_batch("BEGIN IMMEDIATE")
    ticks = 0
    ticker = Thread.new { loop { ticks += 1; Thread.pass } }
    waiter = Thread.new { db[:t].insert(n: 1) }
    sleep 0.2
    holder.execute_batch("COMMIT")
    holder.close
    waiter.join(5)
    ticker.kill.join
    expect(ticks).to be > 1_000
    expect(db[:t].count).to eq(1)
  end

  it "no retry inside a transaction: a stale snapshot surfaces as SerializationFailure and rolls back" do
    db[:t].insert(n: 0)
    other = db.turso_database.connect
    expect do
      db.transaction(mode: :deferred) do
        db[:t].all # take a read snapshot
        other.execute("INSERT INTO t (n) VALUES (1)", []) # another connection commits a write
        db[:t].insert(n: 2) # this write's snapshot is now stale
      end
    end.to raise_error(Sequel::SerializationFailure)
    other.close
    expect(db[:t].select_order_map(:n)).to eq([0, 1])
  end

  it "runs concurrent fibers with the fiber_concurrency extension (subprocess)" do
    script = File.expand_path("support/fiber_concurrency_check.rb", __dir__)
    out = IO.popen([RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), script, tmp_db], err: [:child, :out], &:read)
    expect($?.success?).to be(true), out
    expect(out).to include("rows=40")
  end
end
