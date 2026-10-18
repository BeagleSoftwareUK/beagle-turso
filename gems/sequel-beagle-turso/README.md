# sequel-beagle-turso

A [Sequel](https://sequel.jeremyevans.net) adapter for the
[`beagle-turso`](../beagle-turso) driver, so Sequel, [ROM](https://rom-rb.org)
and [Hanami](https://hanamirb.org) can run on [Turso](https://turso.tech)'s new
engine: a local SQLite-compatible replica that syncs to Turso Cloud.

SQL generation, schema parsing and transactions come from Sequel's shared
SQLite support. The adapter replaces the plumbing (connections, execution,
value conversion) and works around the engine's differences from SQLite.

## Install

```ruby
# Gemfile
gem "sequel-beagle-turso", "~> 0.1"
```

Sequel loads the adapter lazily the first time you connect to a
`beagle-turso://` URL or pass `adapter: :beagle_turso`. To load it yourself,
`require "sequel-beagle-turso"`.

## Connect

```ruby
require "sequel"

DB = Sequel.connect("beagle-turso:///abs/path/app.db")  # absolute path
DB = Sequel.connect("beagle-turso://./app.db")          # relative path
DB = Sequel.connect("beagle-turso:/")                   # in memory
DB = Sequel.connect(adapter: :beagle_turso, database: "app.db")
```

**A synced replica.** Pass `remote_url:` and `auth_token:` as options, never in
the URL. A URL carrying `auth_token` raises, because URLs end up in logs:

```ruby
DB = Sequel.connect(
  "beagle-turso:///abs/path/app.db",
  remote_url: ENV.fetch("TURSO_DATABASE_URL"),
  auth_token: ENV.fetch("TURSO_AUTH_TOKEN")
)
```

The adapter removes `auth_token` from the `Database`'s options once the replica
is open. Push and pull go through the replica: `DB.turso_database.push` and
`DB.turso_database.pull`. See the
[driver README](../beagle-turso#readme) for the durability model, and for which
Turso database to use.

**Sharing a replica.** If you already have an open `Beagle::Turso::Database`,
pass it as `turso_database:` and the `Database` uses it instead of opening one.
The adapter never closes a replica it was handed.

**Closing.** `DB.disconnect` closes the pooled connections and leaves the
replica open. `DB.close_replica` disconnects, then closes the replica that this
`Database` opened. A synced replica is held by one OS process at a time, so
close it before something else needs the file.

Other options: `timeout:` (ms, default 5000, see Writes), `transaction_mode:`,
and `bootstrap_if_empty:` (passed to the driver).

## Hanami and ROM

```ruby
Hanami.app.configure_provider :db do
  config.gateway(:default) do |gw|
    gw.database_url = "beagle-turso://#{Hanami.app.root.join("db/app.db")}"
    gw.connection_options(remote_url: ENV["TURSO_DATABASE_URL"], auth_token: ENV["TURSO_AUTH_TOKEN"])
  end
end
```

- ROM's gateway keeps its own copy of the connection options. The adapter
  scrubs the token from the `Database` it builds, but not from that copy, so
  don't log the gateway's options.
- The `hanami db` commands don't support the `beagle-turso` scheme. Run
  migrations through `ROM::SQL::Migration::Migrator` on the app's gateway, with
  the server stopped (a synced replica is held by one process).

## Writes

The engine allows one writer at a time and reports contention immediately.

- Outside a transaction, and at `BEGIN`, the adapter waits in Ruby (with
  backoff) for up to `timeout:` ms (default 5000), then raises
  `Sequel::DatabaseLockTimeout`.
- Explicit transactions use `BEGIN IMMEDIATE`, so a transaction waits for the
  write lock at its start instead of failing partway. `transaction_mode:`
  (`:deferred`, `:immediate`, `:exclusive`) changes the default, and
  `db.transaction(mode: ...)` overrides it per transaction.
- Inside a transaction, contention surfaces as an error (and the transaction
  rolls back) instead of being retried.
- Don't set `PRAGMA busy_timeout`. Its wait holds the GVL, so the writer that
  holds the lock can't commit.
- Because of `BEGIN IMMEDIATE`, read-only `db.transaction { }` blocks and
  `Dataset#paged_each` take the write lock and queue behind writers. Pass
  `mode: :deferred` for read-only transactions.
- Statements run inside a manual `db.run("BEGIN")` aren't seen as a transaction
  by Sequel, so they get the autocommit busy retry. Use `db.transaction`.
- A `db.run` with several statements (`"INSERT ...; INSERT ..."`) is never
  retried, since a retry could re-run a statement that already committed. If
  the write lock is taken it raises `Sequel::DatabaseLockTimeout` at once, and
  statements before the failing one may already be committed. Run statements
  one at a time, or in a `db.transaction`. (A `;` inside a string literal also
  counts as a second statement.)

**Pool size.** The engine allows many connections (32 and more) to one
replica, but only one writer at a time. `max_connections` defaults to 4. Under
write-heavy load a smaller pool makes writers queue in Sequel's pool rather
than busy-retry against each other. An in-memory database defaults to one
connection.

## Fork (Puma, Unicorn, forking job runners)

A replica belongs to the process that opened it. After `fork`, the child's
inherited pooled connections raise `Sequel::DatabaseDisconnectError` and are
dropped, and opening new ones raises `Sequel::DatabaseConnectionError`
(`Beagle::Turso::ForkedError`). `DB.disconnect` before forking is not enough,
because the replica itself can't cross the fork. Create the `Sequel::Database`
in each process after it forks (for Puma, in `on_worker_boot`), and don't open
it in the parent. A replica file is locked by one process at a time, so give
each process its own replica file.

## Falcon and fibers

Call `Sequel.extension :fiber_concurrency` before connecting, so the pool hands
out connections per fiber rather than per thread. The driver README's
[Threads, fibers and fork](../beagle-turso#threads-fibers-and-fork) section
covers the GVL and Falcon notes, including what runs on Ruby 3.3 and 4.0.

## Limitations

- The sync engine's own tables (`turso_cdc`, `turso_cdc_version`,
  `turso_sync_last_change_id`) are hidden from `tables` and `views`, so cleaners
  and schema dumpers can't truncate the change log.
- The engine doesn't support generated columns, `WITHOUT ROWID` tables, fts5 or
  `ATTACH`.
- Declared-type arguments (`varchar(255)`, `numeric(12,0)`) aren't reported by
  the engine, so `schema` has no `:max_length` for string columns.
- `LIKE` is always case-insensitive: the engine ignores
  `PRAGMA case_sensitive_like`.
- `alter_table` operations that rebuild the table fail, and roll back cleanly,
  if another table's trigger references the rebuilt table.
- Dropping a self-referencing table that has rows works outside a transaction
  only (the adapter retries with foreign keys off). Inside a transaction it
  raises.
- **Known engine issue: self-referencing foreign keys.** Turso's engine has open bugs with foreign keys that reference their own table
  (such as `parent_id`): a multi-row `DELETE`, `UPDATE` or `DROP` that SQLite accepts can fail with
  `FOREIGN KEY constraint failed`, and `ON DELETE SET NULL` / `CASCADE` can leave
  rows behind or orphaned
  ([tursodatabase/turso#8713](https://github.com/tursodatabase/turso/issues/8713),
  [#9279](https://github.com/tursodatabase/turso/issues/9279),
  [#9293](https://github.com/tursodatabase/turso/issues/9293),
  [#9294](https://github.com/tursodatabase/turso/issues/9294)). Foreign keys
  between two different tables are unaffected. Workaround: avoid `ON DELETE`
  actions on self-referencing foreign keys, and delete children before parents,
  one level at a time.

- **Known engine issue: insert ids on MVCC replicas.** On a replica in MVCC
  journal mode with change data capture on (every synced replica of a
  `--tursodb` remote), `last_insert_rowid` returns the change-log id, not the
  inserted row's rowid
  ([tursodatabase/turso#9551](https://github.com/tursodatabase/turso/issues/9551)).
  The adapter doesn't use it: `Dataset#insert` appends `RETURNING rowid` to the
  statement and returns the last row's rowid (`nil` if nothing was inserted,
  such as `insert_ignore` hitting a duplicate), so ids are correct everywhere.
  Code that calls the driver's `last_insert_rowid` itself is still affected.
- **Renames are refused on synced replicas.** The sync engine doesn't capture
  `ALTER TABLE ... RENAME TO` or `RENAME COLUMN` for sync, so the remote never
  sees the rename and later writes to the table are lost on push. When
  `turso_database.synced?`, `rename_table`, `alter_table { rename_column }` and
  the `alter_table` operations that rebuild a table (`set_column_type`,
  `set_column_allow_null`, `set_column_default`, constraint changes, adding a
  unique or primary key column and so on, which end in a rename) raise
  `Sequel::Error`. Local-only replicas are unaffected. Workaround: create the
  new table, copy the rows and drop the old one, or run the rename against the
  remote database directly.

The full list of Sequel integration tests excluded for engine gaps, with a
reason for each, is in
[`spec/integration_known_failures.txt`](spec/integration_known_failures.txt).

## Testing

```bash
bundle exec rspec            # the adapter's own specs, including a ROM smoke test
script/sequel-integration    # Sequel's own integration suite
```

`script/sequel-integration` clones the Sequel release matching the installed
version, runs its `spec/integration` suite against this adapter and excludes the
tests in `spec/integration_known_failures.txt` by exact name. The remote specs
need `TURSO_DATABASE_URL` and `TURSO_AUTH_TOKEN` for a dedicated test database,
and skip cleanly without them.

## License

[MIT](https://opensource.org/licenses/MIT).
