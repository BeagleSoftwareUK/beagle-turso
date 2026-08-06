use beagle_turso_core::OpenOptions;

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
    assert!(printed.contains("[redacted]"));
}
