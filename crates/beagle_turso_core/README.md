# beagle_turso_core

A synchronous Rust façade over the [Turso](https://turso.tech) database engine.

`turso`'s own API is async. `beagle_turso_core` wraps it behind a plain
blocking `Database` / `Connection` pair (via an internal single-threaded
Tokio runtime), so callers don't need to bring their own async runtime —
useful at FFI boundaries such as a Ruby extension.

A `Database` can be opened two ways:

- **Local-only** — in-memory or an on-disk file, no network involved.
- **Synced** — a local file kept in sync with a remote Turso database via
  `Database::push` / `Database::pull`. Writes commit to the local file
  immediately as they happen; `push()` is what propagates them to the
  remote, and `pull()` brings remote changes down.

## Example

The example below only touches the local, offline path — an in-memory
database — so it needs no network access or credentials. It's also run as
a doctest in `src/lib.rs`.

```rust
use beagle_turso_core::{Database, OpenOptions, Value};

let db = Database::open(OpenOptions::default()).unwrap();
let conn = db.connect().unwrap();
conn.execute("CREATE TABLE t (n TEXT)", &[]).unwrap();
conn.execute("INSERT INTO t (n) VALUES (?)", &[Value::Text("x".into())]).unwrap();
let rows = conn.query("SELECT n FROM t", &[]).unwrap();
assert_eq!(rows[0].values[0], Value::Text("x".into()));
```

## Public API

`Value`, `Error`, `Result`, `OpenOptions`, `Database`, `Connection`, `Row`.

## Notes

- `OpenOptions`'s `Debug` implementation redacts `auth_token` — credentials
  are never written to logs.
- Pinned to `turso = "=0.7.2"` (a pre-1.0 crate); the version is held exact
  until its API stabilizes.
- The synced round-trip test (`tests/sync.rs`) needs `TURSO_DATABASE_URL` /
  `TURSO_AUTH_TOKEN` and SKIPs when they're absent (e.g. in CI).

## License

MIT
