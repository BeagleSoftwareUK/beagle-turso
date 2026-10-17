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
without both `remote_url:` and `auth_token:`) raises
`Beagle::Turso::NotSyncedError`.

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

## Errors

Every error the driver raises is a `Beagle::Turso::Error`, a `RuntimeError`
subclass: `OpenError`, `ConnectError`, `QueryError`, `SyncError`,
`NotSyncedError` (push/pull on a local-only database), `BusyError` (another
session or process holds the database), `ClosedError` and `ForkedError`. An
unsupported bind parameter type raises Ruby's `TypeError`. Auth, network and
protocol failures during sync all arrive as `SyncError` (or `OpenError` at
open): the engine does not distinguish them. Messages never contain the auth
token.

Busy conditions now raise `BusyError` with a message beginning
`database is busy:` (0.1.x said `query failed:` / `sync failed:`); it is
still a `RuntimeError`. A replica file already held by another process raises
`OpenError` ("... File is locked by another process").

## Threads, fibers and fork

- One `Database` may be shared by threads. Give each thread its own
  `Connection`; a shared `Connection` works but serializes its callers.
- `open`, `connect`, `push` and `pull` release the GVL, so other threads keep
  running while they wait on the network. Queries keep it; they are local and
  fast.
- While one thread pushes, `closed?` returns immediately on other threads, and
  queries on other connections proceed.
- On a synced database, `connect` called while another thread is pushing waits
  inside the engine until the push finishes (about the push's duration); the
  GVL is released while it waits, so other threads and fibers keep running.
  Open connections up front (e.g. at boot / pool warm-up) rather than per
  request.
- `close` during an in-flight `push` is safe: the push finishes or raises, and
  later calls raise `ClosedError`.
- A blocked native call cannot be interrupted: `Timeout` and `Thread#kill`
  take effect when it returns.
- **Falcon / Async:** on Ruby 4.0+ with `async` 2.25+ (enable its worker pool
  with `ASYNC_SCHEDULER_WORKER_POOL=true` or
  `Async::Scheduler.new(worker_pool: true)`), a fiber scheduler runs these
  calls on a worker thread, so the reactor keeps serving other requests during
  a sync. On Ruby 3.3/3.4 the GVL is still released, but the scheduler's own
  thread blocks. Run sync from a dedicated thread there. Run one Falcon
  process per replica (`--count 1`): the replica file is locked to one
  process.
- **Fork:** handles are bound to the process that opened them. In a forked
  child, `open`, `connect`, `push`, `pull` and queries on an inherited handle
  raise `ForkedError`; open a new database there. `close` is a no-op and
  `closed?` is safe (it reports the handle as closed if it can't be inspected),
  so inherited handles need no cleanup in the child.

## Background sync

`Beagle::Turso::Syncer` keeps the remote copy current without a job system:

```ruby
db = Beagle::Turso::Database.open(local_path: "app.db", remote_url: url, auth_token: token)

syncer = Beagle::Turso::Syncer.new(
  db,
  interval: 30,        # seconds between cycles
  pull: true,          # pull after each push (false = push only)
  max_backoff: 300,    # retry delay cap, seconds
  on_error: ->(error, status) { ErrorTracker.notify(error) },
  logger: Logger.new($stderr),
).start

syncer.status   # => #<data Status running=true, syncing=false, last_push_at=..., ...>
syncer.sync_now # one cycle now, on this thread; :ok, or :busy if one is running
                # (a failure is recorded, passed to on_error, then re-raised)

# on shutdown, before closing the database:
syncer.stop(timeout: 10)   # waits for an in-flight sync, then pushes once more
# syncer.stop(timeout: 10, final_push: false)  # waits, but doesn't push again
db.close
```

- **Opt-in.** Requiring the gem starts nothing. `start` runs one background
  thread. `push` and `pull` release the GVL, so that thread doesn't hold up
  requests on other threads or a Falcon reactor.
- **Failures don't stop it.** Each failure is logged (at `warn`) and passed to
  `on_error`. The next attempt waits `interval × 2ⁿ`, capped at
  `max_backoff`, with ±20% jitter. A success resets the count. A failed push
  skips that cycle's pull. A logger or `on_error` that raises a
  `StandardError` is ignored (an `on_error` error is logged).
- **`sync_now` re-raises.** A failed `sync_now` records the failure in
  `status`, logs it, calls `on_error`, then raises the error to you. Since
  `on_error` has already seen it, don't report it again from a `rescue`. If
  the error message carried a URL or credential, both `on_error` and the
  caller get a copy of the error (same class and backtrace) with the redacted
  message.
- **Status is for monitoring, not lag.** `last_push_at` says when a push last
  succeeded, not how much is still unpushed. Alert when `consecutive_failures`
  grows, or when `last_push_at` gets older than you can tolerate. The site keeps
  serving from the local replica either way. `destination` is the remote host
  only, and error messages are stripped of URLs and tokens.
- **Shutdown is best-effort.** `stop(timeout:, final_push: true)` stops the
  loop, waits for a cycle in flight on any thread (the loop or a concurrent
  `sync_now`), then pushes once more unless `final_push: false`. It waits up
  to `timeout` seconds in total. A push or pull already in flight can't be
  interrupted, so if the deadline passes, `stop` returns with
  `status.syncing == true` and the work finishes in the background; process
  exit then waits for that native call to return (until your platform's kill
  timeout). `stop(timeout: 0)` skips the final push. Called from inside
  `on_error`, `stop` can't wait for the cycle it is part of, so it returns
  without a final push. If the network is down, the deadline passes, or the
  process is killed, writes stay local until the next process pushes them.
  `stop` never closes the database; do that after it returns.
- **Don't call `stop` from a signal handler.** Inside `Signal.trap` it raises
  `ThreadError` (it takes locks). Call it from your server's shutdown hook or
  `at_exit`.
- **One syncer per process, created after fork.** A stopped syncer can't be
  restarted, so create a new one. With Puma in single mode, create it in an
  initializer or `on_booted`; in cluster mode, create it in `on_worker_boot`
  (each worker gets its own) and call `stop` from `on_worker_shutdown` or
  `at_exit`.

## Credential safety

`auth_token` is never included in `inspect` output or in error messages —
confirmed by this gem's `no_secret_logging_spec.rb`.

## License

[MIT](https://opensource.org/licenses/MIT).
