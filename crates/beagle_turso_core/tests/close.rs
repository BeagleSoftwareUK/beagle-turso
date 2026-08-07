//! Regression coverage for the leaked-session bug: a synced `Database` opened
//! a server-side sync session with no way to release it short of GC, so every
//! reconnect (as ActiveRecord routinely does) accumulated a session on the
//! remote until it reported "database is busy". `close()` releases the engine
//! handle eagerly. These tests exercise the close contract on a LOCAL database
//! (no network/credentials needed); the synced path is covered by the
//! credential-gated Ruby spec.

use beagle_turso_core::{Database, Error, OpenOptions};

#[test]
fn database_close_makes_connect_return_closed() {
    let db = Database::open(OpenOptions::default()).expect("open in-memory");
    assert!(!db.is_closed());

    db.close();
    assert!(db.is_closed());

    let err = db.connect();
    assert!(
        matches!(err, Err(Error::Closed)),
        "connect() after close should be Err(Error::Closed)"
    );
}

#[test]
fn database_close_is_idempotent() {
    let db = Database::open(OpenOptions::default()).unwrap();
    db.close();
    // A second close must not panic and must leave the database closed.
    db.close();
    assert!(db.is_closed());
}

#[test]
fn database_push_pull_after_close_return_closed() {
    let db = Database::open(OpenOptions::default()).unwrap();
    db.close();
    assert!(matches!(db.push(), Err(Error::Closed)));
    assert!(matches!(db.pull(), Err(Error::Closed)));
}

#[test]
fn connection_close_makes_execute_return_closed() {
    let db = Database::open(OpenOptions::default()).unwrap();
    let conn = db.connect().expect("connect");
    assert!(!conn.is_closed());

    conn.close();
    assert!(conn.is_closed());

    let err = conn.execute("SELECT 1", &[]);
    assert!(
        matches!(err, Err(Error::Closed)),
        "execute() after close should be Err(Error::Closed)"
    );
}

#[test]
fn connection_close_is_idempotent() {
    let db = Database::open(OpenOptions::default()).unwrap();
    let conn = db.connect().unwrap();
    conn.close();
    // A second close must not panic and must leave the connection closed.
    conn.close();
    assert!(conn.is_closed());
}
