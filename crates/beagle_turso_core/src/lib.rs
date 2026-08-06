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
        let tparams: Vec<turso::Value> = params.iter().map(Value::to_turso).collect();
        self.rt.block_on(async {
            let mut rows = self
                .conn
                .query(sql, tparams)
                .await
                .map_err(|e| Error::Query(e.to_string()))?;
            let mut out = Vec::new();
            while let Some(row) = rows.next().await.map_err(|e| Error::Query(e.to_string()))? {
                let n = row.column_count();
                let mut vals = Vec::with_capacity(n);
                for i in 0..n {
                    let cv = row
                        .get_value(i)
                        .map_err(|e| Error::Query(e.to_string()))?;
                    vals.push(Value::from_turso(cv));
                }
                out.push(Row { values: vals });
            }
            Ok(out)
        })
    }
}
