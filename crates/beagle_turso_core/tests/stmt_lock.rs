//! Statements on a database file are serialised by a process-wide lock per
//! file, shared by every `Database` opened on it, so autocommit writers never
//! see spurious busy errors. Local temp-file databases only; no network or
//! credentials needed.

use beagle_turso_core::{Connection, Database, Error, OpenOptions, Value};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

fn temp_path(name: &str) -> String {
    let marker = format!(
        "{}_{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    );
    std::env::temp_dir()
        .join(format!("btc_stmt_{name}_{marker}.db"))
        .display()
        .to_string()
}

fn open(path: &str) -> Database {
    Database::open(OpenOptions {
        local_path: path.to_string(),
        remote_url: None,
        auth_token: None,
        bootstrap_if_empty: false,
    })
    .expect("open temp db")
}

fn temp_db(name: &str) -> (Database, String) {
    let path = temp_path(name);
    (open(&path), path)
}

fn cleanup(path: &str) {
    for suffix in ["", "-wal", "-shm", "-log"] {
        let _ = std::fs::remove_file(format!("{path}{suffix}"));
    }
}

/// A recursive count that takes at least `min` on this machine: the row count
/// doubles until it does. `None` if even the largest is quicker.
fn long_query(conn: &Connection, min: Duration) -> Option<String> {
    let mut n = 50_000u64;
    while n <= 100_000_000 {
        let sql = format!(
            "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < {n}) \
             SELECT count(*) FROM c"
        );
        let t0 = Instant::now();
        conn.query(&sql, &[]).unwrap();
        if t0.elapsed() >= min {
            return Some(sql);
        }
        n *= 2;
    }
    None
}

/// Eight threads, 200 autocommit inserts each, one connection per thread from
/// `dbs` in turn. Returns every insert's result.
fn parallel_inserts(dbs: &[&Database]) -> Vec<Result<u64, Error>> {
    std::thread::scope(|s| {
        let handles: Vec<_> = (0..8)
            .map(|i| {
                let db = dbs[i % dbs.len()];
                s.spawn(move || {
                    let conn = db.connect().unwrap();
                    (0..200)
                        .map(|_| {
                            conn.execute("INSERT INTO t VALUES (?)", &[Value::Integer(i as i64)])
                        })
                        .collect::<Vec<_>>()
                })
            })
            .collect();
        handles
            .into_iter()
            .flat_map(|h| h.join().unwrap())
            .collect()
    })
}

fn assert_all_ok(results: &[Result<u64, Error>]) {
    for r in results {
        assert!(r.is_ok(), "insert failed: {:?}", r.as_ref().err());
    }
}

#[test]
fn parallel_autocommit_inserts_on_separate_connections_never_busy() {
    let (db, path) = temp_db("parallel");
    let setup = db.connect().unwrap();
    setup.execute("CREATE TABLE t(x INTEGER)", &[]).unwrap();

    assert_all_ok(&parallel_inserts(&[&db]));

    let rows = setup.query("SELECT count(*) FROM t", &[]).unwrap();
    assert_eq!(rows[0].values[0], Value::Integer(1600));
    drop(setup);
    drop(db);
    cleanup(&path);
}

// What an ActiveRecord pool does: one Database per pooled connection, all on
// one file. The lock is per file, so they never overlap either.
#[test]
fn parallel_inserts_through_separate_databases_on_one_file_never_busy() {
    let path = temp_path("pool");
    let (a, b) = (open(&path), open(&path));
    let setup = a.connect().unwrap();
    setup.execute("CREATE TABLE t(x INTEGER)", &[]).unwrap();

    assert_all_ok(&parallel_inserts(&[&a, &b]));

    let rows = setup.query("SELECT count(*) FROM t", &[]).unwrap();
    assert_eq!(rows[0].values[0], Value::Integer(1600));
    drop(setup);
    drop(a);
    drop(b);
    cleanup(&path);
}

#[test]
fn open_transaction_on_a_still_makes_b_busy_immediately() {
    let (db, path) = temp_db("busy");
    let a = db.connect().unwrap();
    a.execute("CREATE TABLE t(x INTEGER)", &[]).unwrap();
    a.execute_batch("BEGIN IMMEDIATE").unwrap();
    a.execute("INSERT INTO t VALUES (?)", &[Value::Integer(1)])
        .unwrap();

    let b = db.connect().unwrap();
    let (tx, rx) = mpsc::channel();
    let started = Instant::now();
    std::thread::scope(|s| {
        s.spawn(|| {
            let r = b.execute("INSERT INTO t VALUES (?)", &[Value::Integer(2)]);
            tx.send(r).unwrap();
        });
        let r = rx
            .recv_timeout(Duration::from_secs(2))
            .expect("B hung instead of failing fast");
        assert!(matches!(r, Err(Error::Busy(_))), "expected Busy, got {r:?}");
    });
    assert!(started.elapsed() < Duration::from_secs(2));

    a.execute_batch("COMMIT").unwrap();
    b.execute("INSERT INTO t VALUES (?)", &[Value::Integer(2)])
        .expect("B succeeds once A has committed");
    drop(a);
    drop(b);
    drop(db);
    cleanup(&path);
}

// A busy wait inside the engine would hold the statement lock, so A could
// never COMMIT and B would always wait out its whole timeout. The driver turns
// the engine's busy wait off, so B is told at once and A commits.
#[test]
fn pragma_busy_timeout_never_waits_while_holding_the_lock() {
    let (db, path) = temp_db("busy_timeout");
    let a = db.connect().unwrap();
    a.execute("CREATE TABLE t(x INTEGER)", &[]).unwrap();
    a.execute_batch("BEGIN IMMEDIATE").unwrap();
    a.execute("INSERT INTO t VALUES (?)", &[Value::Integer(1)])
        .unwrap();

    let b = db.connect().unwrap();
    b.execute_batch("PRAGMA busy_timeout = 5000").unwrap();
    let started = Instant::now();
    let r = b.execute("INSERT INTO t VALUES (?)", &[Value::Integer(2)]);
    assert!(matches!(r, Err(Error::Busy(_))), "expected Busy, got {r:?}");
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "B waited {:?} inside the engine",
        started.elapsed()
    );

    a.execute_batch("COMMIT").unwrap();
    b.execute("INSERT INTO t VALUES (?)", &[Value::Integer(2)])
        .expect("B succeeds once A has committed");
    drop(a);
    drop(b);
    drop(db);
    cleanup(&path);
}

// Push and pull use `sync_lock` only and never take the statement lock; with a
// local database that is structural, so this test covers what the lock does:
// a second statement, through a second Database on the same file, waits for a
// long one.
#[test]
fn statements_on_one_file_are_serialised() {
    let path = temp_path("serial");
    let (db, other_db) = (open(&path), open(&path));
    let long = db.connect().unwrap();
    let other = other_db.connect().unwrap();
    other.execute("CREATE TABLE t(x INTEGER)", &[]).unwrap();
    let Some(sql) = long_query(&long, Duration::from_millis(500)) else {
        eprintln!("skipped: no long query takes 500 ms on this machine");
        return;
    };

    let (started_tx, started_rx) = mpsc::channel();
    let (other_began, other_ended, long_ended) = std::thread::scope(|s| {
        let h = s.spawn(|| {
            started_tx.send(()).unwrap();
            long.query_result(&sql, &[]).unwrap();
            Instant::now()
        });
        started_rx.recv().unwrap();
        // The long statement takes the lock within this margin; it then runs
        // for at least 500 ms.
        std::thread::sleep(Duration::from_millis(100));
        let began = Instant::now();
        other
            .execute("INSERT INTO t VALUES (?)", &[Value::Integer(1)])
            .expect("second statement succeeds");
        (began, Instant::now(), h.join().unwrap())
    });

    assert!(
        other_began < long_ended,
        "second statement began too late to test anything"
    );
    assert!(
        other_ended >= long_ended,
        "second statement finished before the long one"
    );
    drop(long);
    drop(other);
    drop(db);
    drop(other_db);
    cleanup(&path);
}

#[test]
fn an_interrupted_wait_returns_without_running_the_statement() {
    let path = temp_path("interrupt");
    let (db, other_db) = (open(&path), open(&path));
    let long = db.connect().unwrap();
    let other = other_db.connect().unwrap();
    other.execute("CREATE TABLE t(x INTEGER)", &[]).unwrap();
    let Some(sql) = long_query(&long, Duration::from_millis(500)) else {
        eprintln!("skipped: no long query takes 500 ms on this machine");
        return;
    };

    let flag = AtomicBool::new(false);
    let (started_tx, started_rx) = mpsc::channel();
    std::thread::scope(|s| {
        let h = s.spawn(|| {
            started_tx.send(()).unwrap();
            long.query_result(&sql, &[]).unwrap();
        });
        started_rx.recv().unwrap();
        std::thread::sleep(Duration::from_millis(100));
        s.spawn(|| {
            std::thread::sleep(Duration::from_millis(50));
            flag.store(true, Ordering::Release);
        });
        let began = Instant::now();
        let r =
            other.execute_interruptible("INSERT INTO t VALUES (?)", &[Value::Integer(1)], &flag);
        assert!(
            matches!(r, Err(Error::Interrupted)),
            "expected Interrupted, got {r:?}"
        );
        assert!(
            began.elapsed() < Duration::from_millis(300),
            "gave up only after {:?}",
            began.elapsed()
        );
        assert!(
            !h.is_finished(),
            "the long statement ended first; the wait proved nothing"
        );
        h.join().unwrap();
    });

    let rows = other.query("SELECT count(*) FROM t", &[]).unwrap();
    assert_eq!(
        rows[0].values[0],
        Value::Integer(0),
        "the interrupted insert ran"
    );
    drop(long);
    drop(other);
    drop(db);
    drop(other_db);
    cleanup(&path);
}
