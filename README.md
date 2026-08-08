# beagle-turso

**Rails and Ruby on [Turso](https://turso.tech)'s new engine — a local-first SQLite replica that syncs to the cloud.**

[![gem](https://img.shields.io/gem/v/beagle-turso?label=beagle-turso)](https://rubygems.org/gems/beagle-turso)
[![gem](https://img.shields.io/gem/v/activerecord-beagle-turso?label=activerecord-beagle-turso)](https://rubygems.org/gems/activerecord-beagle-turso)
[![crates.io](https://img.shields.io/crates/v/beagle_turso_core?label=beagle_turso_core)](https://crates.io/crates/beagle_turso_core)
[![CI](https://github.com/BeagleSoftwareUK/beagle-turso/actions/workflows/ci.yml/badge.svg)](https://github.com/BeagleSoftwareUK/beagle-turso/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Your app reads and writes a **local SQLite file** — fast, and it keeps working
even when the network doesn't — while a background sync **pushes** those writes
to a remote [Turso](https://turso.tech) database for off-box durability and
**pulls** changes back down. It's built on Turso's newer Rust engine (the
`turso` crate), wrapped for Ruby via a native extension and surfaced to Rails
as an ActiveRecord adapter.

The gems ship **precompiled** — no Rust toolchain needed to install.

## Why?

Turso is moving off libSQL onto a **new engine written in Rust** (the `turso`
crate). The existing Ruby/Rails libSQL adapters sit on that older,
now-maintenance path — and the native driver they depend on shipped an unfixed
bug that leaked the database **auth token to stderr** (and so into container
logs). So there was no clean, safe, maintained way to run Rails on Turso's
*current* engine. That's the gap this fills.

And the local-first model it's built on is genuinely nice to run:

- **Fast** — reads and writes hit a local SQLite file (microseconds), not a
  network round-trip per query.
- **Resilient** — the app keeps serving even when Turso Cloud is unreachable;
  writes commit locally and sync when it's back.
- **Durable** — `push`/`pull` propagate to Turso Cloud for off-box backup and
  other replicas.
- **Boringly simple ops** — one SQLite file plus a cloud copy; no separate
  database server to run, scale, or patch.
- **A real Rails experience** — it subclasses the stock `SQLite3Adapter`, so
  migrations, models, transactions, and schema introspection just work.
- **On the current engine, safely** — Turso's new Rust core, with the
  credential leak gone, shipped as precompiled gems (no toolchain at install or
  deploy).

A good fit for small-to-mid Rails apps, edge/regional deployments, and anything
that wants local read latency with cloud durability behind it.

## Packages

This is a monorepo with one shared Rust core wrapped by two Ruby gems:

| Package | Registry | What it is |
| --- | --- | --- |
| [`beagle_turso_core`](crates/beagle_turso_core) | [crates.io](https://crates.io/crates/beagle_turso_core) | The Rust sync core — a synchronous façade over the `turso` engine. |
| [`beagle-turso`](gems/beagle-turso) | [RubyGems](https://rubygems.org/gems/beagle-turso) | The Ruby driver (native extension over the core): open a local or synced database, run SQL, `push`/`pull`. |
| [`activerecord-beagle-turso`](gems/activerecord-beagle-turso) | [RubyGems](https://rubygems.org/gems/activerecord-beagle-turso) | The ActiveRecord adapter — `adapter: beagle_turso` in `database.yml`. |

## Quick start (Rails)

```ruby
# Gemfile
gem "activerecord-beagle-turso", "~> 0.1"
gem "beagle-turso", "~> 0.1", require: false   # the adapter requires it
```

```yaml
# config/database.yml

# Local-only (dev/test): a plain on-disk replica, no cloud.
development:
  adapter: beagle_turso
  database: storage/development.sqlite3

# Synced: a local replica kept in sync with a remote Turso database.
production:
  adapter: beagle_turso
  database: storage/production.sqlite3
  remote_url: <%= Rails.application.credentials.dig(:turso, :url) %>   # libsql://…
  auth_token: <%= Rails.application.credentials.dig(:turso, :token) %>
```

Migrations and models work as usual — the adapter subclasses Rails' stock
`SQLite3Adapter` and only reroutes raw execution onto the Turso driver, so SQL
generation, quoting, schema introspection, and transactions are all inherited.

**Syncing.** Writes commit to the local file immediately; they reach the cloud
on `push`. Drive it from Rails with `Beagle::Turso::SyncManager` and a Solid
Queue recurring job — see the
[adapter README](gems/activerecord-beagle-turso#readme).

## Quick start (plain Ruby)

```ruby
require "beagle/turso"

db   = Beagle::Turso::Database.open(
  local_path: "app.db",
  remote_url: "libsql://your-db.turso.io",   # omit remote_url/auth_token for local-only
  auth_token: ENV["TURSO_AUTH_TOKEN"],
)
conn = db.connect
conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", [])
conn.execute("INSERT INTO users (name) VALUES (?)", ["Ada"])

db.push                       # propagate local writes to the remote
conn.query("SELECT name FROM users", [])  # => [["Ada"]]
db.close                      # release the replica + its sync session
```

## Good to know

A synced database wants a **dedicated Turso database** (a fresh one is safest),
and the local replica is held by **one OS process at a time** (an exclusive
lock). That shapes a few things — job workers run in-process, no zero-downtime
container swaps on a single replica, don't co-host the same DB with the legacy
libSQL driver. The [`beagle-turso` README](gems/beagle-turso#readme) covers the
durability model and the "which database?" guidance in full.

## Repository layout

```
crates/beagle_turso_core/          # the Rust sync core (published to crates.io)
gems/beagle-turso/                 # the native-extension driver gem
gems/activerecord-beagle-turso/    # the ActiveRecord adapter gem
docs/superpowers/                  # design specs, plans, and the release runbook
```

Releases are cut by tagging `vX.Y.Z`; CI cross-compiles the precompiled gems and
publishes all three packages via trusted publishing (OIDC, no stored tokens).

## Status

Young (`0.1.x`) — the API may still move before `1.0`. Built on the `turso`
engine, which is itself pre-1.0. Issues and PRs welcome.
Beagle Software Limited 
## License

[MIT](LICENSE).
