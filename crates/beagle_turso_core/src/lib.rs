mod error;
mod runtime;
mod value;

use runtime::{new_runtime, SharedRt};

pub use error::{Error, Result};
pub use value::Value;

/// Options controlling how a [`Database`] is opened.
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

/// A single row from a [`Connection::query`] result.
pub struct Row {
    pub values: Vec<Value>,
}

/// A handle to an open database. Local-only for Task 2; synced/remote support
/// is added in Task 4.
pub struct Database {
    rt: SharedRt,
    inner: turso::Database,
}

/// A connection to a [`Database`], used to run SQL.
pub struct Connection {
    rt: SharedRt,
    conn: turso::Connection,
}

impl Database {
    pub fn open(opts: OpenOptions) -> Result<Database> {
        let rt = new_runtime()?;
        // Task 2 handles local only; Task 4 branches on opts.remote_url.
        let inner = rt.block_on(async {
            turso::Builder::new_local(&opts.local_path)
                .build()
                .await
                .map_err(|e| Error::Open(e.to_string()))
        })?;
        Ok(Database { rt, inner })
    }

    pub fn connect(&self) -> Result<Connection> {
        let conn = self
            .inner
            .connect()
            .map_err(|e| Error::Connect(e.to_string()))?;
        Ok(Connection {
            rt: self.rt.clone(),
            conn,
        })
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
