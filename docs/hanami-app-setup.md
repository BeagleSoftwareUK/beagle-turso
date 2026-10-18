# Setting up a Hanami app on Turso, served by Falcon

The [`sequel-beagle-turso` README](../gems/sequel-beagle-turso#hanami-and-rom)
shows the gateway options that open a connection. That is enough to boot; it is
**not** enough to run a real app. This is the checklist, in order, for a Hanami
3 app (ROM + Sequel) on a local-first Turso replica, served by Falcon. It is
the Hanami counterpart of the [Rails guide](rails-app-setup.md).

Everything here is required unless marked optional. Most of these items fail in
a way that looks like something else; each "why" note says what you get if you
skip it.

The snippets come from two apps that run this setup: a throwaway proof of
concept (a notes app on Hanami 3.0.2, Falcon 0.57.0, Ruby 4.0.7, Turso engine
0.8.3) and a real Hanami app. `YourApp` stands for your app's namespace.
Placeholders only: never put a real URL or token in a file you commit.

---

## 1. Gems

```ruby
# Gemfile
gem "beagle-turso", "~> 0.3"
gem "sequel-beagle-turso", "~> 0.1"
gem "falcon", "~> 0.57"
gem "async", ">= 2.25"

group :test do
  gem "database_cleaner-sequel"
end
```

The gems are precompiled for common platforms; on others they need a Rust toolchain.

`async` 2.25 or newer is what lets a push or pull run off the Falcon reactor
(see [Falcon](#7-falcon)). That needs Ruby 4.0. On 3.3 and 3.4 the GVL is
released during a sync, but the scheduler's own thread blocks; see the
[driver README](../gems/beagle-turso#threads-fibers-and-fork).

## 2. The Turso database and the environment variables

**One dedicated Turso database per app and per environment.** Do not point two
apps, or development and production, at one database. A wrong URL is silent:
the replica happily pushes into whatever it is pointed at (the
[Rails guide](rails-app-setup.md#10-watch-the-sync-not-just-the-site) tells the
story of an app that pushed into another app's production database for ~19
hours). Create each one with `--tursodb`, which is easy to forget and fails
only when the app first opens the replica; see
[Create the Turso databases first](rails-app-setup.md#1-create-the-turso-databases-first).

```sh
turso db create myapp-dev --tursodb
turso db show myapp-dev --url       # -> libsql://myapp-dev-<org>.turso.io
turso db tokens create myapp-dev
```

Keep the variables out of git. Hanami's convention is to commit `.env` and keep
secrets in `.env.local` (gitignored). Hanami 3 loads `.env.local` in every
environment except test, via `dotenv` (development and test group only); use that.

```sh
# .env            (committed)
DATABASE_URL=beagle-turso://db/app.db

# .env.test       (committed)
DATABASE_URL=beagle-turso://db/app_test.db

# .env.local      (NOT committed: development only)
TURSO_DATABASE_URL=libsql://<db>-<org>.turso.io
TURSO_AUTH_TOKEN=<token>
```

Names: `TURSO_DATABASE_URL` and `TURSO_AUTH_TOKEN`, the same as the adapter READMEs.
Dev and test can run without them as a plain local file.

**Production loads no `.env` file** (`dotenv` is in the development and test
group). Set `DATABASE_URL`, `TURSO_DATABASE_URL` and `TURSO_AUTH_TOKEN` in the
real environment or your secret store. If one is missing, `ENV.fetch` raises at
boot, which under Falcon shows up only as the worker restart loop described in
[section 6](#6-the-turso_sync-provider).

### Optional: refuse to boot against the wrong database

Check that the remote host starts with the database name you expect for this
environment. Compare the host, and never print the URL (the error message names
the environment and the expected database only). The check is part of the
provider in the next section.

## 3. `DATABASE_URL`

```
beagle-turso://db/app.db        # relative to the process's working directory
beagle-turso:///var/data/app.db # absolute
```

The URL holds a **path only**: no host, no credentials. The scheme is
`beagle-turso`, with a hyphen, not `beagle_turso`: URI schemes cannot contain an
underscore. The remote URL and token go in as connection options (next
section), because a URL with a token in it ends up in logs; the adapter raises
if it sees one.

## 4. The db provider

`config/providers/db.rb`:

```ruby
# frozen_string_literal: true

# Sequel's pool must key connections by fiber under Falcon; this has to be
# loaded before the first Sequel.connect.
require "sequel"
require "uri"
Sequel.extension :fiber_concurrency

Hanami.app.configure_provider :db do
  config.gateway :default do |gw|
    gw.database_url = ENV.fetch("DATABASE_URL")
    # Test env never syncs, even if credentials are exported in the shell or CI.
    remote = !Hanami.env?(:test) && ENV["TURSO_DATABASE_URL"].to_s != ""
    if remote
      # Optional: refuse to sync with another app's or environment's database.
      # Compare hosts without printing the URL.
      expected = ENV.fetch("TURSO_DATABASE_NAME") { {development: "myapp-dev", production: "myapp-prod"}.fetch(Hanami.env, nil) }
      host = URI(ENV.fetch("TURSO_DATABASE_URL")).host.to_s
      unless expected && host.start_with?("#{expected}-")
        raise "TURSO_DATABASE_URL is not the #{expected || "expected"} database for #{Hanami.env}; " \
          "fix .env.local or set TURSO_DATABASE_NAME"
      end
    end
    opts = remote ? {remote_url: ENV.fetch("TURSO_DATABASE_URL"), auth_token: ENV.fetch("TURSO_AUTH_TOKEN")} : {}
    gw.connection_options(**opts)
  end

  # Providers stop in registration order; stop sync (final push) before the
  # gateway disconnects.
  before(:stop) { slice.stop(:turso_sync) if slice.registered?("turso_sync.syncer") }
end
```

What each piece is for:

- **`Sequel.extension :fiber_concurrency` before the first connect.** Falcon runs
  every request in a fiber on one thread. Without the extension the pool hands
  every fiber on the thread the same connection, so concurrent requests share
  one connection and its transaction state.
- **The test-env guard.** `.env.local` is not loaded in test, but variables
  exported in the shell or CI, or an `.env.test.local` file, are. Without the
  guard a test run with those present uses a synced replica and writes test
  rows to Turso Cloud. Tests are always local-only.
- **`before(:stop)` uses `registered?`, not `key?`.** `key?` loads the provider
  lazily, which raises ("can't add a new key into hash during iteration") when
  Hanami shuts down in prepared mode.
- **Don't log the gateway's options, `db.config` or `ENV`.** ROM's gateway
  keeps its own copy of the connection options; the adapter scrubs the token
  from the `Sequel::Database` it builds but not from that copy.

## 5. Migrations

**`hanami db migrate` cannot be used.** hanami-cli does not know the
`beagle-turso://` scheme, so every `hanami db ...` command fails. Run migrations
with `bin/migrate`, below.

Three rules:

1. **The server must be stopped.** A synced replica is held by one OS process.
   A second process (`bin/migrate`, a console, a second Falcon worker) fails
   fast with `OpenError: ... File is locked by another process`.
2. **`prepare(:db)`, not `start`.** `start` builds the ROM container, which
   infers each relation's schema and fails before the table exists, i.e. on
   the very first migration.
3. **Push before and after.** See below.

`bin/migrate`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs pending migrations on the app's gateway. `hanami db migrate` can't:
# hanami-cli doesn't know the beagle-turso:// scheme. Run it with the server
# stopped: the replica file is locked to one process.
require "bundler/setup"
require "hanami/prepare"

# prepare (not start) the db provider: start builds the ROM container, which
# infers relation schemas and fails before the table exists.
Hanami.app.prepare(:db)
gateway = Hanami.app["db.gateway"]
migrator = ROM::SQL::Migration::Migrator.new(gateway.connection, path: File.join(Hanami.app.root, "config/db/migrate"))
begin
  # Push around migrating on a synced replica; see YourApp::MigrationPush.
  YourApp::MigrationPush.new(gateway.connection.turso_database).around do
    # Migration files call ROM::SQL.migration, which needs a current gateway.
    ROM::SQL.with_gateway(gateway) { migrator.run }
  end
rescue YourApp::MigrationPush::Error => e
  abort "bin/migrate: #{e.message}"
ensure
  gateway.connection.close_replica
end
puts "migrated"
```

`lib/your_app/migration_push.rb`:

```ruby
# frozen_string_literal: true

module YourApp
  # Pushes a synced Turso replica before and after running migrations.
  #
  # Before: unpushed writes to a table that a migration rebuilds or drops can be
  # lost, so a failed push aborts the migration. After: the first push following
  # a table rebuild raises one SyncError by design, so it is retried once.
  # Local-only replicas (test) are left alone.
  #
  # Error output is the error class and the driver's message only (the driver
  # redacts the URL and token); never print the remote URL.
  class MigrationPush
    SKIP_ENV = "BEAGLE_TURSO_SKIP_MIGRATION_PUSH"

    class Error < StandardError; end

    def initialize(replica, env: ENV, out: $stderr)
      @replica = replica
      @env = env
      @out = out
    end

    def around
      return yield unless @replica.synced?

      if @env[SKIP_ENV] == "1"
        @out.puts "warning: #{SKIP_ENV}=1, not pushing before or after migrating"
        return yield
      end

      push_before
      result = yield
      push_after
      result
    end

    private

    def push_before
      @replica.push
    rescue Beagle::Turso::Error => e
      raise Error, "could not push pending writes before migrating (#{describe(e)}); " \
        "fix sync or set #{SKIP_ENV}=1"
    end

    def push_after
      @replica.push
    rescue Beagle::Turso::SyncError => e
      begin
        @replica.push
        @out.puts "warning: push after migrating failed once (#{describe(e)}); retry succeeded"
      rescue Beagle::Turso::Error => retry_error
        raise Error, "could not push after migrating (#{describe(retry_error)}); " \
          "the migration is applied locally only"
      end
    rescue Beagle::Turso::Error => e
      raise Error, "could not push after migrating (#{describe(e)}); the migration is applied locally only"
    end

    def describe(error) = "#{error.class}: #{error.message}"
  end
end
```

**Why push before and after.** The sync engine does not reliably carry a
schema change to the remote on the push that follows it. Without the pushes,
the migration is applied to the local replica only, and reaches the remote on
the app's next push, if it converges at all. `bin/migrate` closes the replica as
soon as it finishes, so nothing pushes it. Pushing after migrating makes the
remote catch up right away; it is retried once, because the first push after a
table rebuild raises one `SyncError` by design (see below). A second failure
raises an `Error` that says the migration is applied locally only. Pushing
before protects the data: unpushed writes to a table that a migration rebuilds
or drops can be lost, so a failed push aborts the migration.

Escape hatch: `BEAGLE_TURSO_SKIP_MIGRATION_PUSH=1` skips both pushes (with a
warning), for when the remote is unreachable and you accept the consequences.
The `activerecord-beagle-turso` migration tasks use the same variable.

### What a migration can and cannot do on a synced replica

All of this is in the
[`sequel-beagle-turso` README](../gems/sequel-beagle-turso#limitations); what
matters when you write a migration:

- **`rename_table` is refused** (`Sequel::Error`). The sync engine does not
  capture `ALTER TABLE ... RENAME TO`, so the remote would never see it, and later
  writes to the table would be lost on push. Create the new table, copy the
  rows and drop the old one.
- **Column changes rebuild the table without `RENAME`**: copy to a backup,
  drop, recreate, copy back, drop the backup. The data is copied twice, and
  **the first push after a rebuild raises one `SyncError`, then converges on
  the next push.** `MigrationPush` retries once for you; the app's `Syncer`
  logs it once and retries. The operations are `set_column_type`,
  `set_column_allow_null`, `set_column_default`, constraint changes, adding a
  unique column, and on a synced replica also `drop_column` and `rename_column`.
- **What a rebuild loses:** triggers on the table, partial indexes, a column's
  `COLLATE`, a foreign key's `DEFERRABLE`, and the `AUTOINCREMENT` counter
  (it restarts from the current max id, so a deleted top id can be reused).
  Re-create them in the same migration. A rebuild also fails, and rolls back
  cleanly, if another table's trigger references the rebuilt table.
- **Renaming a column that another table's foreign key references is
  refused.** Rebuild the referencing table as well, or apply the rename on
  the remote and pull. Dropping a foreign key column drops that foreign key.
- **Dropping a self-referencing table that has rows** works only outside a
  transaction (the adapter retries with foreign keys off); inside one it raises.
- **After an unexpected push error, don't pull.** Local writes that never
  reached the remote are the only copy, and a pull can discard them. Copy the
  replica file and all of its sidecar files somewhere safe first, then work out
  what failed.

## 6. The `turso_sync` provider

The `Syncer` is the background push/pull loop. `config/providers/turso_sync.rb`:

```ruby
# frozen_string_literal: true

# Keeps the Turso Cloud copy current while the app runs. Only for a synced
# replica (development/production with credentials); registers nothing for a
# local-only replica (test).
Hanami.app.register_provider :turso_sync, namespace: true do
  prepare do
    require "beagle/turso"
    require "logger"
  end

  start do
    replica = target["db.gateway"].connection.turso_database
    next unless replica.synced?

    interval = Integer(ENV.fetch("TURSO_SYNC_INTERVAL", "5"))
    syncer = Beagle::Turso::Syncer.new(
      replica,
      interval:,
      # Syncer requires max_backoff >= interval; keep its 300s default otherwise.
      max_backoff: [300, interval].max,
      logger: Logger.new($stderr, progname: "turso_sync")
    ).start
    register "syncer", syncer
  end

  stop do
    # Safe when start registered nothing; the db provider's before(:stop) may
    # have stopped it already, in which case it is no longer running.
    if target.registered?("turso_sync.syncer")
      syncer = target["turso_sync.syncer"]
      if syncer.status.running
        status = syncer.stop(timeout: 10)
        warn "turso_sync stopped: last_push_at=#{status.last_push_at.inspect} syncing=#{status.syncing}"
      end
    end
  end
end
```

- **`namespace: true`** makes the key `turso_sync.syncer`. Without it the
  `registered?("turso_sync.syncer")` guards never match, so on shutdown the
  final push is skipped and the syncer is left running.
- **`max_backoff: [300, interval].max`.** `Syncer` raises `ArgumentError` when
  `interval` is greater than `max_backoff` (default 300). Set
  `TURSO_SYNC_INTERVAL` above 300 without this and the app does not boot.
- **Under Falcon a boot error does not look like one.** The worker dies, the
  supervisor restarts it, and the only evidence is a restart loop and a log
  warning from Falcon. The site just never answers. If Falcon keeps
  restarting its worker, read the log for the warning, then reproduce the
  boot in the foreground with the server stopped, which prints the real
  exception:

  ```sh
  bundle exec ruby -e 'require "hanami/boot"; puts "booted"; Hanami.shutdown'
  ```

  Likely causes: a bad `TURSO_SYNC_INTERVAL`, a replica still locked by
  another process (`File is locked by another process`), the wrong-database
  check from [section 4](#4-the-db-provider), or a missing
  `TURSO_AUTH_TOKEN`.
- A syncer failure (network, auth) does not stop it: it is logged, backed off
  and retried. The site keeps serving from the local replica either way,
  which is why [monitoring](#10-monitoring-the-sync-not-the-site) matters.

## 7. Falcon

`bin/serve`:

```sh
#!/usr/bin/env bash
# One process owns the replica; Async's worker pool lets push/pull run off the reactor.
set -euo pipefail
cd "$(dirname "$0")/.."
export ASYNC_SCHEDULER_WORKER_POOL=true
# --graceful-stop: Falcon only waits 1 s by default for the worker to stop; the final push needs longer on a slow link.
exec bundle exec falcon serve --count 1 --graceful-stop "${GRACEFUL_STOP:-10}" --bind "http://localhost:${PORT:-2300}" "$@"
```

- **`--count 1`, always.** Each worker is a process; a second one cannot open
  the replica and dies with `File is locked by another process`.
- **`ASYNC_SCHEDULER_WORKER_POOL=true`** (in the server's environment) runs
  the driver's `push`, `pull`, `open` and `connect` on a worker thread, so a
  sync of tens of seconds does not freeze the reactor. Without it, every
  request waits out each sync. Queries and statements still run on the reactor
  (see [Measured responsiveness](#13-measured-responsiveness)).
- **`--graceful-stop 10`.** Falcon waits only 1 s by default for a worker to
  stop. The final push at shutdown needs longer on a slow link, and when the
  window passes the push is cut off and the last writes stay local.

### The shutdown hook

Nothing calls `Hanami.shutdown` under Falcon. Without a hook, the final push
and the replica close never run, and the writes since the last tick stay on
the box. `config.ru`:

```ruby
# frozen_string_literal: true

require "hanami/boot"

# Nothing calls Hanami.shutdown under Falcon; without this the final push and
# replica close never run.
at_exit { Hanami.shutdown }

run Hanami.app
```

Checked live, under Falcon, against a real Turso database: a write followed
at once by `SIGTERM` or `SIGINT` to the Falcon supervisor was pushed before
the process exited (a fresh replica showed the row). No extra signal trap or
Falcon hook was needed. Do not call `Syncer#stop` from a trap handler: it
takes locks and raises `ThreadError`.

## 8. A health endpoint

Report sync status separately from liveness. `/health` here is JSON, and the
liveness probe your load balancer uses should stay a trivial `/ping` that
touches no database: a probe that queries the replica would stall with it (see
below).

```ruby
# app/actions/health/show.rb
# frozen_string_literal: true

require "json"

module YourApp
  module Actions
    module Health
      class Show < YourApp::Action
        def handle(_request, response)
          db_ok = begin
            Hanami.app["db.gateway"].connection.get(Sequel.lit("1")) == 1
          rescue StandardError
            false
          end
          syncer = Hanami.app.registered?("turso_sync.syncer") ? Hanami.app["turso_sync.syncer"] : nil
          sync = syncer && syncer.status.to_h.transform_values { |v| v.is_a?(Time) ? v.iso8601 : v }
          response.format = :json
          response.body = JSON.generate(process: "ok", database: db_ok ? "ok" : "error", sync: sync)
        end
      end
    end
  end
end
```

```ruby
# app/actions/ping/show.rb (inside YourApp::Actions::Ping)
class Show < YourApp::Action
  def handle(_request, response)
    response.content_type = "text/plain; charset=utf-8"
    response.body = "pong"
  end
end
```

```ruby
# config/routes.rb
get "/ping", to: "ping.show"      # body "pong": liveness
get "/health", to: "health.show"  # process, database, and sync status
```

`sync` is `null` on a local-only replica. Otherwise it carries `running`,
`last_push_at`, `last_pull_at` and `consecutive_failures`, plus the last error
class and time (`last_error_message` included). Error messages are stripped of
URLs and tokens, but they still leak internals: don't make `/health` public.

## 9. Testing: DatabaseCleaner with `:truncation`

`spec/support/db/cleaning.rb` (Hanami's generated file, with these changes):

```ruby
# frozen_string_literal: true

require "database_cleaner/sequel"

RSpec.configure do |config|
  all_databases = -> {
    Hanami.app.with_slices.each_with_object([]) { |slice, dbs|
      next unless slice.key?("db.rom")

      dbs.concat slice["db.rom"].gateways.values.map(&:connection)
    }.uniq
  }

  # Never truncate the sync engine's own tables (emptying sqlite_sequence or
  # turso_cdc on a synced replica makes the engine spin). Only app tables.
  keep = %w[schema_migrations sqlite_sequence turso_cdc turso_cdc_version turso_sync_last_change_id]
  except_for = ->(db) {
    keep + db.tables.map(&:to_s).select { |t| t.start_with?("__turso_internal_", "turso_", "sqlite_") }
  }

  config.before :suite do
    all_databases.call.each do |db|
      DatabaseCleaner[:sequel, db: db].clean_with :truncation, except: except_for.call(db)
    end
  end

  config.prepend_before :each, :db do |example|
    # Truncation, not transaction: DatabaseCleaner's transaction strategy runs
    # the transaction in its own Fiber, and with Sequel's fiber_concurrency
    # (needed under Falcon) that fiber holds a second connection, so the
    # repo's writes would hit "database is locked".
    strategy = :truncation

    all_databases.call.each do |db|
      DatabaseCleaner[:sequel, db: db].strategy = strategy, {except: except_for.call(db)}
      DatabaseCleaner[:sequel, db: db].start
    end
  end

  config.after :each, :db do
    all_databases.call.each do |db|
      DatabaseCleaner[:sequel, db: db].clean
    end
  end
end
```

- **`:truncation`, not `:transaction`.** The transaction strategy opens its
  transaction in its own `Fiber`. With `fiber_concurrency` that fiber checks
  out a second connection, and the repo's writes then fail with
  `database is locked`.
- **Never truncate the engine's tables** (`turso_cdc`, `turso_cdc_version`,
  `turso_sync_last_change_id`, `__turso_internal_*`, `sqlite_sequence`).
  On a synced replica, `DELETE FROM sqlite_sequence WHERE name = 'turso_cdc'`
  loops forever in engine 0.8.3: 100% CPU holding the GVL, so only `SIGKILL`
  stops it. `sequel-beagle-turso` 0.1.0 already hides these tables from
  `tables`, but keep the explicit exclusion, because it is cheap and the
  failure is nasty. Tests run local-only (section 4), where this does not arise,
  but the same suite can be pointed at a synced replica by mistake.
- Run specs with `HANAMI_ENV=test`. An empty `HANAMI_ENV` boots development, with
  a synced replica, so `spec_helper.rb` defaults it and aborts otherwise:

  ```ruby
  ENV["HANAMI_ENV"] = "test" if ENV["HANAMI_ENV"].to_s.empty?
  abort "spec_helper: HANAMI_ENV must be \"test\" for specs (got #{ENV["HANAMI_ENV"].inspect})" unless ENV["HANAMI_ENV"] == "test"
  ```
- The test database is not migrated for you: run `HANAMI_ENV=test bin/migrate`
  once.

## 10. Monitoring the sync, not the site

The app serves from its local replica, so a broken or wrongly pointed sync is
invisible from outside: HTTP 200, no errors. Two failures to watch for:

- **Sync stops advancing.** Alert on `/health`: `sync.consecutive_failures`
  growing, or `sync.last_push_at` older than you can tolerate. Better, check
  the **remote**: query the Turso database for the row count or newest
  `created_at` of a table you write to constantly, and alarm when it stops
  moving. Do this from outside the app (a cron job with
  `turso db shell <db> "SELECT ..."`), because the app can only report what
  it believes.
- **Sync succeeding against the wrong database.** Nothing reports this. The
  boot check in [section 4](#4-the-db-provider) catches a pointer to another
  app's or environment's database; the remote-side check above catches the
  rest.

`last_push_at` says when a push last succeeded, not how much is still
unpushed. See the [driver README](../gems/beagle-turso#background-sync).

## 11. Primary keys: UUID v7

By default `primary_key :id` is an integer rowid, which is the simplest choice
and works with everything above. If you want UUID v7 keys (time-ordered, safe
to expose in URLs), there are two ways. Both were run in a scratch copy of the
proof-of-concept app: ROM relations with `infer: true`, a repo, `by_pk`, and a
request spec, on the local-only test replica with Ruby 4.0.7.

**Generate the id in Ruby** (Ruby 3.3+; recommended: the repo knows the id
without asking the database):

```ruby
# config/db/migrate/..._create_items.rb
ROM::SQL.migration do
  change do
    create_table :items do
      column :id, String, primary_key: true   # TEXT
      column :name, String, null: false
      column :created_at, Time, null: false
    end
  end
end
```

```ruby
# app/repos/item_repo.rb
require "securerandom"

module YourApp
  module Repos
    class ItemRepo < YourApp::DB::Repo
      commands :create

      def create_with_uuid(attrs)
        id = SecureRandom.uuid_v7
        items.command(:create).call(attrs.merge(id: id, created_at: Time.now))
        find(id)
      end

      def find(id) = items.by_pk(id).one!
    end
  end
end
```

**Let the database generate it.** The engine has `uuid7_str()` (text) and
`uuid7()` (a 16-byte blob), usable as a column `DEFAULT`:

```ruby
# a second table, `dflt_items`, same columns but with this id:
column :id, String, primary_key: true, default: Sequel.lit("(uuid7_str())")
```

```ruby
def create_db_default(attrs)
  row = dflt_items.dataset.returning(:id).insert(attrs.merge(created_at: Time.now)).first
  dflt_items.by_pk(row.fetch(:id)).one!
end
```

Results of the run:

- The repo-generated id was stored as `TEXT`, e.g. `01a14eb5-4c80-79df-...`,
  with the version nibble `7`; `by_pk` found it.
- `DEFAULT (uuid7_str())` filled the id, and `returning(:id)` handed it
  back as a `String`. `typeof(id)` was `text`.
- The ids round-tripped through a path param: `GET /items/<uuid>` returned the
  record (200), and an unknown valid-looking uuid raised
  `ROM::TupleCountMismatchError`, which the action turned into a 404.
- Earlier, against the engine through the driver: a `DEFAULT (uuid7())` value is
  generated locally at insert and synced as a concrete value.

Caveats:

- **Not monotonic within one millisecond.** Five ids generated in a tight loop
  did not sort in creation order; ids generated 2 ms apart did. If you need
  strict creation order, keep a `created_at` or an integer column and sort by
  that, not by the key.
- **`insert` returns the rowid, not your uuid.** A TEXT primary key table still
  has an implicit rowid, and Sequel/ROM's `insert` returns that (`1` in the run),
  not the key. Generate the id in the repo (`SecureRandom.uuid_v7`) or use
  `returning(:id)`, as above, and never use the return value of `insert` as the
  id.
- **TEXT or BLOB.** `uuid7_str()` is 36 bytes and safe to put in URLs, logs and
  `turso db shell`. `uuid7()` is 16 bytes and smaller on disk and in indexes,
  but is binary: you have to convert at the edges, and a hex dump is the only
  way to read it in the shell. This was not run through ROM here; choose TEXT
  unless the size matters.

## 12. Putting it together: the order that works

1. Create the Turso database with `--tursodb`; put the URL and token in
   `.env.local`.
2. `bin/migrate` with the server stopped. Look for `migrated`, and read the
   output for a "push after migrating failed once ... retry succeeded" warning
   (expected after a table rebuild).
3. `bin/serve`. Check `/health`: `sync.running` is `true` and
   `last_push_at` advances every interval.
4. Write a row, then check it on the remote (`turso db shell`).
5. Stop the server with `SIGTERM`; look for the `turso_sync stopped:` line.

## 13. Measured responsiveness

How much do bulk writes, a push and a long query disturb `GET /ping` under
Falcon (one worker, one reactor)? These are **single-machine measurements**,
not benchmarks of the setup in general; expect different numbers on other
hardware and networks.

- **Machine.** Intel Core Processor (Haswell, no TSX), 6 cores, 1 thread per
  core. The load generator ran on the same machine, so client and server
  competed for those cores. Ruby 4.0.7, hanami 3.0.2, falcon 0.57.0, async
  2.46.0, sequel 5.109.0, beagle-turso 0.3.0, sequel-beagle-turso 0.1.0,
  Turso engine 0.8.3. The remote was a Turso Cloud database over the public
  internet.
- **Method.** Four client threads hitting `/ping` in a loop (about 1,500
  requests/s in total), each phase run three times, compared with a quiet
  window of the same length just before. The syncer's own loop was set long
  enough to stay out of the way, so only explicit pushes ran.

| What | Result |
|---|---|
| Baseline `/ping` p99 | 5 to 10 ms (swings with the load generator's CPU use) |
| Push of about 5,000 rows (30 s, 19 s, 120 s, in run order) | `/ping` p99 6.4, 9.5, 20.0 ms vs 6.4, 8.9, 17.2 ms quiet; max 45 ms |
| Single-row write 1 s into an 18 to 67 s push | committed in 23 to 32 ms; `/ping` at baseline apart from one ~30 ms blip |
| Slow query (3,000,000-row recursive CTE) | `/ping` stalled for the whole query: 4.64, 4.95, 5.21 s |
| Bulk insert, 2,000 rows in one transaction (50 per statement) | 2.7 s stall in the one run that survived; the other two were killed (below) |

What this says:

- **A push does not block reads, or a concurrent write** (at least for an explicit push). The driver releases the
  GVL for `push` and `pull`, and with `ASYNC_SCHEDULER_WORKER_POOL=true`
  they run off the reactor. Push duration is dominated by the network and
  varies a lot (19 to 120 s for the same 5,000 rows; pushing the 5,000 deletes
  took 27 to 198 s).
- **Every statement holds the GVL on the reactor thread.** `execute` and
  `query` are not offloaded, so a long query or bulk insert stalls the *whole
  server* for its duration: 4.6 to 5.2 s for the slow query, 2.7 s for the
  2,000-row bulk insert. Health checks and other requests wait.
- **Insert cost on a synced replica grows faster than the row count.** In the
  same test: 250 rows took 0.08 s, 500 rows 0.4 s, 1,000 rows 1.9 s, 2,000
  rows 3 to 10 s; and the same insert got slower as the table or its history
  grew. A single 5,000-row transaction froze the reactor past Falcon's health
  check every time.
- **Occasional freezes of more than 30 s on the first statement after
  `BEGIN IMMEDIATE`**, mostly after a large delete-and-push cycle. Falcon's
  health check (30 s by default) killed the worker about eight times
  (`Health check failed!`, `SIGKILL`). They also happened several times with the
  background syncer at its 5 s and 290 s intervals, where a push or pull was in
  flight at the time of the write. They did not happen in the three
  write-during-push runs from an explicit push. The cause is **not isolated
  yet**: it needs engine-level tracing. Until then, with the default 5 s syncer
  interval, expect that a large write can freeze the process.
- **Looking ahead.** `beagle-turso` 0.4.0 is planned to run statements off the
  reactor, so a long statement stops freezing the server. Not released yet.

Practical advice:

- With the default 5 s syncer interval, expect that a large write can freeze the
  process; the advice below limits how often and for how long.
- Keep transactions small. Chunk big writes (a few hundred rows per
  transaction) so each stall is short, and do large backfills offline: against
  a copy of the database, or with the server stopped, then push.
- Keep slow reads off the web process, or off the synced replica.
- Falcon's health-check timeout is configurable: `falcon serve
  --health-check-timeout <seconds>` (default 30.0; flag present in Falcon
  0.57.0). Raising it in `bin/serve` makes a long stall survivable instead
  of fatal, but the server is still frozen for its duration, and it does not
  fix the cause. Treat it as a stopgap. (Checked in the flag list and the
  source; not tested against a stalled worker.)

## 14. Known engine issues

- **Self-referencing foreign keys** (for example `parent_id`): a multi-row
  `DELETE`, `UPDATE` or `DROP` that SQLite accepts can fail with
  `FOREIGN KEY constraint failed`, and `ON DELETE` actions can leave rows
  behind. Foreign keys between two different tables are unaffected. See the
  [driver README](../gems/beagle-turso#known-engine-issue-self-referencing-foreign-keys)
  and the
  [sequel README](../gems/sequel-beagle-turso#limitations).
- **Insert ids on synced replicas.** The engine's `last_insert_rowid` returns the
  change log's rowid, so code that calls it directly gets a wrong id.
  `sequel-beagle-turso` avoids it (`INSERT ... RETURNING rowid`), so ROM's
  `create` works as normal. See the
  [sequel README](../gems/sequel-beagle-turso#limitations).
- The `hanami db` commands, `rename_table`, and the rebuild limits are covered
  in [section 5](#5-migrations).
