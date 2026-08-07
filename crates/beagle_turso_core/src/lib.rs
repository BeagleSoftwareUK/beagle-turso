//! `beagle_turso_core` — a synchronous Rust façade over the Turso engine.
//!
//! It wraps the async `turso` crate behind a blocking API (via an internal
//! single-threaded Tokio runtime), so callers get a plain synchronous
//! `Database` / `Connection` pair without needing an async runtime of their
//! own — handy for FFI boundaries such as a Ruby extension.
//!
//! A [`Database`] can be opened purely local (in-memory or on-disk file, no
//! network) or synced with a remote Turso database (see
//! [`OpenOptions::remote_url`] / [`OpenOptions::auth_token`] and
//! [`Database::push`] / [`Database::pull`]). Local writes to a synced
//! database are durable to the local file as they happen; [`Database::push`]
//! is what propagates them to the remote.
//!
//! The example below only exercises the local, offline path — it opens an
//! in-memory database, so it needs no network access or credentials.
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

mod error;
mod runtime;
mod value;

use runtime::{new_runtime, SharedRt};

pub use error::{Error, Result};
pub use value::Value;

/// Options controlling how a [`Database`] is opened.
#[derive(Clone)]
pub struct OpenOptions {
    pub local_path: String,
    pub remote_url: Option<String>,
    pub auth_token: Option<String>,
    pub bootstrap_if_empty: bool,
}

/// Redacts `remote_url` and `auth_token`, showing only whether each was set.
///
/// This is the only place secrets can leak via `{:?}`; other logging paths
/// (e.g. engine errors from `Database::open`/`push`/`pull`) may surface the
/// remote *host* embedded in a turso error string, but never the auth token
/// — the token is sent as an `Authorization` header, never embedded in the
/// URL, by this crate.
impl std::fmt::Debug for OpenOptions {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OpenOptions")
            .field("local_path", &self.local_path)
            .field("remote_url", &self.remote_url.as_ref().map(|_| "[set]"))
            .field(
                "auth_token",
                &self.auth_token.as_ref().map(|_| "[redacted]"),
            )
            .field("bootstrap_if_empty", &self.bootstrap_if_empty)
            .finish()
    }
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

/// A single row from a [`Connection::query`] result.
pub struct Row {
    pub values: Vec<Value>,
}

/// The full result of a [`Connection::query_result`] call: column names
/// alongside the rows, since [`Row`] alone carries no column metadata.
pub struct QueryResult {
    pub columns: Vec<String>,
    pub rows: Vec<Row>,
}

/// The underlying engine handle: local-only, or synced with a remote Turso
/// database via push/pull.
enum Inner {
    Local(turso::Database),
    Synced(turso::sync::Database),
}

/// A handle to an open database. Local-only when [`OpenOptions::remote_url`]
/// and [`OpenOptions::auth_token`] are `None`; synced (with [`Database::push`]
/// / [`Database::pull`]) when both are `Some`.
pub struct Database {
    rt: SharedRt,
    inner: Inner,
}

/// A connection to a [`Database`], used to run SQL.
pub struct Connection {
    rt: SharedRt,
    conn: turso::Connection,
}

impl Database {
    pub fn open(opts: OpenOptions) -> Result<Database> {
        let rt = new_runtime()?;
        let inner = rt.block_on(async {
            match (&opts.remote_url, &opts.auth_token) {
                (Some(url), Some(token)) => {
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
            // The synced database's connect() is async (unlike the local one).
            Inner::Synced(db) => self
                .rt
                .block_on(async { db.connect().await })
                .map_err(|e| Error::Connect(e.to_string()))?,
        };
        Ok(Connection {
            rt: self.rt.clone(),
            conn,
        })
    }

    /// Push local changes to the remote. Errors if this database is
    /// local-only (opened without `remote_url`/`auth_token`).
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

    /// Pull remote changes; returns `true` if any changes were applied.
    /// Errors if this database is local-only (opened without
    /// `remote_url`/`auth_token`).
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
        Ok(self.query_result(sql, params)?.rows)
    }

    /// Like [`Connection::query`], but also captures the result set's column
    /// names — needed by callers (e.g. an ActiveRecord adapter) that must
    /// know column identity, not just positional values.
    pub fn query_result(&self, sql: &str, params: &[Value]) -> Result<QueryResult> {
        let tparams: Vec<turso::Value> = params.iter().map(Value::to_turso).collect();
        self.rt.block_on(async {
            let mut rows = self
                .conn
                .query(sql, tparams)
                .await
                .map_err(|e| Error::Query(e.to_string()))?;
            // turso::Rows::column_names() reads column metadata off the
            // prepared statement, so it's available up front (no need to
            // step first) and stays fixed across the whole result set.
            let columns = rows.column_names();
            let mut out = Vec::new();
            while let Some(row) = rows.next().await.map_err(|e| Error::Query(e.to_string()))? {
                let n = row.column_count();
                let mut vals = Vec::with_capacity(n);
                for i in 0..n {
                    let cv = row.get_value(i).map_err(|e| Error::Query(e.to_string()))?;
                    vals.push(Value::from_turso(cv));
                }
                out.push(Row { values: vals });
            }
            Ok(QueryResult { columns, rows: out })
        })
    }

    /// Returns the rowid of the last row inserted by this connection.
    ///
    /// Backed by `turso::Connection::last_insert_rowid` (a plain sync call —
    /// it reads state off the connection, no I/O — so unlike the other
    /// methods here it needs no `block_on`). `Result` is kept in this
    /// method's signature for API consistency with the rest of `Connection`,
    /// even though the underlying call cannot fail.
    pub fn last_insert_rowid(&self) -> Result<i64> {
        Ok(self.conn.last_insert_rowid())
    }

    /// Runs a script of multiple `;`-separated SQL statements (e.g. schema
    /// DDL) in one call.
    ///
    /// Delegates to `turso::Connection::execute_batch`, which parses the
    /// script with the real SQL parser rather than naively splitting on
    /// `;` — so statements containing `;` inside string literals (e.g.
    /// `INSERT INTO t (n) VALUES ('a;b')`) are handled correctly.
    pub fn execute_batch(&self, sql: &str) -> Result<()> {
        self.rt.block_on(async {
            self.conn
                .execute_batch(sql)
                .await
                .map_err(|e| Error::Query(e.to_string()))
        })
    }
}
