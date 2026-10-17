#![cfg(unix)]
//! A forked child must not use, or hang dropping, handles inherited from its
//! parent: the parent's Tokio worker thread does not exist in the child.

use beagle_turso_core::{Database, Error, OpenOptions};

#[test]
fn child_gets_forked_error_and_drops_inherited_handles_without_hanging() {
    let db = Database::open(OpenOptions::default()).unwrap();
    let conn = db.connect().unwrap();
    conn.execute("CREATE TABLE t (n INTEGER)", &[]).unwrap();

    let pid = unsafe { libc::fork() };
    assert!(pid >= 0, "fork failed");
    if pid == 0 {
        // Child. SIGALRM kills us if drop hangs, which the parent sees as failure.
        unsafe { libc::alarm(5) };
        let ok_query = matches!(conn.query("SELECT 1", &[]), Err(Error::Forked { .. }));
        let ok_connect = matches!(db.connect(), Err(Error::Forked { .. }));
        db.close(); // must be a no-op, not a hang
        drop(conn);
        drop(db);
        unsafe { libc::_exit(if ok_query && ok_connect { 0 } else { 1 }) };
    }

    let mut status = 0;
    let waited = unsafe { libc::waitpid(pid, &mut status, 0) };
    assert_eq!(waited, pid, "waitpid returned the wrong pid");
    assert!(
        libc::WIFEXITED(status),
        "child did not exit normally (hung or crashed): {status}"
    );
    assert_eq!(
        libc::WEXITSTATUS(status),
        0,
        "child did not see Forked errors"
    );

    // Parent unaffected.
    assert!(conn.query("SELECT 1", &[]).is_ok());
    assert!(db.connect().is_ok());
}
