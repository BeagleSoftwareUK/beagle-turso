# Overhead benchmark for the statement GVL offload (Beagle::Turso.statement_gvl).
#
#   bundle exec ruby script/bench_statements.rb      # RUNS=3 by default
#
# Each case runs under both modes (:hold = the 0.3.0 code path, :release) on a
# fresh local temp database. Only the statement calls are timed. Per-run
# figures are reduced to the median across RUNS runs, and a Markdown table is
# printed.
require "beagle/turso"
require "async"
require "tmpdir"

RUNS = Integer(ENV.fetch("RUNS", "3"))
SELECTS = 10_000
WARMUP = 500
IMPORT_ROWS = 5_000
BATCH = 50
MODES = %i[hold release].freeze

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def median(a) = a.sort[a.size / 2]
def pct(a, p) = a.sort[[(a.size * p).ceil - 1, 0].max]

# Runs the block inside an Async reactor on a fresh thread.
def in_reactor(worker_pool)
  out = nil
  Thread.new do
    scheduler = Async::Scheduler.new(worker_pool: worker_pool)
    Fiber.set_scheduler(scheduler)
    scheduler.run { out = yield }
  end.join
  out
end

def with_db
  Dir.mktmpdir("bt_bench") do |dir|
    db = Beagle::Turso::Database.open_local(File.join(dir, "b.db"))
    yield db.connect
  end
end

def seeded(conn)
  conn.execute("CREATE TABLE t (x INTEGER)", [])
  conn.execute("BEGIN", [])
  1000.times { |i| conn.execute("INSERT INTO t (x) VALUES (?)", [i]) }
  conn.execute("COMMIT", [])
end

SELECT_SQL = "SELECT x FROM t WHERE rowid = ?".freeze

# Returns [median_us, p99_us] over SELECTS point selects, after a warm-up.
def select_timings(conn)
  WARMUP.times { |i| conn.query(SELECT_SQL, [i % 1000 + 1]) }
  times = Array.new(SELECTS) do |i|
    t = now
    conn.query(SELECT_SQL, [i % 1000 + 1])
    (now - t) * 1e6
  end
  [median(times), pct(times, 0.99)]
end

def select_case(kind)
  with_db do |conn|
    seeded(conn)
    case kind
    when :a then select_timings(conn)
    when :b then in_reactor(false) { select_timings(conn) }
    when :c then in_reactor(true) { select_timings(conn) }
    end
  end
end

# Returns seconds spent in statement calls for the import.
def import_case(kind)
  with_db do |conn|
    conn.execute("CREATE TABLE t (x INTEGER, y TEXT)", [])
    run = lambda do
      spent = 0.0
      timed = lambda do |sql, params|
        t = now
        conn.execute(sql, params)
        spent += now - t
      end
      timed.call("BEGIN", [])
      if kind == :d
        IMPORT_ROWS.times { |i| timed.call("INSERT INTO t (x, y) VALUES (?, ?)", [i, "row #{i}"]) }
      else
        sql = "INSERT INTO t (x, y) VALUES " + (["(?, ?)"] * BATCH).join(", ")
        (IMPORT_ROWS / BATCH).times do |b|
          timed.call(sql, Array.new(BATCH) { |j| [b * BATCH + j, "row"] }.flatten)
        end
      end
      timed.call("COMMIT", [])
      spent
    end
    in_reactor(true, &run)
  end
end

def warm_process
  with_db { |c| seeded(c); select_timings(c) }
  with_db { |c| c.execute("CREATE TABLE t (x INTEGER, y TEXT)", []); c.execute("INSERT INTO t VALUES (?, ?)", [1, "a"]) }
end

warm_process
res = Hash.new { |h, k| h[k] = [] }
RUNS.times do
  # Alternate mode order per run so drift doesn't favour one mode.
  order = res[:flip] = !res[:flip] ? MODES : MODES.reverse
  order.each do |mode|
    Beagle::Turso.statement_gvl = mode
    %i[a b c].each { |k| res[[k, mode]] << select_case(k) }
    %i[d e].each { |k| res[[k, mode]] << import_case(k) }
  end
end

def agg(runs, idx) = median(runs.map { |r| r[idx] })

puts "Ruby #{RUBY_VERSION}, beagle-turso #{Beagle::Turso::VERSION}, #{RUNS} runs (median of runs)"
puts
puts "| case | :hold median / p99 (us) | :release median / p99 (us) | median overhead (us) |"
puts "|---|---|---|---|"
{ a: "(a) 10k point selects, no scheduler",
  b: "(b) same, Async without worker pool",
  c: "(c) same, Async with worker pool" }.each do |k, label|
  h = res[[k, :hold]]
  r = res[[k, :release]]
  hm, hp = agg(h, 0), agg(h, 1)
  rm, rp = agg(r, 0), agg(r, 1)
  puts format("| %s | %.1f / %.1f | %.1f / %.1f | %+.1f |", label, hm, hp, rm, rp, rm - hm)
end
puts
puts "| case | :hold (s) | :release (s) | change |"
puts "|---|---|---|---|"
{ d: "(d) 5,000 single-row INSERTs, one txn, worker pool",
  e: "(e) 5,000 rows as 50-row multi-VALUES, one txn, worker pool" }.each do |k, label|
  h = median(res[[k, :hold]])
  r = median(res[[k, :release]])
  puts format("| %s | %.4f | %.4f | %+.1f%% |", label, h, r, (r - h) / h * 100)
end
