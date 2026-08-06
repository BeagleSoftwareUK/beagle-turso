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
