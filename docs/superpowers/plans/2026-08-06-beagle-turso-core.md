# beagle_turso_core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `beagle_turso_core`, a Rust library crate that wraps the `turso` engine behind a small **synchronous** API (open, connect, execute, query, transactions, push, pull) so higher layers (a Ruby Magnus gem, later an Elixir NIF) can call it without touching async.

**Architecture:** A thin façade over the `turso` crate (v0.7.x, `sync` feature). The crate owns a tokio runtime and `block_on`s the engine's async calls, exposing blocking methods. It supports two open modes: **local-only** (in-memory or file, no network — used by fast unit tests) and **synced** (local replica + remote Turso Cloud, used by hero use case A). Parameters and rows cross the boundary as a plain `Value` enum, never engine-native types.

**Tech Stack:** Rust 2021, `turso` 0.7.2 (`sync` feature), `tokio` (multi-thread, 1 worker), `anyhow` (tests only), `thiserror`.

## Global Constraints

- Pin `turso = "=0.7.2"` (beta engine — exact pin, no caret). Copy verbatim into `Cargo.toml`.
- The public API is **synchronous**. No `async fn` is exposed from this crate. All async is bridged internally via `Runtime::block_on`.
- Values crossing the public API use `beagle_turso_core::Value` only — never `turso::Value` or other engine types in signatures.
- **No credential logging.** Never `println!`/`dbg!`/`log` the `auth_token`, the `remote_url`, or any `Value`. This is the reason the project exists; a test enforces it.
- Errors are the crate's own `Error` enum (`thiserror`); engine errors are converted, never leaked as `turso::Error` in signatures.
- Every task ends green (`cargo test`) and with a commit.
- **External-API note:** `turso` is a beta crate. Where a step says "confirm signature", open `https://docs.rs/turso/0.7.2` or run `cargo doc -p turso --open` and match the real names before implementing. Adjust the shown code to the actual API if it differs; keep the crate's *own* public signatures exactly as specified here.

---

## File Structure

- `Cargo.toml` — crate manifest (lib), deps.
- `src/lib.rs` — public re-exports; `OpenOptions`, `Database`, `Connection`, `Row`; module wiring.
- `src/value.rs` — `Value` enum + conversions to/from `turso` param/column values.
- `src/error.rs` — `Error` enum (`thiserror`) + `Result` alias.
- `src/runtime.rs` — shared tokio runtime helper (`SharedRt = Arc<Runtime>`, `new_runtime()`).
- `tests/local.rs` — integration tests for the local (no-network) path.
- `tests/sync.rs` — integration test for the synced round-trip, **gated** on `TURSO_DATABASE_URL`/`TURSO_AUTH_TOKEN` env (skips when unset).
- `tests/no_secret_logging.rs` — asserts creds never appear in `Debug`/`Display` output.

`OpenOptions` fields: `local_path: String`, `remote_url: Option<String>`, `auth_token: Option<String>`, `bootstrap_if_empty: bool`.

---

## Task 1: Crate skeleton, `Value`, `Error`

**Files:**
- Create: `Cargo.toml`, `src/lib.rs`, `src/value.rs`, `src/error.rs`
- Test: `src/value.rs` (unit `#[cfg(test)]`), `src/error.rs` (unit)

**Interfaces:**
- Produces: `Value` (`Null | Integer(i64) | Real(f64) | Text(String) | Blob(Vec<u8>)`, derives `Debug, Clone, PartialEq`); `Error` (`thiserror`, variants `Open(String)`, `Connect(String)`, `Query(String)`, `Sync(String)`, `Type(String)`); `type Result<T> = std::result::Result<T, Error>`.

- [ ] **Step 1: Write the failing test** (`src/value.rs`)

```rust
#[cfg(test)]
mod tests {
    use super::Value;

    #[test]
    fn value_equality_and_clone() {
        let v = Value::Text("hi".into());
        assert_eq!(v.clone(), Value::Text("hi".into()));
        assert_ne!(Value::Integer(1), Value::Integer(2));
        assert_eq!(Value::Null, Value::Null);
    }
}
```

- [ ] **Step 2: Create the manifest and modules so it compiles**

`Cargo.toml`:
```toml
[package]
name = "beagle_turso_core"
version = "0.1.0"
edition = "2021"
license = "MIT"

[dependencies]
turso = { version = "=0.7.2", features = ["sync"] }
tokio = { version = "1", features = ["rt", "rt-multi-thread"] }
thiserror = "2"

[dev-dependencies]
anyhow = "1"
```

`src/value.rs`:
```rust
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Integer(i64),
    Real(f64),
    Text(String),
    Blob(Vec<u8>),
}
```

`src/error.rs`:
```rust
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("open failed: {0}")]
    Open(String),
    #[error("connect failed: {0}")]
    Connect(String),
    #[error("query failed: {0}")]
    Query(String),
    #[error("sync failed: {0}")]
    Sync(String),
    #[error("type error: {0}")]
    Type(String),
}

pub type Result<T> = std::result::Result<T, Error>;
```

`src/lib.rs`:
```rust
mod error;
mod value;

pub use error::{Error, Result};
pub use value::Value;
```

- [ ] **Step 3: Run test to verify it passes**

Run: `cargo test value_equality_and_clone`
Expected: PASS (1 test).

- [ ] **Step 4: Add an error-display test** (`src/error.rs`)

```rust
#[cfg(test)]
mod tests {
    use super::Error;

    #[test]
    fn error_displays_context() {
        let e = Error::Query("boom".into());
        assert_eq!(e.to_string(), "query failed: boom");
    }
}
```

- [ ] **Step 5: Run tests**

Run: `cargo test`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Cargo.toml src/lib.rs src/value.rs src/error.rs
git commit -m "feat(core): crate skeleton with Value and Error types"
```

---

## Task 2: Shared runtime + local open/connect/execute/query

**Files:**
- Create: `src/runtime.rs`, `tests/local.rs`
- Modify: `src/lib.rs` (add `Database`, `Connection`, `Row`, `OpenOptions`; wire runtime)
- Modify: `src/value.rs` (add `to_turso`/`from_turso` conversions)

**Interfaces:**
- Consumes: `Value`, `Error`, `Result` (Task 1).
- Produces:
  - `OpenOptions { local_path: String, remote_url: Option<String>, auth_token: Option<String>, bootstrap_if_empty: bool }` (impl `Default`, `local_path=":memory:"`).
  - `Database` with `pub fn open(opts: OpenOptions) -> Result<Database>` and `pub fn connect(&self) -> Result<Connection>`.
  - `Connection` with `pub fn execute(&self, sql: &str, params: &[Value]) -> Result<u64>` (affected rows) and `pub fn query(&self, sql: &str, params: &[Value]) -> Result<Vec<Row>>`.
  - `Row { pub values: Vec<Value> }`.

- [ ] **Step 1: Write the failing test** (`tests/local.rs`)

```rust
use beagle_turso_core::{Database, OpenOptions, Value};

#[test]
fn local_insert_and_query_roundtrip() {
    let db = Database::open(OpenOptions::default()).expect("open in-memory");
    let conn = db.connect().expect("connect");

    conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", &[])
        .expect("create");
    let affected = conn
        .execute("INSERT INTO t (name) VALUES (?)", &[Value::Text("alice".into())])
        .expect("insert");
    assert_eq!(affected, 1);

    let rows = conn.query("SELECT name FROM t", &[]).expect("select");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].values[0], Value::Text("alice".into()));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --test local local_insert_and_query_roundtrip`
Expected: FAIL — `Database`/`OpenOptions` not found.

- [ ] **Step 3: Implement the runtime helper** (`src/runtime.rs`)

```rust
use std::sync::Arc;
use tokio::runtime::{Builder, Runtime};

pub type SharedRt = Arc<Runtime>;

pub fn new_runtime() -> crate::Result<SharedRt> {
    let rt = Builder::new_multi_thread()
        .worker_threads(1)
        .enable_all()
        .build()
        .map_err(|e| crate::Error::Open(e.to_string()))?;
    Ok(Arc::new(rt))
}
```

- [ ] **Step 4: Implement value conversions** (`src/value.rs`)

Confirm signature against docs.rs: how `turso` represents a bound parameter and a column value (likely `turso::Value`). Implement both directions. Reference shape:

```rust
use crate::{Error, Value};

impl Value {
    /// Our Value -> the engine's parameter value.
    pub(crate) fn to_turso(&self) -> turso::Value {
        match self {
            Value::Null => turso::Value::Null,
            Value::Integer(i) => turso::Value::Integer(*i),
            Value::Real(f) => turso::Value::Real(*f),
            Value::Text(s) => turso::Value::Text(s.clone()),
            Value::Blob(b) => turso::Value::Blob(b.clone()),
        }
    }

    /// The engine's column value -> our Value.
    pub(crate) fn from_turso(v: turso::Value) -> Result<Value, Error> {
        Ok(match v {
            turso::Value::Null => Value::Null,
            turso::Value::Integer(i) => Value::Integer(i),
            turso::Value::Real(f) => Value::Real(f),
            turso::Value::Text(s) => Value::Text(s),
            turso::Value::Blob(b) => Value::Blob(b),
        })
    }
}
```

If the `turso::Value` variant names differ, adjust the match arms only.

- [ ] **Step 5: Implement `OpenOptions`, `Database`, `Connection`, `Row`** (`src/lib.rs`)

```rust
mod error;
mod runtime;
mod value;

use runtime::{new_runtime, SharedRt};

pub use error::{Error, Result};
pub use value::Value;

#[derive(Debug, Clone)]
pub struct OpenOptions {
    pub local_path: String,
    pub remote_url: Option<String>,
    pub auth_token: Option<String>,
    pub bootstrap_if_empty: bool,
}

impl Default for OpenOptions {
    fn default() -> Self {
        Self {
            local_path: ":memory:".to_string(),
            remote_url: None,
            auth_token: None,
            bootstrap_if_empty: true,
        }
    }
}

pub struct Row {
    pub values: Vec<Value>,
}

pub struct Database {
    rt: SharedRt,
    inner: turso::Database, // local-only for Task 2; synced added in Task 4
}

pub struct Connection {
    rt: SharedRt,
    conn: turso::Connection,
}

impl Database {
    pub fn open(opts: OpenOptions) -> Result<Database> {
        let rt = new_runtime()?;
        // Task 2 handles local only; Task 4 branches on opts.remote_url.
        let inner = rt.block_on(async {
            // confirm signature: turso::Builder::new_local(path).build().await
            turso::Builder::new_local(&opts.local_path)
                .build()
                .await
                .map_err(|e| Error::Open(e.to_string()))
        })?;
        Ok(Database { rt, inner })
    }

    pub fn connect(&self) -> Result<Connection> {
        // confirm signature: local Database::connect() — sync or async?
        let conn = self
            .inner
            .connect()
            .map_err(|e| Error::Connect(e.to_string()))?;
        Ok(Connection { rt: self.rt.clone(), conn })
    }
}

impl Connection {
    pub fn execute(&self, sql: &str, params: &[Value]) -> Result<u64> {
        let tparams: Vec<turso::Value> = params.iter().map(Value::to_turso).collect();
        self.rt.block_on(async {
            self.conn
                .execute(sql, tparams)
                .await
                .map_err(|e| Error::Query(e.to_string()))
        })
    }

    pub fn query(&self, sql: &str, params: &[Value]) -> Result<Vec<Row>> {
        let tparams: Vec<turso::Value> = params.iter().map(Value::to_turso).collect();
        self.rt.block_on(async {
            let mut rows = self
                .conn
                .query(sql, tparams)
                .await
                .map_err(|e| Error::Query(e.to_string()))?;
            let mut out = Vec::new();
            while let Some(row) = rows.next().await.map_err(|e| Error::Query(e.to_string()))? {
                // confirm signature: number of columns + how to read a column Value
                let n = row.column_count();
                let mut vals = Vec::with_capacity(n);
                for i in 0..n {
                    let cv = row.get_value(i).map_err(|e| Error::Query(e.to_string()))?;
                    vals.push(Value::from_turso(cv)?);
                }
                out.push(Row { values: vals });
            }
            Ok(out)
        })
    }
}
```

Notes for the implementer: `execute` returns affected-row count — confirm whether `turso`'s `execute` returns that directly (`u64`) or requires `changes()`; adjust to satisfy `Result<u64>`. `row.column_count()` / `row.get_value(i)` names must be confirmed against docs.rs; the *shape* (loop columns → `Value`) stays.

- [ ] **Step 6: Run the test to verify it passes**

Run: `cargo test --test local local_insert_and_query_roundtrip`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Cargo.toml src/lib.rs src/runtime.rs src/value.rs tests/local.rs
git commit -m "feat(core): local open/connect/execute/query over the turso engine"
```

---

## Task 3: Parameter binding across types + NULL

**Files:**
- Modify: `tests/local.rs` (add cases)

**Interfaces:**
- Consumes: everything from Task 2. No new public API.

- [ ] **Step 1: Write the failing test** (`tests/local.rs`)

```rust
#[test]
fn params_bind_all_value_kinds() {
    let db = Database::open(OpenOptions::default()).unwrap();
    let conn = db.connect().unwrap();
    conn.execute(
        "CREATE TABLE k (i INTEGER, r REAL, t TEXT, b BLOB, n TEXT)",
        &[],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO k (i, r, t, b, n) VALUES (?, ?, ?, ?, ?)",
        &[
            Value::Integer(42),
            Value::Real(3.5),
            Value::Text("hi".into()),
            Value::Blob(vec![1, 2, 3]),
            Value::Null,
        ],
    )
    .unwrap();

    let rows = conn.query("SELECT i, r, t, b, n FROM k", &[]).unwrap();
    assert_eq!(rows[0].values[0], Value::Integer(42));
    assert_eq!(rows[0].values[1], Value::Real(3.5));
    assert_eq!(rows[0].values[2], Value::Text("hi".into()));
    assert_eq!(rows[0].values[3], Value::Blob(vec![1, 2, 3]));
    assert_eq!(rows[0].values[4], Value::Null);
}
```

- [ ] **Step 2: Run it**

Run: `cargo test --test local params_bind_all_value_kinds`
Expected: PASS if Task 2's conversions are correct; if a variant fails, fix `to_turso`/`from_turso` in `src/value.rs` until green.

- [ ] **Step 3: Commit**

```bash
git add tests/local.rs src/value.rs
git commit -m "test(core): parameter binding covers all Value kinds incl NULL/blob"
```

---

## Task 4: Synced open + push/pull (env-gated integration test)

**Files:**
- Modify: `src/lib.rs` (branch `open` on `remote_url`; add `push`/`pull`; wrap inner in an enum)
- Create: `tests/sync.rs`

**Interfaces:**
- Consumes: Task 2 API.
- Produces: `Database::push(&self) -> Result<()>`, `Database::pull(&self) -> Result<bool>`. `open` now: if `remote_url` is `Some`, build a synced DB; else local.

- [ ] **Step 1: Write the failing test** (`tests/sync.rs`)

```rust
use beagle_turso_core::{Database, OpenOptions, Value};

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|s| !s.is_empty())
}

#[test]
fn synced_write_pushes_and_fresh_replica_sees_it() {
    let (Some(url), Some(token)) = (env("TURSO_DATABASE_URL"), env("TURSO_AUTH_TOKEN")) else {
        eprintln!("SKIP: TURSO_DATABASE_URL/TURSO_AUTH_TOKEN not set");
        return;
    };

    // unique marker so we prove THIS run round-trips
    let marker = format!("btc-{}", std::process::id());
    let dir = std::env::temp_dir();
    let path_a = dir.join(format!("btc_a_{marker}.db")).display().to_string();
    let path_b = dir.join(format!("btc_b_{marker}.db")).display().to_string();

    let opts_a = OpenOptions {
        local_path: path_a,
        remote_url: Some(url.clone()),
        auth_token: Some(token.clone()),
        bootstrap_if_empty: true,
    };
    let db_a = Database::open(opts_a).unwrap();
    let conn_a = db_a.connect().unwrap();
    conn_a
        .execute("CREATE TABLE IF NOT EXISTS m (name TEXT)", &[])
        .unwrap();
    conn_a
        .execute("INSERT INTO m (name) VALUES (?)", &[Value::Text(marker.clone())])
        .unwrap();
    db_a.push().unwrap();

    let opts_b = OpenOptions {
        local_path: path_b,
        remote_url: Some(url),
        auth_token: Some(token),
        bootstrap_if_empty: true,
    };
    let db_b = Database::open(opts_b).unwrap();
    db_b.pull().unwrap();
    let conn_b = db_b.connect().unwrap();
    let rows = conn_b
        .query("SELECT count(*) FROM m WHERE name = ?", &[Value::Text(marker)])
        .unwrap();
    assert_eq!(rows[0].values[0], Value::Integer(1));
}
```

- [ ] **Step 2: Run it (expect SKIP without creds, FAIL to compile until impl)**

Run: `cargo test --test sync`
Expected: compile error — `push`/`pull` not found.

- [ ] **Step 3: Refactor `Database` inner to an enum and implement synced open + push/pull** (`src/lib.rs`)

Replace the `Database` struct and its `impl` from Task 2 with:

```rust
enum Inner {
    Local(turso::Database),
    Synced(turso::sync::Database),
}

pub struct Database {
    rt: SharedRt,
    inner: Inner,
}

impl Database {
    pub fn open(opts: OpenOptions) -> Result<Database> {
        let rt = new_runtime()?;
        let inner = rt.block_on(async {
            match (&opts.remote_url, &opts.auth_token) {
                (Some(url), Some(token)) => {
                    // confirm signature: turso::sync::Builder (as used in the spike)
                    let db = turso::sync::Builder::new_remote(&opts.local_path)
                        .with_remote_url(url)
                        .with_auth_token(token)
                        .bootstrap_if_empty(opts.bootstrap_if_empty)
                        .build()
                        .await
                        .map_err(|e| Error::Open(e.to_string()))?;
                    Ok::<Inner, Error>(Inner::Synced(db))
                }
                _ => {
                    let db = turso::Builder::new_local(&opts.local_path)
                        .build()
                        .await
                        .map_err(|e| Error::Open(e.to_string()))?;
                    Ok(Inner::Local(db))
                }
            }
        })?;
        Ok(Database { rt, inner })
    }

    pub fn connect(&self) -> Result<Connection> {
        let conn = match &self.inner {
            Inner::Local(db) => db.connect().map_err(|e| Error::Connect(e.to_string()))?,
            // confirm: sync::Database::connect() is async (it was `.await` in the spike)
            Inner::Synced(db) => self
                .rt
                .block_on(async { db.connect().await })
                .map_err(|e| Error::Connect(e.to_string()))?,
        };
        Ok(Connection { rt: self.rt.clone(), conn })
    }

    pub fn push(&self) -> Result<()> {
        match &self.inner {
            Inner::Local(_) => Err(Error::Sync("push() on a local-only database".into())),
            Inner::Synced(db) => self
                .rt
                .block_on(async { db.push().await })
                .map(|_| ())
                .map_err(|e| Error::Sync(e.to_string())),
        }
    }

    pub fn pull(&self) -> Result<bool> {
        match &self.inner {
            Inner::Local(_) => Err(Error::Sync("pull() on a local-only database".into())),
            Inner::Synced(db) => self
                .rt
                .block_on(async { db.pull().await })
                .map_err(|e| Error::Sync(e.to_string())),
        }
    }
}
```

Implementer note: confirm that `Inner::Local(db).connect()` and `Inner::Synced(db).connect().await` both yield the same `turso::Connection` type held by `Connection`. If they differ, make `Connection.conn` an enum mirroring `Inner` and match in `execute`/`query`.

- [ ] **Step 4: Provision a scratch DB and run the gated test**

```bash
# one-time: a throwaway cloud DB for the test (turso CLI must be authed)
turso db create beagle-turso-ci 2>/dev/null || true
export TURSO_DATABASE_URL=$(turso db show beagle-turso-ci --url)
export TURSO_AUTH_TOKEN=$(turso db tokens create beagle-turso-ci)
cargo test --test sync -- --nocapture
```
Expected: PASS — `count(*) == 1` for this run's marker.

- [ ] **Step 5: Run the whole suite (local tests still green)**

Run: `cargo test`
Expected: PASS (local tests pass; sync test passes with creds, SKIPs without).

- [ ] **Step 6: Commit**

```bash
git add src/lib.rs tests/sync.rs
git commit -m "feat(core): synced open + push/pull with env-gated round-trip test"
```

---

## Task 5: Credential-safety invariant

**Files:**
- Create: `tests/no_secret_logging.rs`
- Modify: `src/lib.rs` (ensure `Database`/`Connection`/`OpenOptions` do not derive/emit secrets)

**Interfaces:**
- Consumes: public API. Produces: a manual `Debug` for `OpenOptions` that redacts `auth_token`.

- [ ] **Step 1: Write the failing test** (`tests/no_secret_logging.rs`)

```rust
use beagle_turso_core::OpenOptions;

#[test]
fn options_debug_redacts_auth_token() {
    let opts = OpenOptions {
        local_path: "x.db".into(),
        remote_url: Some("libsql://example".into()),
        auth_token: Some("SECRET-eyJshh".into()),
        bootstrap_if_empty: true,
    };
    let printed = format!("{opts:?}");
    assert!(!printed.contains("SECRET-eyJshh"), "auth_token leaked in Debug: {printed}");
    assert!(printed.contains("[redacted]"));
}
```

- [ ] **Step 2: Run it**

Run: `cargo test --test no_secret_logging`
Expected: FAIL — derived `Debug` prints the token.

- [ ] **Step 3: Replace the derived `Debug` on `OpenOptions` with a redacting one** (`src/lib.rs`)

Remove `Debug` from the `derive` on `OpenOptions` and add:

```rust
impl std::fmt::Debug for OpenOptions {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OpenOptions")
            .field("local_path", &self.local_path)
            .field("remote_url", &self.remote_url)
            .field("auth_token", &self.auth_token.as_ref().map(|_| "[redacted]"))
            .field("bootstrap_if_empty", &self.bootstrap_if_empty)
            .finish()
    }
}
```

- [ ] **Step 4: Run it**

Run: `cargo test --test no_secret_logging`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib.rs tests/no_secret_logging.rs
git commit -m "feat(core): redact auth_token in Debug output (no-secret-logging invariant)"
```

---

## Task 6: Public API polish, docs, CI

**Files:**
- Modify: `src/lib.rs` (crate-level `//!` docs + doctest), `Cargo.toml` (metadata)
- Create: `README.md`, `.github/workflows/ci.yml`

**Interfaces:**
- No new API. Locks the public surface: `Value`, `Error`, `Result`, `OpenOptions`, `Database`, `Connection`, `Row`.

- [ ] **Step 1: Add a crate doctest that exercises the local path** (`src/lib.rs`, top)

```rust
//! `beagle_turso_core` — a synchronous Rust façade over the Turso engine.
//!
//! ```
//! use beagle_turso_core::{Database, OpenOptions, Value};
//! let db = Database::open(OpenOptions::default()).unwrap();
//! let conn = db.connect().unwrap();
//! conn.execute("CREATE TABLE t (n TEXT)", &[]).unwrap();
//! conn.execute("INSERT INTO t (n) VALUES (?)", &[Value::Text("x".into())]).unwrap();
//! let rows = conn.query("SELECT n FROM t", &[]).unwrap();
//! assert_eq!(rows[0].values[0], Value::Text("x".into()));
//! ```
```

- [ ] **Step 2: Run doctests**

Run: `cargo test --doc`
Expected: PASS.

- [ ] **Step 3: Add CI** (`.github/workflows/ci.yml`)

```yaml
name: ci
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo build --verbose
      - run: cargo test --verbose        # sync test SKIPs (no creds in CI)
      - run: cargo fmt --check
      - run: cargo clippy -- -D warnings
```

- [ ] **Step 4: Write `README.md`** (short: what it is, the local example above, the sync note, MIT).

- [ ] **Step 5: Run full gate**

Run: `cargo fmt --check && cargo clippy -- -D warnings && cargo test`
Expected: PASS / clean.

- [ ] **Step 6: Commit**

```bash
git add src/lib.rs Cargo.toml README.md .github/workflows/ci.yml
git commit -m "docs(core): crate docs, README, and CI"
```

---

## Self-Review

**Spec coverage (Plan 1 = the `beagle_turso_core` layer only):**
- Synchronous façade over `turso` ✓ (Tasks 2, 4). Local + synced open ✓ (Tasks 2, 4). push/pull ✓ (Task 4). Value boundary type ✓ (Tasks 1–3). No-credential-logging invariant ✓ (Task 5). Pinned beta crate ✓ (Global Constraints). Round-trip test mirroring Spike 1 ✓ (Task 4).
- Deferred to later plans (correctly out of scope here): the Ruby Magnus gem (`beagle-turso`, Plan 2), the ActiveRecord adapter + SyncManager + Solid Queue job (`activerecord-beagle-turso`, Plan 3), cross-compiled precompiled gems (Plan 2 CI).

**Placeholder scan:** No "TBD"/"handle errors"/"similar to". The only soft spots are explicit "confirm signature against docs.rs" notes on the beta `turso` API — intentional and specific, not lazy.

**Type consistency:** `Value`, `Error`, `Result`, `OpenOptions`, `Database`, `Connection`, `Row` names are identical across all tasks. `execute -> Result<u64>`, `query -> Result<Vec<Row>>`, `push -> Result<()>`, `pull -> Result<bool>` are consistent from definition (Task 2/4) through use.

## Follow-on plans (not written yet — by design)

- **Plan 2 — `beagle-turso` (Ruby driver, Magnus/rb-sys):** wrap this crate's public API; ship precompiled gems via rb-sys-dock. Written against the *real* core API once Plan 1 lands.
- **Plan 3 — `activerecord-beagle-turso`:** `BeagleTursoAdapter < SQLite3Adapter`, `SyncManager`, Solid Queue recurring job, dummy-app integration + AR shared adapter suite.
