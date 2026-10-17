use beagle_turso_core::{Database, Error, OpenOptions};

#[test]
fn push_and_pull_on_local_only_are_not_synced() {
    let db = Database::open(OpenOptions::default()).unwrap();
    assert!(matches!(db.push(), Err(Error::NotSynced("push"))));
    assert!(matches!(db.pull(), Err(Error::NotSynced("pull"))));
}

#[test]
fn not_synced_keeps_the_0_1_message_text() {
    // activerecord-beagle-turso <= 0.1.x matches /on a local-only database/.
    let db = Database::open(OpenOptions::default()).unwrap();
    let msg = db.push().unwrap_err().to_string();
    assert_eq!(msg, "sync failed: push() on a local-only database");
}

#[test]
fn closed_database_reports_closed() {
    let db = Database::open(OpenOptions::default()).unwrap();
    db.close();
    assert!(matches!(db.connect(), Err(Error::Closed)));
    assert!(matches!(db.push(), Err(Error::Closed)));
}

#[test]
fn connection_outlives_database_close() {
    // close() drops the Database's Arc; a Connection made earlier keeps working
    // (unchanged 0.1 behaviour, now explicit).
    let db = Database::open(OpenOptions::default()).unwrap();
    let conn = db.connect().unwrap();
    db.close();
    assert!(conn.query("SELECT 1", &[]).is_ok());
}
