# activerecord-beagle-turso

An ActiveRecord connection adapter for [Turso](https://turso.tech)'s libsql
engine, backed by the [`beagle-turso`](../beagle-turso) driver. It subclasses
Rails' stock `SQLite3Adapter` and reroutes only the raw-execution seam onto
`beagle-turso`, so SQL generation, quoting, schema introspection, and
transaction handling are all inherited unchanged — you get a normal
ActiveRecord experience, running against a local, in-memory, or
remote-synced Turso database.

## Install

Add both gems to your `Gemfile` (`activerecord-beagle-turso` depends on
`beagle-turso`, but Bundler needs it listed explicitly if you're installing
from a path/git source rather than RubyGems):

```ruby
gem "activerecord-beagle-turso"
gem "beagle-turso"
```

or install directly:

```sh
gem install activerecord-beagle-turso
```

`beagle-turso` has a native (Rust) extension, so installing it requires a
Rust toolchain unless a precompiled binary gem is available for your
platform — see [`beagle-turso`'s README](../beagle-turso/README.md#install)
for details. **There is currently no precompiled/cross-compiled gem release
job for either gem** — installing means building the extension locally
(or, as in this repo, from a path dependency built once already).

## `config/database.yml`

Set `adapter: beagle_turso`. A **local** connection (no sync) needs only
`database:`:

```yaml
development:
  adapter: beagle_turso
  database: storage/development.sqlite3
```

A **synced** connection additionally sets `remote_url:` and `auth_token:` —
both are required together to enable sync (see
[`Beagle::Turso::Database.open`](../beagle-turso/README.md#synced-example)):

```yaml
production:
  adapter: beagle_turso
  database: storage/production.sqlite3
  remote_url: <%= Rails.application.credentials.dig(:turso, :prod_url) %>
  auth_token: <%= Rails.application.credentials.dig(:turso, :prod_token) %>
  # Informational only (see "Recurring sync" below) -- not read by this
  # adapter or by SyncManager. Keep it in sync with recurring.yml by hand.
  sync_interval: 30 # seconds
```

Never log `remote_url`/`auth_token` — Rails masks `password`-ish keys in
some diagnostics, but these are custom `database.yml` keys, so that masking
does not cover them automatically. Source them from encrypted credentials or
`ENV`, as above, and avoid logging/inspecting the raw connection config.

An optional `bootstrap_if_empty:` (default `true`) controls whether a brand
new/empty local file is populated from the remote on first open — see
`Beagle::Turso::Database.open`.

### Durability note: writes commit on-sync, not synchronously

Writes go to the **local** file immediately, as part of the normal
ActiveRecord write path (`INSERT`/`UPDATE`/`DELETE` all commit locally,
synchronously, like any SQLite-backed adapter). They are only propagated to
the remote Turso database **on sync** — i.e. whenever something calls
`push!` (see below) — not automatically after every write or transaction
commit. Until a sync succeeds, a write that is fully durable on this
replica's local disk is not yet visible to any other replica of the same
remote database. Plan your sync cadence (and any read-after-write
expectations across replicas) around that gap.

## Sync: `Beagle::Turso::SyncManager` + Solid Queue recurring job

`Beagle::Turso::SyncManager` drives push/pull from the ActiveRecord layer,
given a connection using `adapter: beagle_turso`:

```ruby
Beagle::Turso::SyncManager.push!(ActiveRecord::Base.connection) # local writes -> remote
Beagle::Turso::SyncManager.pull!(ActiveRecord::Base.connection) # remote writes -> local
Beagle::Turso::SyncManager.sync!(ActiveRecord::Base.connection) # push!, then pull!
```

All three default their `connection` argument to `ActiveRecord::Base.connection`,
so `Beagle::Turso::SyncManager.sync!` alone is the usual call. Calling any of
them against a **local-only** connection (no `remote_url:`/`auth_token:` in
`database.yml`) raises `Beagle::Turso::SyncManager::NotSyncedError` — a
distinct, rescuable type — rather than the driver's bare `RuntimeError`.

To sync on a timer, wire
`ActiveRecord::ConnectionAdapters::BeagleTurso::SyncJob` (a thin delegator to
`SyncManager.sync!`) into [Solid Queue's recurring
jobs](https://github.com/rails/solid_queue?tab=readme-ov-file#recurring-tasks).
This gem does not generate or load `config/recurring.yml` itself — copy the
relevant block from
[`config/recurring.yml.example`](config/recurring.yml.example) into your
host app's own `config/recurring.yml`, for whichever environment(s) actually
use a synced connection:

```yaml
production:
  beagle_turso_sync:
    class: ActiveRecord::ConnectionAdapters::BeagleTurso::SyncJob
    queue: default
    schedule: every 30 seconds # match database.yml's sync_interval: for this env
```

`SyncJob` subclasses `ActiveJob::Base` when ActiveJob is loaded (the normal
case in a Rails app running Solid Queue) and falls back to a plain class
with the same `#perform` otherwise, so requiring this gem never raises a
`LoadError` on its own in a non-Rails context.

A recurring `SyncJob` against a local-only connection will fail every run
with `NotSyncedError` — only add the recurring entry for environments whose
`database.yml` connection actually carries `remote_url:`/`auth_token:`.

## Test coverage

This gem's own spec suite (`spec/`, run via `bundle exec rspec`) is 35
examples covering, against the real `beagle-turso` driver (nothing mocked):
CRUD through a model, foreign-key enforcement, data-modifying CTEs,
transactions (commit/rollback/nested `requires_new`), DDL
(`add_column`/`remove_column`/`change_column`/`add_index`), every AR column
type round-tripping through a model, `pluck`/`where`/`update_all`/`delete_all`,
and (with real Turso credentials — otherwise a clean `PENDING` skip, no
silent pass) a genuine push/pull sync round trip between two replicas.

### Real-Rails-boot integration test

`spec/dummy_app_integration_spec.rb` boots `test/dummy` — a small but
**genuine** `Rails::Application` (not a mock or a stand-in) — through Rails'
own `config/environment.rb` → `Rails.application.initialize!` sequence, the
same path a real app's `bin/rails server`/`bin/rails console`/`bin/rails db:migrate`
takes. It proves the adapter survives that boot rather than only the
hand-called `ActiveRecord::Base.establish_connection(adapter: "beagle_turso", ...)`
the rest of the suite uses:

- `adapter: beagle_turso` is resolved from a real `config/database.yml` by
  `ActiveRecord::Railtie`'s own `active_record.initialize_database`
  initializer, not passed as a literal hash.
- A real `ActiveRecord::Migration` file is run via `ActiveRecord::MigrationContext`
  (not `ActiveRecord::Schema.define`, which the rest of the suite uses) —
  this exercises `schema_migrations`/`ar_internal_metadata` bookkeeping,
  which no other spec in this gem touches.
- The model under test (`DummyWidget`) is never `require`d by hand — it's
  resolved through Rails' normal Zeitwerk `app/models` autoloading.

`test/dummy` intentionally boots only the frameworks
`ActiveRecord::Railtie` itself pulls in (it hard-requires
`action_controller/railtie`, and transitively `action_view/railtie`, for
long-standing middleware-configuration reasons — see the comment at the top
of Rails' `active_record/railtie.rb`) — no Active Job, Action Mailer, Active
Storage, Action Cable, etc. See `test/dummy/config/application.rb` for the
exact boot list.

### What's deferred: ActiveRecord's own internal adapter test suite

ActiveRecord ships an extensive internal adapter conformance suite
(`activerecord/test/cases/*_test.rb` in the [Rails source
tree](https://github.com/rails/rails/tree/v8.1.3.1/activerecord/test/cases))
that official adapters (`mysql2`, `pg`, `trilogy`) are exercised against.
**This gem does not vendor or run that suite, and that is a deliberate,
documented decision, not a silent gap:**

- That suite is not shipped in the released `activerecord` gem — only in
  the Rails monorepo's source tree. It is not designed for consumption by
  external adapter gems.
- We confirmed this concretely: even a single, relatively adapter-agnostic
  file from it (`test/cases/adapter_test.rb`) `require`s `cases/helper`,
  `support/connection_helper`, and several `models/*` fixture classes,
  which in turn depend on ActiveRecord's internal `ARTest` test harness and
  its ~1,500-line `test/schema/schema.rb` (dozens of interlocking fixture
  tables — authors, books, posts, comments, and more) plus a `test/config.yml`
  whose format/location has itself shifted between Rails versions. None of
  this is a stable, public interface; vendoring even one file means
  vendoring most of that infrastructure and keeping it hand-synced with
  whatever Rails version this gem targets.
- This is precisely why official third-party adapters handle it by
  checking out the **entire** Rails source at a pinned commit/tag (often as
  a CI-only step, sometimes a git submodule) and running AR's suite
  in-tree against their adapter — a substantial, ongoing-maintenance
  commitment, not something addable as a "focused subset" inside a single
  gem release.
- What that suite covers beyond this gem's own 35 examples: exhaustive
  per-type edge cases (encoding, precision/scale boundaries, reserved-word
  quoting across dozens of identifiers), schema-dumping round-trips
  (`db/schema.rb` load-and-compare), the full fixture-based association
  graph, and adapter-independent behavior that has nothing to do with the
  raw-execution seam this adapter actually changes. None of that is
  exercised here.

If this adapter needs that level of assurance in the future (e.g. before a
1.0 release, or before proposing it for inclusion upstream), the right next
step is a separately-scoped effort to vendor the full Rails source at a
pinned tag and run its adapter suite in CI — not a partial port bolted onto
this gem.

## Limitations (v1)

1. **Uncast raw/computed SELECT values.** Reads go through `ActiveRecord::Result`
   without result column types, so ordinary model attributes and `pluck(:column)`
   cast correctly, but a raw/computed SELECT expression with no backing attribute
   (e.g. `select_all("SELECT some_datetime_expr ...")`, `pluck(Arel.sql("..."))`)
   may come back uncast (string / 0/1 instead of Time / boolean). Cast such values
   yourself.

2. **Data-modifying CTEs and read-replica write-guards.** A hand-written
   `WITH ... UPDATE/INSERT/DELETE` executes correctly, but is classified as a read
   by ActiveRecord's write-guard layer — so under `connected_to(role: :reading)` it
   won't trip the read-only guard, and it won't mark the transaction dirty. Use
   plain `UPDATE`/`DELETE` (or `Model.update_all`/`delete_all`) if you rely on
   read/write splitting.

3. **Sync holds the GVL.** `SyncManager.push!`/`pull!` block Ruby's GVL for the
   full network round-trip. Under `SOLID_QUEUE_IN_PUMA=true` (jobs in the Puma
   process), a recurring `SyncJob` stalls all Puma threads for the duration of
   each sync — pick a sync cadence accordingly, or run Solid Queue in a separate
   process.

## License

[MIT](https://opensource.org/licenses/MIT).
