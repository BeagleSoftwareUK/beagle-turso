# Setting up a new Rails app on beagle_turso

The [README quick start](../README.md#quick-start-rails) shows the two gems and
the `database.yml` entry. That is enough to open a connection; it is **not**
enough to run a real app. This is the full checklist, in order.

Everything here is required unless marked optional. Skipping any of the first
five produces a failure that looks like something else — the "Why this is
required" notes say what you get if you leave it out.

Minimum versions: **`activerecord-beagle-turso` 0.1.4** and **`beagle-turso`
0.1.3**. Earlier versions silently lose writes and column types; see
[Known-bad versions](#known-bad-versions).

---

## 1. Create the Turso databases first

One **dedicated** database per synced environment. Do not point two
environments at one database, and do not reuse a database that the legacy
libSQL driver has written to.

```sh
turso db create myapp-prod
turso db create myapp-staging

turso db show myapp-prod --url          # -> libsql://myapp-prod-<org>.turso.io
turso db tokens create myapp-prod       # -> the auth token
```

Dev and test do **not** get a Turso database. They are local-only files with no
credentials and no cloud sync, so the app works offline.

## 2. Gemfile

```ruby
gem "activerecord-beagle-turso", "~> 0.1"
gem "beagle-turso", "~> 0.1", require: false   # the adapter requires it
```

Both gems are precompiled — no Rust toolchain is needed, in development or in
the Docker build.

## 3. Credentials

```sh
bin/rails credentials:edit
```

```yaml
turso:
  prod_url: libsql://myapp-prod-<org>.turso.io
  prod_token: <token>
  staging_url: libsql://myapp-staging-<org>.turso.io
  staging_token: <token>
```

## 4. `config/database.yml`

Two adapters in one file. The primary is `beagle_turso`; the Solid stores are
**plain `sqlite3`** and must stay that way.

```yaml
default: &default
  adapter: beagle_turso
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  timeout: 5000

# Local sqlite for the Solid stores. NOT beagle_turso: these are local-only
# and must never be synced into the primary's Turso database.
solid_sqlite: &solid_sqlite
  adapter: sqlite3
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  timeout: 5000

development:
  <<: *default
  database: storage/development.sqlite3

test:
  <<: *default
  database: storage/test.sqlite3

<%
  # rescue -> {} so `assets:precompile` in the Docker build (no master key,
  # never connects) doesn't crash.
  turso = begin; Rails.application.credentials.turso || {}; rescue; {}; end
%>
production:
  primary:
    <<: *default
    database: storage/production.sqlite3
    remote_url: <%= turso[:prod_url] || ENV["PROD_TURSO_DATABASE_URL"] %>
    auth_token: <%= turso[:prod_token] || ENV["PROD_TURSO_AUTH_TOKEN"] %>
  cache:
    <<: *solid_sqlite
    database: storage/production_cache.sqlite3
    migrations_paths: db/cache_migrate
  queue:
    <<: *solid_sqlite
    database: storage/production_queue.sqlite3
    migrations_paths: db/queue_migrate
  cable:
    <<: *solid_sqlite
    database: storage/production_cable.sqlite3
    migrations_paths: db/cable_migrate
```

**Why this is required:** point the Solid stores at `beagle_turso` and you push
queue/cache churn into your Turso database and pay sync cost on every job.

## 5. `config/initializers/beagle_turso_database_tasks.rb`

```ruby
# frozen_string_literal: true

# Rails resolves a db: task class by regex-matching the adapter NAME against
# /sqlite/, and "beagle_turso" doesn't match. The local replica is a plain
# sqlite file, so Rails' own SQLite task class is the correct one.
ActiveRecord::Tasks::DatabaseTasks.register_task(
  /beagle_turso/, "ActiveRecord::Tasks::SQLiteDatabaseTasks"
)
```

**Why this is required:** without it any `db:` task that resolves a task class
— `db:seed:replant`, used by `bin/ci` — raises
`ActiveRecord::Tasks::DatabaseNotSupported`.

Note this leaves `structure_dump`/`structure_load` shelling out to the
`sqlite3` CLI, i.e. a second OS process opening the replica, which the
exclusive lock forbids. Harmless while `schema_format` is `:ruby` (the
default). If you switch to `:sql`, revisit it.

## 6. Sync: flush on shutdown + a recurring push

`config/initializers/beagle_turso_sync.rb`:

```ruby
# frozen_string_literal: true

module MyApp                      # your app's module
  module PrimarySync
    def self.flush!
      Beagle::Turso::SyncManager.push!(ActiveRecord::Base.connection)
      true
    rescue Beagle::Turso::SyncManager::NotSyncedError
      false                       # local-only (dev/test) — nothing to push
    end
  end
end
```

`config/recurring.yml`, under **each** synced environment:

```yaml
production:
  beagle_turso_sync:
    class: ActiveRecord::ConnectionAdapters::BeagleTurso::SyncJob
    queue: default
    schedule: every 30 seconds
```

**Why this is required:** writes commit to the local replica immediately but
only reach Turso Cloud on push. Without the recurring job your off-box copy is
whatever the last deploy left; without the shutdown flush (below) a deploy
discards everything written since the last push.

## 7. `config/puma.rb`

```ruby
# Solid Queue must run as THREADS inside Puma, not as a forked process: the
# replica's exclusive lock is per-OS-process, so a forked supervisor would
# deadlock against the web process.
#
# Order matters. `plugin :solid_queue` is what defines the `solid_queue_mode`
# DSL method; calling it first raises NoMethodError.
if ENV["SOLID_QUEUE_IN_PUMA"]
  plugin :solid_queue
  solid_queue_mode :async
end

# Flush local writes to Turso Cloud on graceful shutdown, so a deploy doesn't
# strand them. No-op on local-only connections.
at_exit do
  begin
    MyApp::PrimarySync.flush! if defined?(MyApp::PrimarySync)
  rescue => e
    warn "beagle_turso shutdown flush failed: #{e.class}"
  end
end
```

**Never set `WEB_CONCURRENCY` > 1.** Puma workers are forked processes; a
second worker is a second process opening the same replica file, and it will
fail to start.

## 8. Kamal (`config/deploy.yml`)

```yaml
env:
  clear:
    SOLID_QUEUE_IN_PUMA: true

volumes:
  - "myapp_storage:/rails/storage"      # the ONLY stateful thing on the box
```

That volume holds the primary replica, the Solid sqlite files, and Active
Storage blobs.

**Do not split jobs into their own container**, now or when you outgrow one
server. A job container is a second OS process on the same replica — it moves
the lock fight across a shared volume instead of eliminating it. Decoupling
jobs needs a different data story for the primary first.

### Deploys after the first are brief-downtime

Kamal boots the new container before stopping the old one, and the new one's
`db:prepare` cannot open a replica the old container still holds. So:

```sh
bin/kamal app stop && bin/kamal deploy
```

The *first* cutover deploy is fine with a plain `bin/kamal deploy` — the
outgoing container holds no local-file lock. Every deploy after that needs the
stop first. This is inherent to one local replica per app, not a config toggle.

## 9. Verify before you ship

```sh
bin/rails db:prepare
bin/rails db:migrate:status          # must list your migrations, not "no schema_migrations"
bin/rails db:schema:dump && git diff --stat db/schema.rb   # must be empty
bin/ci
```

`db:migrate:status` is the one that catches a broken setup: an app whose
migration bookkeeping was lost reports "Schema migrations table does not exist
yet" while every other command exits 0.

---

## Known-bad versions

| Version | Bug |
|---|---|
| `beagle-turso` < 0.1.3 | Reading a pragma table-valued function wedges the connection: every later write is discarded silently. `db:prepare` creates your tables but loses `schema_migrations`, and `db:migrate` then exits 0 forever without doing anything. |
| `activerecord-beagle-turso` < 0.1.3 | With `query_log_tags_enabled` (Rails' dev default) the `defer_foreign_keys` bridge misses tagged SQL, so `add_foreign_key` and every other `alter_table` change dies with `query failed: incomplete input`. Also dumps turso's `__turso_internal_*` tables into `db/schema.rb`. |
| `activerecord-beagle-turso` < 0.1.4 | `PRAGMA table_info` drops parenthesised type arguments, so `limit`, `precision` and `scale` all read back as nil. Worse than dump churn: `alter_table` rebuilds tables from that degraded view, so a single `add_foreign_key` permanently strips `decimal(10,2)` down to `decimal` on disk. |

**Upgrading an existing app** on any of these: bump the gems, then rebuild the
local databases — the fixes stop new damage but cannot restore bookkeeping
tables or column types already lost.

```sh
rm -f storage/development.sqlite3* storage/test.sqlite3*
bin/rails db:prepare
```

For a synced environment, check whether any table went through an `alter_table`
under the old gems before trusting its column types.
