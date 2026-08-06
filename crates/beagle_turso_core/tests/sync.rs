use beagle_turso_core::{Database, OpenOptions, Value};

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|s| !s.is_empty())
}

#[test]
fn synced_write_pushes_and_fresh_replica_sees_it() {
    let (Some(url), Some(token)) = (env("TURSO_DATABASE_URL"), env("TURSO_AUTH_TOKEN")) else {
        eprintln!("SKIP: TURSO_DATABASE_URL/TURSO_AUTH_TOKEN not set");
        return;
    };

    // unique marker so we prove THIS run round-trips
    let marker = format!("btc-{}", std::process::id());
    let dir = std::env::temp_dir();
    let path_a = dir.join(format!("btc_a_{marker}.db")).display().to_string();
    let path_b = dir.join(format!("btc_b_{marker}.db")).display().to_string();

    let opts_a = OpenOptions {
        local_path: path_a,
        remote_url: Some(url.clone()),
        auth_token: Some(token.clone()),
        bootstrap_if_empty: true,
    };
    let db_a = Database::open(opts_a).unwrap();
    let conn_a = db_a.connect().unwrap();
    conn_a
        .execute("CREATE TABLE IF NOT EXISTS m (name TEXT)", &[])
        .unwrap();
    conn_a
        .execute(
            "INSERT INTO m (name) VALUES (?)",
            &[Value::Text(marker.clone())],
        )
        .unwrap();
    db_a.push().unwrap();

    let opts_b = OpenOptions {
        local_path: path_b,
        remote_url: Some(url),
        auth_token: Some(token),
        bootstrap_if_empty: true,
    };
    let db_b = Database::open(opts_b).unwrap();
    db_b.pull().unwrap();
    let conn_b = db_b.connect().unwrap();
    let rows = conn_b
        .query(
            "SELECT count(*) FROM m WHERE name = ?",
            &[Value::Text(marker)],
        )
        .unwrap();
    assert_eq!(rows[0].values[0], Value::Integer(1));
}
