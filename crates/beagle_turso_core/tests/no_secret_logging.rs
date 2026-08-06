use beagle_turso_core::{Database, OpenOptions};

#[test]
fn options_debug_redacts_auth_token() {
    let opts = OpenOptions {
        local_path: "x.db".into(),
        remote_url: Some("libsql://example".into()),
        auth_token: Some("SECRET-eyJshh".into()),
        bootstrap_if_empty: true,
    };
    let printed = format!("{opts:?}");
    assert!(
        !printed.contains("SECRET-eyJshh"),
        "auth_token leaked in Debug: {printed}"
    );
    assert!(
        !printed.contains("libsql://example"),
        "remote_url leaked in Debug: {printed}"
    );
    assert!(printed.contains("[redacted]"));
    assert!(printed.contains("[set]"));
}

/// Even when opening a synced database fails outright (bad remote URL), the
/// resulting `Error`'s `Display`/`Debug` output must never contain the auth
/// token. The failure here is a scheme-validation error raised by turso
/// before any network I/O happens, so this test runs fully offline.
#[test]
fn failed_open_never_leaks_auth_token() {
    let opts = OpenOptions {
        local_path: ":memory:".into(),
        remote_url: Some("not-a-valid-scheme://x".into()),
        auth_token: Some("SECRET-eyJshh".into()),
        bootstrap_if_empty: true,
    };
    // `Database` intentionally doesn't implement `Debug`, so match instead of
    // `expect_err`/`unwrap_err` (which require `T: Debug`).
    let err = match Database::open(opts) {
        Ok(_) => panic!("expected open() to fail on an invalid URL scheme"),
        Err(e) => e,
    };
    let display = format!("{err}");
    let debug = format!("{err:?}");
    assert!(
        !display.contains("SECRET-eyJshh"),
        "auth_token leaked in Error Display: {display}"
    );
    assert!(
        !debug.contains("SECRET-eyJshh"),
        "auth_token leaked in Error Debug: {debug}"
    );
}
