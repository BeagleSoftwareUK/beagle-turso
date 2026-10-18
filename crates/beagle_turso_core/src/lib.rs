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

use std::mem::ManuallyDrop;
use std::sync::{Arc, Mutex};

use runtime::{new_runtime, SharedRt};

pub use error::{Error, Result};
pub use value::Value;

/// Errors with [`Error::Forked`] when called in a process other than the one
/// that opened the handle. The parent's Tokio worker thread and engine state
/// do not survive `fork`, so an inherited handle must never be used.
fn check_pid(opened: u32) -> Result<()> {
    let current = std::process::id();
    if current == opened {
        Ok(())
    } else {
        Err(Error::Forked { opened, current })
    }
}

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
    /// Declared type per column (None for expressions or untyped columns).
    pub decl_types: Vec<Option<String>>,
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
///
/// The engine handle sits in a `Mutex<Option<Arc<_>>>`. Each operation clones
/// the `Arc` and releases the mutex before doing any I/O, so a slow `push`
/// never makes `connect`, `close` or `is_closed` wait. `close` takes the
/// `Option`; an operation still in flight keeps its own `Arc` and finishes,
/// and the engine is released when the last one drops. `None` means closed.
/// `sync_lock` serializes `push`/`pull` against each other only.
/// `stmt_lock` is shared with every [`Connection`] from this database and is
/// held for exactly one statement, so statements never overlap within a
/// database (the engine reports overlapping autocommit writers as busy).
/// Opened handles are bound to the opening process; see [`Error::Forked`].
pub struct Database {
    rt: ManuallyDrop<SharedRt>,
    pid: u32,
    inner: Mutex<Option<Arc<Inner>>>,
    sync_lock: Mutex<()>,
    stmt_lock: Arc<Mutex<()>>,
}

/// A connection to a [`Database`], used to run SQL.
///
/// `conn` is a `Mutex<Option<_>>` for the same reasons as [`Database::inner`]:
/// [`Connection::close`] can release the handle eagerly, `None` means closed,
/// and the `Mutex` keeps the type `Send + Sync` for the Magnus wrap.
/// `stmt_lock` is the owning [`Database`]'s statement lock; `execute`,
/// `query_result` and `execute_batch` hold it for one statement, always taking
/// it before `conn`. `last_insert_rowid`, `close` and `is_closed` don't.
/// Opened handles are bound to the opening process; see [`Error::Forked`].
pub struct Connection {
    rt: ManuallyDrop<SharedRt>,
    pid: u32,
    stmt_lock: Arc<Mutex<()>>,
    conn: Mutex<Option<turso::Connection>>,
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
                        .map_err(|e| Error::from_engine(Error::Open, e))?;
                    Ok::<Inner, Error>(Inner::Synced(db))
                }
                _ => {
                    let db = turso::Builder::new_local(&opts.local_path)
                        .build()
                        .await
                        .map_err(|e| Error::from_engine(Error::Open, e))?;
                    Ok(Inner::Local(db))
                }
            }
        })?;
        Ok(Database {
            rt: ManuallyDrop::new(rt),
            pid: std::process::id(),
            inner: Mutex::new(Some(Arc::new(inner))),
            sync_lock: Mutex::new(()),
            stmt_lock: Arc::new(Mutex::new(())),
        })
    }

    fn handle(&self) -> Result<Arc<Inner>> {
        check_pid(self.pid)?;
        let guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        guard.as_ref().cloned().ok_or(Error::Closed)
    }

    pub fn connect(&self) -> Result<Connection> {
        let inner = self.handle()?;
        let conn = match &*inner {
            Inner::Local(db) => db
                .connect()
                .map_err(|e| Error::from_engine(Error::Connect, e))?,
            // The synced database's connect() is async (unlike the local one).
            Inner::Synced(db) => self
                .rt
                .block_on(async { db.connect().await })
                .map_err(|e| Error::from_engine(Error::Connect, e))?,
        };
        Ok(Connection {
            rt: ManuallyDrop::new((*self.rt).clone()),
            pid: self.pid,
            stmt_lock: Arc::clone(&self.stmt_lock),
            conn: Mutex::new(Some(conn)),
        })
    }

    /// Push local changes to the remote. Errors with [`Error::NotSynced`] if
    /// this database is local-only.
    pub fn push(&self) -> Result<()> {
        let inner = self.handle()?;
        match &*inner {
            Inner::Local(_) => Err(Error::NotSynced("push")),
            Inner::Synced(db) => {
                let _sync = self.sync_lock.lock().unwrap_or_else(|p| p.into_inner());
                self.rt
                    .block_on(async { db.push().await })
                    .map(|_| ())
                    .map_err(|e| Error::from_engine(Error::Sync, e))
            }
        }
    }

    /// Pull remote changes; returns `true` if any changes were applied.
    /// Errors with [`Error::NotSynced`] if this database is local-only.
    pub fn pull(&self) -> Result<bool> {
        let inner = self.handle()?;
        match &*inner {
            Inner::Local(_) => Err(Error::NotSynced("pull")),
            Inner::Synced(db) => {
                let _sync = self.sync_lock.lock().unwrap_or_else(|p| p.into_inner());
                self.rt
                    .block_on(async { db.pull().await })
                    .map_err(|e| Error::from_engine(Error::Sync, e))
            }
        }
    }

    /// Close the database, releasing the underlying engine handle and — for a
    /// synced database — its remote sync session, instead of waiting for GC.
    /// Idempotent. After close, [`Database::connect`]/[`Database::push`]/
    /// [`Database::pull`] return [`Error::Closed`]. An operation already in
    /// flight on another thread keeps its own reference and completes; the
    /// engine is released when it finishes.
    ///
    /// The `turso` crate (v0.8.3) exposes no explicit async `close`/`shutdown`
    /// on `sync::Database`/`Connection`; teardown is via `Drop`. A synced
    /// `turso::sync::Database` runs its IO on an independent worker thread that
    /// holds only a `Weak` reference to the sync engine; dropping the last
    /// strong handle (our `Inner`) closes the worker's mpsc channel and lets
    /// its `Weak::upgrade` fail, so the worker loop exits and the sync engine
    /// is released — that is what ends the server-side session. turso 0.8.3 has
    /// no custom `Drop` that touches the *current* runtime, so the
    /// `block_on(async move { drop(inner) })` below has no await and resolves
    /// immediately; it is kept purely as a harmless defensive wrapper (a live
    /// reactor is in scope if a future turso version ever needs one on drop).
    pub fn close(&self) {
        if check_pid(self.pid).is_err() {
            // Forked child: dropping the engine could block on the parent's
            // worker thread. Leak it; the child's exit reclaims the memory.
            // `try_lock`, because a parent thread may have held the mutex at
            // fork time, leaving it locked with no owner in the child.
            match self.inner.try_lock() {
                Ok(mut g) => std::mem::forget(g.take()),
                Err(std::sync::TryLockError::Poisoned(p)) => {
                    std::mem::forget(p.into_inner().take())
                }
                Err(std::sync::TryLockError::WouldBlock) => {}
            }
            return;
        }
        let inner = self.inner.lock().unwrap_or_else(|p| p.into_inner()).take();
        if inner.is_some() {
            self.rt.block_on(async move { drop(inner) });
        }
    }

    /// Whether this database has been closed (see [`Database::close`]).
    pub fn is_closed(&self) -> bool {
        if check_pid(self.pid).is_err() {
            // Forked child: an inherited handle is unusable, so "closed" is the
            // honest answer, and the mutex may be held by a thread that no
            // longer exists here.
            return match self.inner.try_lock() {
                Ok(g) => g.is_none(),
                Err(std::sync::TryLockError::Poisoned(p)) => p.into_inner().is_none(),
                Err(std::sync::TryLockError::WouldBlock) => true,
            };
        }
        self.inner
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .is_none()
    }
}

impl Drop for Database {
    /// Backstop: a consumer that drops the handle without calling
    /// [`Database::close`] still releases the session uniformly. In a forked
    /// child, `close` leaks the engine and the runtime is not dropped either
    /// (its worker thread only exists in the parent).
    fn drop(&mut self) {
        if check_pid(self.pid).is_err() {
            // `get_mut` never touches the futex (`&mut self` proves exclusive
            // access), so a lock held by a vanished parent thread can't hang us.
            let slot = self.inner.get_mut().unwrap_or_else(|p| p.into_inner());
            std::mem::forget(slot.take());
            return;
        }
        self.close();
        // SAFETY: `rt` is never used again after this point.
        unsafe { ManuallyDrop::drop(&mut self.rt) };
    }
}

impl Connection {
    pub fn execute(&self, sql: &str, params: &[Value]) -> Result<u64> {
        check_pid(self.pid)?;
        let _stmt = self.stmt_lock.lock().unwrap_or_else(|p| p.into_inner());
        let guard = self.conn.lock().unwrap_or_else(|p| p.into_inner());
        let conn = guard.as_ref().ok_or(Error::Closed)?;
        let tparams: Vec<turso::Value> = params.iter().map(Value::to_turso).collect();
        let result = self.rt.block_on(async {
            conn.execute(sql, tparams)
                .await
                .map_err(|e| Error::from_engine(Error::Query, e))
        });
        result
    }

    pub fn query(&self, sql: &str, params: &[Value]) -> Result<Vec<Row>> {
        Ok(self.query_result(sql, params)?.rows)
    }

    /// Like [`Connection::query`], but also captures the result set's column
    /// names — needed by callers (e.g. an ActiveRecord adapter) that must
    /// know column identity, not just positional values.
    pub fn query_result(&self, sql: &str, params: &[Value]) -> Result<QueryResult> {
        check_pid(self.pid)?;
        let _stmt = self.stmt_lock.lock().unwrap_or_else(|p| p.into_inner());
        let guard = self.conn.lock().unwrap_or_else(|p| p.into_inner());
        let conn = guard.as_ref().ok_or(Error::Closed)?;
        let tparams: Vec<turso::Value> = params.iter().map(Value::to_turso).collect();
        let result = self.rt.block_on(async {
            let mut rows = conn
                .query(sql, tparams)
                .await
                .map_err(|e| Error::from_engine(Error::Query, e))?;
            // turso::Rows::columns() reads metadata off the prepared statement,
            // so it's available before stepping and fixed for the result set.
            let cols = rows.columns();
            let columns = cols.iter().map(|c| c.name().to_string()).collect();
            let decl_types = cols
                .iter()
                .map(|c| c.decl_type().map(str::to_string))
                .collect();
            let mut out = Vec::new();
            while let Some(row) = rows
                .next()
                .await
                .map_err(|e| Error::from_engine(Error::Query, e))?
            {
                let n = row.column_count();
                let mut vals = Vec::with_capacity(n);
                for i in 0..n {
                    let cv = row
                        .get_value(i)
                        .map_err(|e| Error::from_engine(Error::Query, e))?;
                    vals.push(Value::from_turso(cv));
                }
                out.push(Row { values: vals });
            }
            Ok(QueryResult {
                columns,
                decl_types,
                rows: out,
            })
        });
        result
    }

    /// Returns the rowid of the last row inserted by this connection.
    ///
    /// Backed by `turso::Connection::last_insert_rowid` (a plain sync call —
    /// it reads state off the connection, no I/O — so unlike the other
    /// methods here it needs no `block_on`). `Result` is kept in this
    /// method's signature for API consistency with the rest of `Connection`,
    /// even though the underlying call cannot fail.
    pub fn last_insert_rowid(&self) -> Result<i64> {
        check_pid(self.pid)?;
        let guard = self.conn.lock().unwrap_or_else(|p| p.into_inner());
        let conn = guard.as_ref().ok_or(Error::Closed)?;
        Ok(conn.last_insert_rowid())
    }

    /// Runs a script of multiple `;`-separated SQL statements (e.g. schema
    /// DDL) in one call.
    ///
    /// Delegates to `turso::Connection::execute_batch`, which parses the
    /// script with the real SQL parser rather than naively splitting on
    /// `;` — so statements containing `;` inside string literals (e.g.
    /// `INSERT INTO t (n) VALUES ('a;b')`) are handled correctly.
    pub fn execute_batch(&self, sql: &str) -> Result<()> {
        check_pid(self.pid)?;
        let _stmt = self.stmt_lock.lock().unwrap_or_else(|p| p.into_inner());
        let guard = self.conn.lock().unwrap_or_else(|p| p.into_inner());
        let conn = guard.as_ref().ok_or(Error::Closed)?;
        let result = self.rt.block_on(async {
            conn.execute_batch(sql)
                .await
                .map_err(|e| Error::from_engine(Error::Query, e))
        });
        result
    }

    /// Close this connection, releasing the underlying `turso::Connection`
    /// handle instead of waiting for GC. Idempotent. After close, the
    /// execution methods return [`Error::Closed`].
    ///
    /// As with [`Database::close`], the drop happens inside `rt.block_on` only
    /// as a harmless defensive wrapper — turso 0.8.3's `Connection` has no
    /// custom `Drop` that awaits, so this resolves immediately.
    pub fn close(&self) {
        if check_pid(self.pid).is_err() {
            // Forked child: dropping the engine could block on the parent's
            // worker thread. Leak it; the child's exit reclaims the memory.
            // `try_lock`, because a parent thread may have held the mutex at
            // fork time, leaving it locked with no owner in the child.
            match self.conn.try_lock() {
                Ok(mut g) => std::mem::forget(g.take()),
                Err(std::sync::TryLockError::Poisoned(p)) => {
                    std::mem::forget(p.into_inner().take())
                }
                Err(std::sync::TryLockError::WouldBlock) => {}
            }
            return;
        }
        let conn = self.conn.lock().unwrap_or_else(|p| p.into_inner()).take();
        if conn.is_some() {
            self.rt.block_on(async move { drop(conn) });
        }
    }

    /// Whether this connection has been closed (see [`Connection::close`]).
    pub fn is_closed(&self) -> bool {
        if check_pid(self.pid).is_err() {
            // Forked child: see `Database::is_closed`.
            return match self.conn.try_lock() {
                Ok(g) => g.is_none(),
                Err(std::sync::TryLockError::Poisoned(p)) => p.into_inner().is_none(),
                Err(std::sync::TryLockError::WouldBlock) => true,
            };
        }
        self.conn
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .is_none()
    }
}

impl Drop for Connection {
    /// Mirrors [`Database`]'s `Drop`, including the forked-child leak.
    fn drop(&mut self) {
        if check_pid(self.pid).is_err() {
            let slot = self.conn.get_mut().unwrap_or_else(|p| p.into_inner());
            std::mem::forget(slot.take());
            return;
        }
        self.close();
        // SAFETY: `rt` is never used again after this point.
        unsafe { ManuallyDrop::drop(&mut self.rt) };
    }
}

#[cfg(all(test, unix))]
mod fork_lock_tests {
    use super::*;
    use std::sync::mpsc;

    /// Fork while another thread holds `lock_it`'s mutex, then run `child_body`
    /// in the child under a 5s alarm. Before the fix the child's `lock()` waited
    /// forever on a futex with no owner, and SIGALRM killed it.
    fn fork_with_lock_held(
        lock_it: impl FnOnce(mpsc::Sender<()>, mpsc::Receiver<()>) + Send + 'static,
        child_body: impl FnOnce(),
    ) {
        let (held_tx, held_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let holder = std::thread::spawn(move || lock_it(held_tx, release_rx));
        held_rx.recv().unwrap();

        let pid = unsafe { libc::fork() };
        assert!(pid >= 0, "fork failed");
        if pid == 0 {
            unsafe { libc::alarm(5) };
            child_body();
            unsafe { libc::_exit(0) };
        }

        let mut status = 0;
        let waited = unsafe { libc::waitpid(pid, &mut status, 0) };
        release_tx.send(()).unwrap();
        holder.join().unwrap();
        assert_eq!(waited, pid, "waitpid returned the wrong pid");
        assert!(
            libc::WIFEXITED(status),
            "child did not exit normally (hung on a held lock?): {status}"
        );
        assert_eq!(libc::WEXITSTATUS(status), 0);
    }

    #[test]
    fn forked_child_does_not_hang_on_database_lock_held_at_fork() {
        let db = Box::new(Database::open(OpenOptions::default()).unwrap());
        let addr = &*db as *const Database as usize;
        fork_with_lock_held(
            move |held, release| {
                // SAFETY: the parent joins this thread before dropping `db`.
                let db = unsafe { &*(addr as *const Database) };
                let _guard = db.inner.lock().unwrap();
                held.send(()).unwrap();
                let _ = release.recv();
            },
            || {
                db.close();
                // Inherited handle is unusable in a child: reported closed.
                assert!(db.is_closed());
                std::mem::drop(db);
            },
        );
    }

    #[test]
    fn forked_child_does_not_hang_on_connection_lock_held_at_fork() {
        let db = Database::open(OpenOptions::default()).unwrap();
        let conn = Box::new(db.connect().unwrap());
        let addr = &*conn as *const Connection as usize;
        fork_with_lock_held(
            move |held, release| {
                // SAFETY: the parent joins this thread before dropping `conn`.
                let conn = unsafe { &*(addr as *const Connection) };
                let _guard = conn.conn.lock().unwrap();
                held.send(()).unwrap();
                let _ = release.recv();
            },
            || {
                conn.close();
                assert!(conn.is_closed());
                std::mem::drop(conn);
                std::mem::drop(db);
            },
        );
    }

    #[test]
    fn forked_child_drop_without_close_does_not_hang_on_held_lock() {
        let db = Box::new(Database::open(OpenOptions::default()).unwrap());
        let addr = &*db as *const Database as usize;
        fork_with_lock_held(
            move |held, release| {
                // SAFETY: the parent joins this thread before dropping `db`.
                let db = unsafe { &*(addr as *const Database) };
                let _guard = db.inner.lock().unwrap();
                held.send(()).unwrap();
                let _ = release.recv();
            },
            || std::mem::drop(db),
        );
    }
}
