# Beagle Turso — Rails adapter for Turso's new engine (synced single-DB)

**Status:** Design (spike-validated) · **Date:** 2026-08-06 · **Home:** `BeagleSoftwareUK/beagle-turso`

## 1. Problem & motivation

libSQL (Turso's SQLite fork) is now in maintenance — Turso has pivoted to its
ground-up Rust rewrite, **Turso Database** (crate `turso`, formerly Limbo). The
existing Rails path (`libsql_activerecord` → `turso_libsql`) sits on that frozen
base and carries real defects we hit directly: a credential leak (the bundled
`liblibsql.so` prints the auth token to stderr) and remote/Hrana bugs requiring a
fork. Upstream fixes are unlikely.

Meanwhile the new engine has **no Ruby binding at all** (its bindings are Rust,
JS/WASM, Python, Go, Java, .NET). That's the opening: be early for Rails on the
engine Turso is actually investing in — the way `turso_ex` is early for Elixir.

## 2. Goals / Non-goals

**Goals (v1):**
- A clean, maintained ActiveRecord adapter for the **new** Turso engine.
- Hero use case **(A) synced single-DB**: local-first reads *and* writes at
  SQLite speed, synced to Turso Cloud for durability.
- No credential leakage — ever (an explicit, tested invariant).
- A Rust core factored so a future Elixir/Ecto wrapper reuses it unchanged.

**Non-goals (v1) — YAGNI:**
- Multi-tenant (database-per-tenant) connection management.
- Elixir/Ecto wrapper (design for it; build nothing).
- Branching, edge-specific tooling, custom conflict resolution beyond the engine's.

## 3. Hero use case (A)

A local SQLite-compatible DB driven by the Turso engine: reads and writes hit the
local file in microseconds; a background job `push()`es local changes to Turso
Cloud and `pull()`s remote changes. **Durability is on-sync** — a write is durable
in the cloud after the next `push()`, not synchronously at commit. Ideal for the
small Rails apps this targets; explicitly *not* for "must be in the cloud before I
ack" workloads.

## 4. Architecture

Three layers plus a future-language seam. Each layer has one job and a clean
interface to the next.

```
beagle_turso_core (Rust crate)
  Thin wrapper over `turso` 0.7.x (sync feature). Owns the tokio runtime and the
  async→sync bridge. Surface: open(local_path, remote_url, token, opts) ·
  connection · execute · query→rows · transactions · push() · pull() ·
  bootstrap / sync-status.
        │  Magnus / rb-sys   (native extension)
        ▼
beagle-turso (Ruby gem, native ext)
  Low-level driver: Beagle::Turso::Database / Connection / Statement · Rows,
  plus #push / #pull / #sync. Shipped as PRECOMPILED gems via rb-sys-dock
  (arm64/x86_64 linux, arm64 darwin). Being ours, it has no dbg! leak.
        │  raw_connection
        ▼
activerecord-beagle-turso (pure Ruby gem)
  ActiveRecord::ConnectionAdapters::BeagleTursoAdapter < SQLite3Adapter.
  Reuses SQLite type map / quoting / schema statements; overrides only connection
  creation to use the Beagle::Turso driver. Registers `adapter: beagle_turso`.
  Ships a SyncManager and a generator for a Solid Queue recurring push/pull job.

Future (NOT built in v1): an Elixir Rustler NIF over the SAME beagle_turso_core
crate — the "build once, wrap twice" payoff.
```

**Why subclass `SQLite3Adapter`:** the new engine is SQLite-compatible, so the
type map, quoting, and schema logic already fit. Subclassing means we write the
*least* adapter code and inherit Rails' battle-tested SQLite behavior; we override
only where Turso differs (connection creation, sync).

## 5. Naming

| Piece | Name |
|---|---|
| GitHub monorepo | `BeagleSoftwareUK/beagle-turso` |
| Rust crate | `beagle_turso_core` |
| Ruby driver gem | `beagle-turso` (`Beagle::Turso`) |
| ActiveRecord adapter gem | `activerecord-beagle-turso` (`adapter: beagle_turso`) |

Monorepo layout (target): `crates/beagle_turso_core/`, `gems/beagle-turso/`,
`gems/activerecord-beagle-turso/`, `docs/`, `spikes/` (the validated spike code).

## 6. Configuration

```yaml
# config/database.yml
production:
  adapter: beagle_turso
  database: storage/local.sqlite3          # local replica file
  remote_url: <%= Rails.application.credentials.dig(:turso, :url) %>
  auth_token: <%= Rails.application.credentials.dig(:turso, :token) %>
  sync_interval: 10                        # seconds; drives the recurring job
```

Credentials resolve from Rails encrypted credentials with ENV fallback (never
committed, never logged).

## 7. Data flow & sync

- **Boot:** adapter opens the local DB via the driver; `bootstrap_if_empty` pulls
  the full DB from cloud on first run (validated in Spike 1).
- **Queries:** AR → inherited `SQLite3Adapter` machinery → our `raw_connection`
  → `beagle_turso_core` → local engine.
- **Sync:** `SyncManager#push` / `#pull` invoked by a **Solid Queue recurring
  job** at `sync_interval`; plus a manual `Beagle::Turso.sync!`. Writes are
  local-first; `push` ships them to cloud.
- **Bootstrap semantics:** a fresh replica opened against a populated remote
  bootstraps on open, so an immediate `pull()` may report "no changes" — expected.

## 8. Error handling

- `beagle_turso_core` maps engine errors into a `Beagle::Turso::Error` hierarchy;
  the adapter maps those to `ActiveRecord::StatementInvalid` and friends.
- Sync/network failures **never break local queries** — the local DB keeps
  serving; failures are logged and retried by Solid Queue.
- **Invariant (tested):** credentials never appear in logs, exceptions, or
  Debug/inspect output. A regression test asserts the token is absent from all
  emitted streams — the whole reason this project exists.

## 9. Testing

- **Rust:** `beagle_turso_core` unit tests + a Spike-1-style round-trip
  integration test against a scratch Turso Cloud DB.
- **Ruby driver:** RSpec specs over the native ext (open/exec/query/tx/sync).
- **Adapter:** run against ActiveRecord's shared adapter test suite (subclassing
  buys most of it) + a dummy Rails app exercising migrate / CRUD / sync.
- **CI:** rb-sys-dock cross-compile matrix producing precompiled gems.

## 10. Packaging & CI

Precompiled native gems for `beagle-turso` via `rb-sys-dock` /
`rake-compiler-dock` across arm64/x86_64 linux + arm64 darwin, pinned to a tested
`turso` crate version. `activerecord-beagle-turso` is pure Ruby depending on
`beagle-turso`. License: **MIT**.

## 11. Spike evidence (proven, not assumed)

Validated on this machine (2026-08-06):

- **Spike 1 — engine sync round-trips.** `turso` 0.7.2: replica A wrote locally →
  `push()` → fresh replica B bootstrapped from cloud and read back A's exact
  per-run marker. Confirms hero (A) and that writes must go through the engine
  (killing the "stock sqlite3 for local" approach).
- **Spike 2a — toolchain on Ruby 4.0.6.** rb-sys 0.9.128 + Magnus 0.8.2 build and
  load a native ext on bleeding-edge Ruby 4.0.6.
- **Spike 2b — engine via Magnus.** Ruby called into Rust (Magnus) which drove the
  `turso` engine and returned a queried row to Ruby.

Toolchain present: Rust 1.95, clang 19, Ruby 4.0.6, turso CLI v1.0.31 (authed).

## 12. Risks & mitigations

| Risk | Mitigation |
|---|---|
| `turso` 0.7.x is pre-1.0 / beta | Pin the crate version; track breaking changes; CI round-trip test. |
| `SQLite3Adapter` internals shift across Rails versions | Rails version test matrix; pin; thin override surface. |
| On-sync (not synchronous) durability surprises users | Document prominently; not for ack-before-durable workloads. |
| Proposed Zig rewrite of the engine (upstream churn) | We wrap a published crate API, not internals; re-evaluate at 1.0. |
| Spike 3 (`SQLite3Adapter` subclass) not yet run | Low risk / well-trodden; validate first in implementation. |

## 13. Open questions

- Exact `turso` crate version to pin for v1.
- Whether `adapter:` key should be `beagle_turso` (branded, chosen) vs `turso`
  (cleaner but risks colliding with a future official adapter).
- Minimum supported Rails version for the subclass.

## 14. Out of scope / future

Multi-tenant (DB-per-tenant) · Elixir/Ecto wrapper over the same core · branching
· edge deployment tooling · advanced conflict resolution. Each is a later
spec → plan → build cycle on top of this foundation.
