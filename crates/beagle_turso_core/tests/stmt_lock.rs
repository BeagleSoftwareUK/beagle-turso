//! Statements on connections from one `Database` are serialised by a
//! per-Database lock, so autocommit writers never see spurious busy errors.
//! Local temp-file databases only; no network or credentials needed.

use beagle_turso_core::{Database, Error, OpenOptions, Value};
use std::sync::mpsc;
use std::time::{Duration, Instant};

fn temp_db(name: &str) -> (Database, String) {
    let marker = format!(
        "{}_{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    );
    let path = std::env::temp_dir()
        .join(format!("btc_stmt_{name}_{marker}.db"))
        .display()
        .to_string();
    let db = Database::open(OpenOptions {
        local_path: path.clone(),
        remote_url: None,
        auth_token: None,
        bootstrap_if_empty: false,
    })
    .expect("open temp db");
    (db, path)
}

fn cleanup(path: &str) {
    for suffix in ["", "-wal", "-shm", "-log"] {
        let _ = std::fs::remove_file(format!("{path}{suffix}"));
    }
}

#[test]
fn parallel_autocommit_inserts_on_separate_connections_never_busy() {
    let (db, path) = temp_db("parallel");
    let setup = db.connect().unwrap();
    setup.execute("CREATE TABLE t(x INTEGER)", &[]).unwrap();

    let results: Vec<Result<u64, Error>> = std::thread::scope(|s| {
        let handles: Vec<_> = (0..8)
            .map(|i| {
                let db = &db;
                s.spawn(move || {
                    let conn = db.connect().unwrap();
                    (0..200)
                        .map(|_| conn.execute("INSERT INTO t VALUES (?)", &[Value::Integer(i)]))
                        .collect::<Vec<_>>()
                })
            })
            .collect();
        handles
            .into_iter()
            .flat_map(|h| h.join().unwrap())
            .collect()
    });
    for r in &results {
        assert!(r.is_ok(), "insert failed: {:?}", r.as_ref().err());
    }

    let rows = setup.query("SELECT count(*) FROM t", &[]).unwrap();
    assert_eq!(rows[0].values[0], Value::Integer(1600));
    drop(setup);
    drop(db);
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

// Push and pull use `sync_lock` only and never take the statement lock; with a
// local database that is structural, so this test covers what the lock does:
// a second statement waits for a long one running on another connection.
#[test]
fn statements_on_one_database_are_serialised() {
    let (db, path) = temp_db("serial");
    let long = db.connect().unwrap();
    let other = db.connect().unwrap();
    other.execute("CREATE TABLE t(x INTEGER)", &[]).unwrap();

    let (started_tx, started_rx) = mpsc::channel();
    let (long_elapsed, short_elapsed, short_ended_after_long) = std::thread::scope(|s| {
        let h = s.spawn(|| {
            let t0 = Instant::now();
            started_tx.send(()).unwrap();
            long.query_result(
                "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 50000) \
                 SELECT count(*) FROM c",
                &[],
            )
            .unwrap();
            (t0, Instant::now())
        });
        started_rx.recv().unwrap();
        // Let the long statement get past its lock acquisition.
        std::thread::sleep(Duration::from_millis(100));
        let t1 = Instant::now();
        other
            .execute("INSERT INTO t VALUES (?)", &[Value::Integer(1)])
            .expect("second statement succeeds");
        let t2 = Instant::now();
        let (l0, l1) = h.join().unwrap();
        (l1 - l0, t2 - t1, t2 >= l1)
    });

    assert!(
        long_elapsed > Duration::from_millis(300),
        "long query too fast ({long_elapsed:?}) to prove anything"
    );
    assert!(
        short_ended_after_long,
        "second statement finished before the long one ({short_elapsed:?})"
    );
    drop(long);
    drop(other);
    drop(db);
    cleanup(&path);
}
