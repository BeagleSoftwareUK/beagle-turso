use beagle_turso_core::{Database, OpenOptions, Value};

#[test]
fn local_insert_and_query_roundtrip() {
    let db = Database::open(OpenOptions::default()).expect("open in-memory");
    let conn = db.connect().expect("connect");

    conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", &[])
        .expect("create");
    let affected = conn
        .execute(
            "INSERT INTO t (name) VALUES (?)",
            &[Value::Text("alice".into())],
        )
        .expect("insert");
    assert_eq!(affected, 1);

    let rows = conn.query("SELECT name FROM t", &[]).expect("select");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].values[0], Value::Text("alice".into()));
}

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

#[test]
fn last_rowid_and_batch() {
    let db = Database::open(OpenOptions::default()).unwrap();
    let c = db.connect().unwrap();
    c.execute_batch(
        "CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT); INSERT INTO t (n) VALUES ('x');",
    )
    .unwrap();
    assert_eq!(c.last_insert_rowid().unwrap(), 1);
    c.execute("INSERT INTO t (n) VALUES (?)", &[Value::Text("y".into())])
        .unwrap();
    assert_eq!(c.last_insert_rowid().unwrap(), 2);
}

#[test]
fn query_result_exposes_column_names() {
    let db = Database::open(OpenOptions::default()).unwrap();
    let conn = db.connect().unwrap();
    conn.execute("CREATE TABLE t (id INTEGER, name TEXT)", &[])
        .unwrap();
    conn.execute(
        "INSERT INTO t (id, name) VALUES (?, ?)",
        &[Value::Integer(1), Value::Text("a".into())],
    )
    .unwrap();
    let r = conn.query_result("SELECT id, name FROM t", &[]).unwrap();
    assert_eq!(r.columns, vec!["id".to_string(), "name".to_string()]);
    assert_eq!(
        r.rows[0].values,
        vec![Value::Integer(1), Value::Text("a".into())]
    );
}
