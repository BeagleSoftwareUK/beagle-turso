# activerecord-beagle-turso Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `activerecord-beagle-turso`, an ActiveRecord adapter (`adapter: beagle_turso`) that runs Rails on Turso's new engine via the `beagle-turso` gem — subclassing `SQLite3Adapter`, plus a SyncManager driven by a Solid Queue recurring job.

**Architecture:** `BeagleTursoAdapter < ActiveRecord::ConnectionAdapters::SQLite3Adapter`. It supplies a `beagle-turso` `Connection` as `@raw_connection` and overrides only the execution path (`perform_query`, `cast_result`, `affected_rows`, `last_inserted_id`, `execute_batch`) and connection lifecycle (`connect`/`new_client`/pragma config), inheriting SQLite type mapping, quoting, and schema statements. The adapter needs three primitives the lower layers don't yet expose, so this plan first extends `beagle_turso_core` and `beagle-turso`, then builds the adapter.

**Tech Stack:** ActiveRecord 8.1.3.1, `beagle-turso` (this repo), `beagle_turso_core` (this repo), turso 0.7.2, RSpec + Minitest (AR shared suite), Solid Queue.

## Global Constraints

- Adapter registers as `adapter: beagle_turso` and subclasses `ActiveRecord::ConnectionAdapters::SQLite3Adapter` (Rails 8.1). Override the minimum; inherit the rest.
- No credential logging — the token invariant from Plans 1/2 must hold through the adapter (creds come from `database.yml` via credentials/ENV; never logged).
- Lower-layer additions keep existing public APIs backward compatible (Plan 2's `query -> Array<Array>` and Plan 1's `Connection::query -> Vec<Row>` must not break; add new methods rather than change return types).
- `turso = "=0.7.2"` stays pinned. Non-deprecated Magnus.
- **External-API note:** verify exact AR internals against the installed source before implementing each adapter task: `activerecord-8.1.3.1/lib/active_record/connection_adapters/sqlite3/database_statements.rb` (`perform_query` line 86, `cast_result` 136, `affected_rows` 142, `execute_batch` 146) and `sqlite3_adapter.rb` (`connect` 838, `new_client` 50). Keep the adapter's own method names as specified; adjust bodies to the real inherited signatures.
- Every task ends green (its layer's suite) and with a commit.

---

## File Structure

- `crates/beagle_turso_core/src/lib.rs` — add `QueryResult { columns, rows }` (or `query` returning columns), `last_insert_rowid()`, `execute_batch()`.
- `gems/beagle-turso/ext/beagle_turso/src/lib.rs` — expose the three primitives to Ruby.
- `gems/activerecord-beagle-turso/` (new gem):
  - `activerecord-beagle-turso.gemspec`, `Gemfile`, `lib/active_record/connection_adapters/beagle_turso_adapter.rb`, `lib/activerecord/beagle_turso/version.rb`, `lib/activerecord-beagle-turso.rb` (register adapter).
  - `lib/active_record/connection_adapters/beagle_turso/sync_manager.rb`, plus a Railtie/generator for the Solid Queue recurring job.
  - `spec/` (unit) + `test/` (a dummy Rails app + the AR shared adapter suite).

---

## Task 1: Core — column names in query results

**Files:** `crates/beagle_turso_core/src/lib.rs`, `crates/beagle_turso_core/tests/local.rs`

**Interfaces:**
- Produces: `pub struct QueryResult { pub columns: Vec<String>, pub rows: Vec<Row> }`; `Connection::query_result(&self, sql: &str, params: &[Value]) -> Result<QueryResult>`. Keep the existing `query -> Result<Vec<Row>>` (implement it via `query_result`).

- [ ] **Step 1: Write the failing test** (`tests/local.rs`)

```rust
#[test]
fn query_result_exposes_column_names() {
    let db = Database::open(OpenOptions::default()).unwrap();
    let conn = db.connect().unwrap();
    conn.execute("CREATE TABLE t (id INTEGER, name TEXT)", &[]).unwrap();
    conn.execute("INSERT INTO t (id, name) VALUES (?, ?)", &[Value::Integer(1), Value::Text("a".into())]).unwrap();
    let r = conn.query_result("SELECT id, name FROM t", &[]).unwrap();
    assert_eq!(r.columns, vec!["id".to_string(), "name".to_string()]);
    assert_eq!(r.rows[0].values, vec![Value::Integer(1), Value::Text("a".into())]);
}
```

- [ ] **Step 2: Run — fails** (`query_result` undefined). `cargo test --test local query_result_exposes_column_names`.

- [ ] **Step 3: Implement** — add `QueryResult` and `query_result`; read column names from the turso `Rows`. Confirm the turso 0.7.2 API for column names on a `Rows`/statement (e.g. `rows.column_name(i)` or `rows.columns()`); the query loop already reads `row.get_value(i)` for `0..column_count`, so capture names once before iterating rows.

```rust
pub struct QueryResult {
    pub columns: Vec<String>,
    pub rows: Vec<Row>,
}

impl Connection {
    pub fn query_result(&self, sql: &str, params: &[Value]) -> Result<QueryResult> {
        let tparams: Vec<turso::Value> = params.iter().map(Value::to_turso).collect();
        self.rt.block_on(async {
            let mut rows = self.conn.query(sql, tparams).await.map_err(|e| Error::Query(e.to_string()))?;
            // confirm: how to read column names from `rows` in turso 0.7.2
            let columns: Vec<String> = /* rows.columns()/column_name(i) */ Vec::new();
            let mut out = Vec::new();
            while let Some(row) = rows.next().await.map_err(|e| Error::Query(e.to_string()))? {
                let n = row.column_count();
                let mut vals = Vec::with_capacity(n);
                for i in 0..n { vals.push(Value::from_turso(row.get_value(i).map_err(|e| Error::Query(e.to_string()))?)); }
                out.push(Row { values: vals });
            }
            Ok(QueryResult { columns, rows: out })
        })
    }

    pub fn query(&self, sql: &str, params: &[Value]) -> Result<Vec<Row>> {
        Ok(self.query_result(sql, params)?.rows)
    }
}
```
If turso only exposes column names on the `Rows` before iteration, capture them there; if it needs a prepared `Statement`, prepare + read `column_name` then step. Implementer confirms against docs.rs/turso/0.7.2.

- [ ] **Step 4: Run** — `cargo test --test local` green (new + existing). **Step 5: Commit** `feat(core): expose column names via query_result`.

---

## Task 2: Core — `last_insert_rowid` + `execute_batch`

**Files:** `crates/beagle_turso_core/src/lib.rs`, `tests/local.rs`

**Interfaces:**
- Produces: `Connection::last_insert_rowid(&self) -> Result<i64>`; `Connection::execute_batch(&self, sql: &str) -> Result<()>` (runs a script of multiple `;`-separated statements, for schema/DDL).

- [ ] **Step 1: Failing test**

```rust
#[test]
fn last_rowid_and_batch() {
    let db = Database::open(OpenOptions::default()).unwrap();
    let c = db.connect().unwrap();
    c.execute_batch("CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT); INSERT INTO t (n) VALUES ('x');").unwrap();
    assert_eq!(c.last_insert_rowid().unwrap(), 1);
    c.execute("INSERT INTO t (n) VALUES (?)", &[Value::Text("y".into())]).unwrap();
    assert_eq!(c.last_insert_rowid().unwrap(), 2);
}
```

- [ ] **Step 2: Run — fails.** **Step 3: Implement** — confirm turso 0.7.2 exposes `last_insert_rowid` on the connection and a batch/execute-script call; if no native batch, split on `;` and `execute` each non-empty statement (naive splitter is acceptable for DDL — document the limitation).

```rust
impl Connection {
    pub fn last_insert_rowid(&self) -> Result<i64> {
        self.rt.block_on(async { /* self.conn.last_insert_rowid() — confirm name */ Ok(0) })
    }
    pub fn execute_batch(&self, sql: &str) -> Result<()> {
        for stmt in sql.split(';').map(str::trim).filter(|s| !s.is_empty()) {
            self.execute(stmt, &[])?;
        }
        Ok(())
    }
}
```

- [ ] **Step 4: Run green. Step 5: Commit** `feat(core): last_insert_rowid + execute_batch`.

---

## Task 3: Gem — expose the three primitives to Ruby

**Files:** `gems/beagle-turso/ext/beagle_turso/src/lib.rs`, `gems/beagle-turso/spec/*`

**Interfaces:**
- Produces (Ruby): `Connection#query_result(sql, params=[]) -> [columns_array, rows_array]`; `Connection#last_insert_rowid -> Integer`; `Connection#execute_batch(sql) -> nil`.

- [ ] **Step 1: Failing spec** (`spec/adapter_primitives_spec.rb`)

```ruby
require "beagle/turso"
RSpec.describe "adapter primitives" do
  it "returns columns + rows, rowid, and batch" do
    c = Beagle::Turso::Database.open_local(":memory:").connect
    c.execute_batch("CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT); INSERT INTO t (n) VALUES ('a');")
    cols, rows = c.query_result("SELECT id, n FROM t", [])
    expect(cols).to eq(["id", "n"])
    expect(rows).to eq([[1, "a"]])
    expect(c.last_insert_rowid).to eq(1)
  end
end
```

- [ ] **Step 2: Run — fails.** **Step 3: Implement** the three ext methods, reusing the proven `value_to_ruby`/`ruby_array_to_params` helpers. `query_result` returns a 2-element `RArray` `[columns, rows]` (columns as an array of Ruby strings). Register with `method!(..., N)`. `rake compile`.

- [ ] **Step 4: Run** `bundle exec rake compile && bundle exec rspec` green (all prior specs unchanged; `query` still returns `Array<Array>`). **Step 5: Commit** `feat(gem): query_result (columns+rows), last_insert_rowid, execute_batch`.

---

## Task 4: Adapter — subclass + execution path (the crux; proves migrate + CRUD)

**Files:** new gem `gems/activerecord-beagle-turso/` skeleton + `lib/active_record/connection_adapters/beagle_turso_adapter.rb`; `spec/adapter_crud_spec.rb`.

**Interfaces:**
- Produces: `ActiveRecord::ConnectionAdapters::BeagleTursoAdapter` registered as `adapter: beagle_turso`; a working connect + exec path.

- [ ] **Step 1: Failing spec** (`spec/adapter_crud_spec.rb`) — establish a connection, migrate, CRUD:

```ruby
require "active_record"
require "activerecord-beagle-turso"

RSpec.describe "beagle_turso adapter CRUD" do
  before(:all) do
    ActiveRecord::Base.establish_connection(adapter: "beagle_turso", database: ":memory:")
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :widgets, force: true do |t|
        t.string :name
        t.integer :qty
      end
    end
  end

  it "inserts and reads back through the model" do
    klass = Class.new(ActiveRecord::Base) { self.table_name = "widgets" }
    w = klass.create!(name: "gizmo", qty: 3)
    expect(w.id).to be_a(Integer)
    got = klass.find(w.id)
    expect([got.name, got.qty]).to eq(["gizmo", 3])
    expect(klass.where(qty: 3).count).to eq(1)
  end
end
```

- [ ] **Step 2: Run — fails** (adapter not registered).

- [ ] **Step 3: Implement the adapter.** Skeleton (confirm each inherited signature against the AR 8.1 source named in Global Constraints):

```ruby
require "active_record/connection_adapters/sqlite3_adapter"
require "beagle/turso"

module ActiveRecord
  module ConnectionAdapters
    class BeagleTursoAdapter < SQLite3Adapter
      ADAPTER_NAME = "BeagleTurso"

      class << self
        # Open a beagle-turso Connection instead of a ::SQLite3::Database.
        def new_client(config)
          db = if config[:remote_url]
            Beagle::Turso::Database.open(
              local_path: config[:database].to_s,
              remote_url: config[:remote_url],
              auth_token: config[:auth_token],
              bootstrap_if_empty: config.fetch(:bootstrap_if_empty, true),
            )
          else
            Beagle::Turso::Database.open_local(config[:database].to_s)
          end
          Client.new(db)
        end
      end

      # Wrap Database+Connection so the adapter's pragma/lifecycle calls have a home.
      class Client
        attr_reader :database, :connection
        def initialize(database)
          @database = database
          @connection = database.connect
        end
        def query_result(sql, params) = connection.query_result(sql, params)
        def execute(sql, params) = connection.execute(sql, params)
        def execute_batch(sql) = connection.execute_batch(sql)
        def last_insert_rowid = connection.last_insert_rowid
        def push = database.push
        def pull = database.pull
        # No-op the sqlite3-specific lifecycle bits the adapter calls:
        def busy_handler_timeout=(_); end
        def closed?; false; end
        def rollback; execute("ROLLBACK", []); end
        # Pragmas: accept `foo=` setter calls the adapter makes during connect.
        def method_missing(name, *args)
          name.to_s.end_with?("=") ? nil : super
        end
        def respond_to_missing?(name, _ = false) = name.to_s.end_with?("=") || super
      end

      private
        # Reroute the SQLite3 exec path to the beagle-turso Connection.
        def perform_query(raw_connection, sql, binds, type_casted_binds, prepare:, notification_payload:, batch: false)
          params = type_casted_binds
          if batch
            raw_connection.execute_batch(sql)
            return ::ActiveRecord::Result.empty
          end
          if returning_query?(sql) # SELECT / RETURNING
            cols, rows = raw_connection.query_result(sql, params)
            ::ActiveRecord::Result.new(cols, rows)
          else
            @last_affected = raw_connection.execute(sql, params)
            @last_rowid = raw_connection.last_insert_rowid
            ::ActiveRecord::Result.empty
          end
        end

        def cast_result(result) = result # already an ActiveRecord::Result
        def affected_rows(_result) = @last_affected.to_i
        def last_inserted_id(_result) = @last_rowid

        def returning_query?(sql)
          sql =~ /\A\s*(SELECT|PRAGMA|WITH)\b/i || sql =~ /RETURNING/i
        end

        def connect
          @raw_connection = self.class.new_client(@connection_parameters)
        end
    end

    # register
  end
end
ActiveRecord::ConnectionAdapters.register("beagle_turso", "ActiveRecord::ConnectionAdapters::BeagleTursoAdapter", "active_record/connection_adapters/beagle_turso_adapter")
```

Implementer notes (confirm against the AR source): the exact `perform_query` signature and what `cast_result`/`affected_rows`/`last_inserted_id` receive; whether `ActiveRecord::Result.new(columns, rows)` is the right constructor in 8.1; how `binds`/`type_casted_binds` map to positional `?` params (order + values — `type_casted_binds` is already a flat array of cast values in bind order). If `perform_query` isn't the cleanest seam, override `internal_exec_query`/`raw_execute` instead — the goal is: SELECT → Result with columns+rows; write → affected + last rowid. Add a gemspec + `lib/activerecord-beagle-turso.rb` that requires the adapter and registers it.

- [ ] **Step 4: Run the CRUD spec** — migrate + create + find + where all pass. Iterate the exec-path overrides against real AR behavior until green. **Step 5: Commit** `feat(adapter): BeagleTursoAdapter subclass — connect + exec path, migrate+CRUD green`.

---

## Task 5: Adapter — schema/transactions/type completeness

**Files:** `beagle_turso_adapter.rb`; `spec/adapter_schema_spec.rb`.

- [ ] **Step 1: Failing specs** covering: transactions (`transaction { } ` commit + rollback), `add_column`/`add_index`/`remove_column` (DDL via `execute_batch`), a variety of column types (string/integer/float/boolean/datetime/binary), and `pluck`/`update`/`delete`. (Concrete assertions per case — write real `expect`s, not "test the above".)

- [ ] **Step 2: Run — fails where the inherited SQLite3 path hits a call our `Client` doesn't satisfy.** **Step 3: Implement** — add the missing `Client` methods the inherited schema/transaction code calls (confirm which via the failures: likely `transaction`/`begin`, `changes`, `total_changes`; map to `execute("BEGIN"/"COMMIT"/"ROLLBACK")` and to core counters if needed). Inherit SQLite type map and quoting unchanged. **Step 4: Green. Step 5: Commit** `feat(adapter): transactions, DDL, and type coverage`.

---

## Task 6: SyncManager + Solid Queue recurring job + config

**Files:** `lib/active_record/connection_adapters/beagle_turso/sync_manager.rb`; a generator or Railtie wiring `config/recurring.yml`; `spec/sync_manager_spec.rb` (env-gated).

**Interfaces:** `Beagle::Turso::SyncManager.push!/pull!/sync!` operating on the current adapter's `Client` (`push`/`pull`); a Solid Queue recurring job class calling `sync!` at `sync_interval`.

- [ ] **Step 1: Failing env-gated spec** — with `TURSO_*` creds, establish a synced connection, write, `SyncManager.push!`, open a second synced connection at a fresh path, `SyncManager.pull!`, assert the row is visible; SKIP without creds.
- [ ] **Step 2/3: Implement** SyncManager (reaches the adapter's `raw_connection.push/pull`) + a `BeagleTurso::SyncJob` (Solid Queue) + a documented `config/recurring.yml` entry + `database.yml` keys (`remote_url`, `auth_token`, `sync_interval`). Creds via credentials/ENV, never logged.
- [ ] **Step 4: Run** (PASS with creds, SKIP without). **Step 5: Commit** `feat(adapter): SyncManager + Solid Queue recurring sync`.

---

## Task 7: Dummy Rails app integration, AR shared suite, README, CI

**Files:** `test/dummy/` (minimal Rails app on `adapter: beagle_turso`); hook a subset of ActiveRecord's shared adapter test suite; `README.md`; gemspec metadata; `.github/workflows/adapter.yml`.

- [ ] **Step 1** Minimal dummy app + a smoke test (migrate, model CRUD, a request-less integration) proving the adapter works inside a real Rails boot.
- [ ] **Step 2** Wire a focused subset of `ActiveRecord::TestCase` shared adapter tests (or document why full suite is deferred — no silent skip).
- [ ] **Step 3** README (config example with `adapter: beagle_turso` + sync, on-sync durability note, MIT), gemspec metadata, CI (`oxidize-rb` setup + rake compile of the gem dep + rspec + the dummy-app test).
- [ ] **Step 4** Full gate green. **Step 5: Commit** `docs(adapter): dummy app, AR suite subset, README, CI`.

---

## Self-Review

**Spec coverage:** column names (T1/T3), rowid+batch (T2/T3), the subclass + exec path with migrate+CRUD (T4), schema/tx/types (T5), sync via Solid Queue (T6), real-Rails integration + AR suite + docs/CI (T7). Credential invariant preserved (creds from database.yml, never logged).

**Risk front-loading:** T4 is the crux (does `SQLite3Adapter` subclassing with a swapped `raw_connection` actually work). It is a reviewed task with a concrete migrate+CRUD gate; if the `perform_query` seam proves wrong, the review checkpoint catches it and the override moves to `internal_exec_query`/`raw_execute` (same goal). The lower-layer primitives (T1–T3) are independently testable and de-risk T4's inputs.

**Placeholder scan:** AR-internal signatures carry explicit "confirm against activerecord-8.1.3.1 source" notes (the analog of Plans 1/2's turso/magnus confirmations); everything else is concrete.

## Follow-on / open items (from the Plan 2 final review)
- GVL is held during `execute`/`query`/`push`/`pull` — under threaded Puma the adapter serializes DB/network I/O. If it bites, add `rb_thread_call_without_gvl` in the gem (a gem-level change, its own future task).
- Non-UTF-8/non-binary String params raise in the gem decoder — AR type-casting normalizes most inputs; revisit if a real case appears.
