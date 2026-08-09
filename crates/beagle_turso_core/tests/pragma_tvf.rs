//! Regression coverage for the turso 0.7.2 pragma table-valued-function wedge.
//!
//! Querying a pragma TVF (`SELECT ... FROM pragma_table_list`) leaves the
//! connection permanently marked as executing a nested statement, so every
//! later statement skips its commit — writes report success and are visible
//! for the rest of the session, then vanish when it closes. The driver repairs
//! this with a BEGIN/COMMIT pair; see `Connection::repair_pragma_tvf_wedge`.
use beagle_turso_core::{Database, OpenOptions, Value};

fn scratch(name: &str) -> String {
    let dir = std::env::temp_dir().join(format!("beagle-turso-pragma-tvf-{name}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir.join("test.db").to_string_lossy().into_owned()
}

fn open(path: &str) -> Database {
    Database::open(OpenOptions {
        local_path: path.to_string(),
        remote_url: None,
        auth_token: None,
        bootstrap_if_empty: true,
    })
    .unwrap()
}

/// Table names as seen by a FRESH connection — the only thing that proves a
/// write actually committed, since the wedged session still reports its own
/// lost writes as present.
fn committed_tables(path: &str) -> Vec<String> {
    let db = open(path);
    let conn = db.connect().unwrap();
    let rows = conn
        .query("SELECT name FROM sqlite_master WHERE type='table'", &[])
        .unwrap();
    let names = rows
        .iter()
        .map(|row| match &row.values[0] {
            Value::Text(name) => name.clone(),
            other => format!("{other:?}"),
        })
        .collect();
    conn.close();
    db.close();
    names
}

#[test]
fn write_after_pragma_tvf_query_commits() {
    let path = scratch("query");
    let db = open(&path);
    let conn = db.connect().unwrap();

    conn.query("SELECT name FROM pragma_table_list", &[])
        .unwrap();
    conn.execute("CREATE TABLE zz (a integer)", &[]).unwrap();
    conn.close();
    db.close();

    assert!(committed_tables(&path).contains(&"zz".to_string()));
}

#[test]
fn every_write_after_a_pragma_tvf_commits() {
    let path = scratch("many");
    let db = open(&path);
    let conn = db.connect().unwrap();

    conn.query("SELECT name FROM pragma_table_list", &[])
        .unwrap();
    conn.execute("CREATE TABLE zz (a integer)", &[]).unwrap();
    conn.execute("INSERT INTO zz (a) VALUES (1)", &[]).unwrap();
    conn.execute("CREATE TABLE zz2 (a integer)", &[]).unwrap();
    conn.close();
    db.close();

    let tables = committed_tables(&path);
    assert!(tables.contains(&"zz".to_string()), "got {tables:?}");
    assert!(tables.contains(&"zz2".to_string()), "got {tables:?}");
}

#[test]
fn pragma_tvf_in_execute_and_batch_commits() {
    let path = scratch("execute");
    let db = open(&path);
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE seen (name TEXT)", &[]).unwrap();
    conn.execute(
        "INSERT INTO seen (name) SELECT name FROM pragma_table_list",
        &[],
    )
    .unwrap();
    // execute_batch cannot run row-returning statements, so exercise the TVF
    // from a statement that consumes it instead.
    conn.execute_batch("INSERT INTO seen (name) SELECT name FROM pragma_table_list;")
        .unwrap();
    conn.execute("CREATE TABLE zz (a integer)", &[]).unwrap();
    conn.close();
    db.close();

    assert!(committed_tables(&path).contains(&"zz".to_string()));
}

#[test]
fn pragma_tvf_still_returns_its_rows() {
    let db = Database::open(OpenOptions::default()).unwrap();
    let conn = db.connect().unwrap();
    conn.execute("CREATE TABLE widgets (a integer)", &[])
        .unwrap();

    let names: Vec<String> = conn
        .query("SELECT name FROM pragma_table_list", &[])
        .unwrap()
        .iter()
        .map(|row| match &row.values[0] {
            Value::Text(name) => name.clone(),
            other => format!("{other:?}"),
        })
        .collect();

    assert!(names.contains(&"widgets".to_string()), "got {names:?}");
}

/// The repair must not disturb a caller's own transaction: inside an explicit
/// BEGIN the wedge does not occur, and the repair's `BEGIN` fails harmlessly
/// rather than committing the caller's work early or aborting it.
#[test]
fn pragma_tvf_inside_explicit_transaction_is_left_alone() {
    let path = scratch("txn");
    let db = open(&path);
    let conn = db.connect().unwrap();

    conn.execute("BEGIN", &[]).unwrap();
    conn.query("SELECT name FROM pragma_table_list", &[])
        .unwrap();
    conn.execute("CREATE TABLE committed_t (a integer)", &[])
        .unwrap();
    conn.execute("COMMIT", &[]).unwrap();

    conn.execute("BEGIN", &[]).unwrap();
    conn.query("SELECT name FROM pragma_table_list", &[])
        .unwrap();
    conn.execute("CREATE TABLE rolled_back_t (a integer)", &[])
        .unwrap();
    conn.execute("ROLLBACK", &[]).unwrap();
    conn.close();
    db.close();

    let tables = committed_tables(&path);
    assert!(
        tables.contains(&"committed_t".to_string()),
        "got {tables:?}"
    );
    assert!(
        !tables.contains(&"rolled_back_t".to_string()),
        "got {tables:?}"
    );
}

#[test]
fn ordinary_statements_are_unaffected() {
    let path = scratch("plain");
    let db = open(&path);
    let conn = db.connect().unwrap();

    conn.query("PRAGMA table_list", &[]).unwrap();
    conn.execute("CREATE TABLE zz (a integer)", &[]).unwrap();
    conn.execute("INSERT INTO zz (a) VALUES (7)", &[]).unwrap();
    conn.close();
    db.close();

    assert!(committed_tables(&path).contains(&"zz".to_string()));
}
