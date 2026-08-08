# beagle-turso

A Ruby driver for [Turso](https://turso.tech)'s database engine, backed by a
native Rust extension (`beagle_turso_core`, via [Magnus](https://github.com/matsadler/magnus)/[rb_sys](https://github.com/oxidize-rb/rb-sys)).

A `Database` can be opened two ways:

- **Local-only** — in-memory or an on-disk file, no network involved.
- **Synced** — a local file kept in sync with a remote Turso database via
  `push`/`pull`.

## Install

Add to your `Gemfile`:

```ruby
gem "beagle-turso"
```

or install directly:

```sh
gem install beagle-turso
```

Installing builds the native extension via `rb_sys`/`rake-compiler`, so a
Rust toolchain is required unless a precompiled binary gem is available for
your platform.

## Local example

```ruby
require "beagle/turso"

db = Beagle::Turso::Database.open_local(":memory:")
conn = db.connect

conn.execute("CREATE TABLE users (id INTEGER, name TEXT)", [])
conn.execute("INSERT INTO users (id, name) VALUES (?, ?)", [1, "Ada"])

rows = conn.query("SELECT id, name FROM users", [])
# => [[1, "Ada"]]
```

`execute` returns the number of affected rows (an `Integer`); `query`
returns an `Array` of row `Array`s. Bind parameters may be `nil`, `Integer`,
`Float`, `String` (bound as `TEXT`), or a binary `String` — one with
`ASCII-8BIT`/`BINARY` encoding — bound as `BLOB`.

## Synced example

```ruby
require "beagle/turso"

db = Beagle::Turso::Database.open(
  local_path: "/path/to/local.db",
  remote_url: ENV.fetch("TURSO_DATABASE_URL"),
  auth_token: ENV.fetch("TURSO_AUTH_TOKEN")
)

conn = db.connect
conn.execute("INSERT INTO users (id, name) VALUES (?, ?)", [2, "Grace"])

db.push # propagate local writes to the remote
db.pull # pull remote changes down to the local file (returns true/false)
```

`Database.open` also accepts `bootstrap_if_empty:` (defaults to `true`),
which pulls all remote data down on first open if the local file is new/empty.
Calling `push`/`pull` on a database opened via `open_local` (or via `open`
without both `remote_url:` and `auth_token:`) raises `RuntimeError`.

### Durability note: writes commit on-sync, not synchronously

Writes to a synced database commit to the **local** file immediately, as
part of `execute` — they do not wait on the network. They are only
propagated to the remote **on sync**, i.e. whenever `push` is explicitly
called; `push` is not called automatically after every write. Until a
`push` succeeds, a write that's durable locally is not yet visible to other
replicas of the same remote database.

## Which Turso database?

Point a synced database at a Turso database **dedicated to this engine** —
ideally a fresh, empty one. On first open of an empty local replica,
`bootstrap_if_empty` pulls the remote down; against a fresh remote that's a
clean start, and the engine then manages its own state in that database (it
creates `turso_cdc`, `__turso_internal_*`, and `turso_sync_last_change_id`
tables and takes an **exclusive lock** on the local replica file — only one
OS process may hold a given replica open at a time).

Two things to avoid:

- **Don't co-host a synced database with the legacy libSQL/Hrana driver.**
  This engine (Turso's newer Rust core) and the classic libSQL client have
  different write/sync models; running both against the same remote database
  at once risks corrupting its sync state. Give this engine its own database.
- **Migrating an existing, populated libSQL database into the synced engine
  is not validated.** A fresh database is the supported, tested path. If you
  must adopt existing data, treat it as unproven — test push/pull round-trips
  before relying on it.

A single remote database, dedicated to this engine and written by one process
at a time, is the model it's built for.

## Credential safety

`auth_token` is never included in `inspect` output or in error messages —
confirmed by this gem's `no_secret_logging_spec.rb`.

## License

[MIT](https://opensource.org/licenses/MIT).
