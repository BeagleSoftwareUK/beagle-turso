# beagle-turso (Ruby/Magnus gem) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `beagle-turso`, a Ruby gem with a native Magnus/rb-sys extension that wraps `beagle_turso_core`, exposing `Beagle::Turso::Database`/`Connection` with `open`, `connect`, `execute`, `query`, `push`, `pull` — the low-level driver the ActiveRecord adapter (Plan 3) sits on.

**Architecture:** A native extension (`ext/beagle_turso`, crate type `cdylib`) uses Magnus to wrap the `beagle_turso_core` crate's `Database`/`Connection` as persistent Ruby objects (proven `Send`-safe — no actor thread needed). Ruby values cross the boundary as a plain array of bind params (`nil`/Integer/Float/String) and rows come back as arrays. Shipped as precompiled gems via rb-sys-dock.

**Tech Stack:** Ruby 4.0.6, Magnus 0.8, rb-sys 0.9.x, rake-compiler, RSpec, `beagle_turso_core` (path dep).

## Global Constraints

- Magnus wrapped types use `#[magnus::wrap(class = "...", free_immediately)]`. Direct wrapping of `beagle_turso_core::Database` and `Connection` is PROVEN to compile and work (spikes/magnus-wrap) — do NOT introduce an actor/thread indirection.
- Use the NON-deprecated Magnus APIs: `ruby.exception_runtime_error()` / `ruby.exception_type_error()` (NOT `magnus::exception::*`); `ruby.str_from_slice(&[u8])` (NOT `RString::from_slice`).
- Param decoding reads the Ruby array via `unsafe { arr.as_slice() }` (safe: no Ruby code runs during the loop). Type order: `nil` → `i64` → `f64` → `String`; anything else is a `TypeError`.
- Public Ruby API: `Beagle::Turso::Database.open(local_path:, remote_url: nil, auth_token: nil, bootstrap_if_empty: true)` and `.open_local(path)`; `Database#connect` → `Connection`; `Database#push` / `#pull`; `Connection#execute(sql, params = []) -> Integer` (affected rows); `Connection#query(sql, params = []) -> Array<Array>`.
- **No credential logging.** The auth token must never appear in `inspect`/`to_s`/exception output of any Ruby object. A spec enforces it.
- `beagle_turso_core` and `turso` stay pinned (`turso = "=0.7.2"`); the ext depends on the core by path.
- Every task ends green (`bundle exec rake compile && bundle exec rspec`) and with a commit.
- **External-API note:** where a step says "confirm", check the real Magnus 0.8 / rb-sys signature (docs.rs/magnus, and the working reference in `spikes/magnus-wrap/src/lib.rs`) before implementing; keep the crate's own public method names as specified.

---

## File Structure (all under `gems/beagle-turso/`)

- `beagle-turso.gemspec` — gem metadata; declares the extension.
- `Gemfile` — dev deps (rake-compiler, rb_sys, rspec).
- `Rakefile` — `RbSys::ExtensionTask` compile task.
- `lib/beagle/turso.rb` — requires the compiled ext + Ruby-side sugar (`Database.open` keyword wrapper).
- `lib/beagle/turso/version.rb` — `Beagle::Turso::VERSION`.
- `ext/beagle_turso/Cargo.toml` — crate `beagle_turso` (`cdylib`), dep on `beagle_turso_core` by path + `magnus`.
- `ext/beagle_turso/extconf.rb` — `rb_sys/mkmf` `create_rust_makefile("beagle_turso/beagle_turso")`.
- `ext/beagle_turso/src/lib.rs` — the Magnus wrapping.
- `spec/spec_helper.rb`, `spec/*_spec.rb` — RSpec.

The ext crate is added to the root workspace `members` so it shares the build cache. Its path dep to the core is verified in Task 1.

---

## Task 1: Gem + native-ext skeleton and build pipeline

**Files:** create all skeleton files above (minimal), add ext to root `Cargo.toml` members.

**Interfaces:**
- Produces: a loadable gem where `require "beagle/turso"` succeeds and `Beagle::Turso::VERSION` is a String; the native ext compiles and defines the `Beagle::Turso` module.

- [ ] **Step 1: Write the failing spec** (`spec/version_spec.rb`)

```ruby
require "beagle/turso"

RSpec.describe Beagle::Turso do
  it "has a version" do
    expect(Beagle::Turso::VERSION).to be_a(String)
  end

  it "loaded the native extension" do
    expect(defined?(Beagle::Turso::Database)).to eq("constant")
  end
end
```

- [ ] **Step 2: Create the skeleton**

`gems/beagle-turso/lib/beagle/turso/version.rb`:
```ruby
module Beagle
  module Turso
    VERSION = "0.1.0"
  end
end
```

`gems/beagle-turso/lib/beagle/turso.rb`:
```ruby
require_relative "turso/version"
require "beagle_turso/beagle_turso" # native extension

module Beagle
  module Turso
  end
end
```

`gems/beagle-turso/ext/beagle_turso/Cargo.toml` (confirm the relative path to the core — from `ext/beagle_turso/` it is four levels up to the repo root):
```toml
[package]
name = "beagle_turso"
version = "0.1.0"
edition = "2021"
publish = false

[lib]
crate-type = ["cdylib"]

[dependencies]
magnus = "0.8"
beagle_turso_core = { path = "../../../../crates/beagle_turso_core" }
```

`gems/beagle-turso/ext/beagle_turso/extconf.rb`:
```ruby
require "mkmf"
require "rb_sys/mkmf"

create_rust_makefile("beagle_turso/beagle_turso")
```

`gems/beagle-turso/ext/beagle_turso/src/lib.rs` (minimal — defines the module + a placeholder Database class so the spec's `defined?` passes; real methods land in Task 2):
```rust
use magnus::{Error, Ruby};

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let turso = ruby.define_module("Beagle")?.define_module("Turso")?;
    turso.define_class("Database", ruby.class_object())?;
    Ok(())
}
```

`gems/beagle-turso/beagle-turso.gemspec`:
```ruby
require_relative "lib/beagle/turso/version"

Gem::Specification.new do |spec|
  spec.name = "beagle-turso"
  spec.version = Beagle::Turso::VERSION
  spec.authors = ["BeagleSoftwareUK"]
  spec.summary = "Ruby driver for Turso's new engine, backed by beagle_turso_core (Rust)."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["lib/**/*.rb", "ext/**/*.{rb,rs,toml}", "README.md"]
  spec.extensions = ["ext/beagle_turso/extconf.rb"]
  spec.add_dependency "rb_sys", "~> 0.9"
end
```

`gems/beagle-turso/Gemfile`:
```ruby
source "https://rubygems.org"
gemspec
gem "rake-compiler"
gem "rspec"
```

`gems/beagle-turso/Rakefile`:
```ruby
require "rake/extensiontask"
require "rb_sys/extensiontask"

RbSys::ExtensionTask.new("beagle_turso") do |ext|
  ext.lib_dir = "lib/beagle_turso"
end

task default: :compile
```

`gems/beagle-turso/spec/spec_helper.rb`:
```ruby
require "beagle/turso"
```

Add the ext to the root workspace — `Cargo.toml` `members`:
```toml
members = ["crates/beagle_turso_core", "gems/beagle-turso/ext/beagle_turso"]
```

- [ ] **Step 3: Install + compile + run**

```bash
cd gems/beagle-turso
bundle install
bundle exec rake compile     # confirm: builds ext/beagle_turso -> lib/beagle_turso/beagle_turso.so
bundle exec rspec spec/version_spec.rb
```
Expected: compile succeeds, 2 examples pass. If the core path dep is wrong, fix the `../../../../` depth until `cargo` resolves it.

- [ ] **Step 4: Commit**

```bash
git add gems/beagle-turso Cargo.toml
git commit -m "feat(gem): beagle-turso skeleton + rb-sys native ext pipeline"
```

---

## Task 2: Wrap Database + Connection (open_local / connect / execute / query)

**Files:** rewrite `ext/beagle_turso/src/lib.rs`; add `spec/roundtrip_spec.rb`.

**Interfaces:**
- Produces (Ruby): `Beagle::Turso::Database.open_local(path) -> Database`; `Database#connect -> Connection`; `Connection#execute(sql, params_array) -> Integer`; `Connection#query(sql, params_array) -> Array<Array>`.

This is proven code — it compiled and passed in `spikes/magnus-wrap/src/lib.rs`. Use it directly.

- [ ] **Step 1: Write the failing spec** (`spec/roundtrip_spec.rb`)

```ruby
require "beagle/turso"

RSpec.describe "local round-trip" do
  it "creates, inserts, and queries via persistent objects" do
    db = Beagle::Turso::Database.open_local(":memory:")
    conn = db.connect
    conn.execute("CREATE TABLE t (id INTEGER, name TEXT)", [])
    affected = conn.execute("INSERT INTO t (id, name) VALUES (?, ?)", [1, "alice"])
    expect(affected).to eq(1)
    rows = conn.query("SELECT id, name FROM t", [])
    expect(rows).to eq([[1, "alice"]])
  end
end
```

- [ ] **Step 2: Run it — fails** (`open_local`/methods not defined). `bundle exec rspec spec/roundtrip_spec.rb`.

- [ ] **Step 3: Implement the wrapping** (`ext/beagle_turso/src/lib.rs`)

```rust
use beagle_turso_core::{Connection, Database, OpenOptions, Value};
use magnus::{function, method, prelude::*, Error, IntoValue, RArray, Ruby};

#[magnus::wrap(class = "Beagle::Turso::Database", free_immediately)]
struct RbDatabase {
    inner: Database,
}

#[magnus::wrap(class = "Beagle::Turso::Connection", free_immediately)]
struct RbConnection {
    inner: Connection,
}

fn rt_err(ruby: &Ruby, msg: String) -> Error {
    Error::new(ruby.exception_runtime_error(), msg)
}

fn ruby_array_to_params(ruby: &Ruby, arr: RArray) -> Result<Vec<Value>, Error> {
    // Safe: no Ruby code (which could GC/mutate the array) runs during this loop.
    let items = unsafe { arr.as_slice() };
    let mut out = Vec::with_capacity(items.len());
    for &item in items {
        let v = if item.is_nil() {
            Value::Null
        } else if let Ok(i) = i64::try_convert(item) {
            Value::Integer(i)
        } else if let Ok(f) = f64::try_convert(item) {
            Value::Real(f)
        } else if let Ok(s) = String::try_convert(item) {
            Value::Text(s)
        } else {
            return Err(Error::new(ruby.exception_type_error(), "unsupported bind parameter type"));
        };
        out.push(v);
    }
    Ok(out)
}

fn value_to_ruby(ruby: &Ruby, v: &Value) -> magnus::Value {
    match v {
        Value::Null => ruby.qnil().as_value(),
        Value::Integer(i) => (*i).into_value_with(ruby),
        Value::Real(f) => (*f).into_value_with(ruby),
        Value::Text(s) => s.clone().into_value_with(ruby),
        Value::Blob(b) => ruby.str_from_slice(b).as_value(),
    }
}

impl RbDatabase {
    fn open_local(path: String) -> Result<RbDatabase, Error> {
        let ruby = Ruby::get().map_err(|_| Error::new(magnus::exception::standard_error(), "no ruby"))?;
        let opts = OpenOptions { local_path: path, remote_url: None, auth_token: None, bootstrap_if_empty: true };
        let db = Database::open(opts).map_err(|e| rt_err(&ruby, e.to_string()))?;
        Ok(RbDatabase { inner: db })
    }

    fn connect(&self) -> Result<RbConnection, Error> {
        let ruby = Ruby::get().map_err(|_| Error::new(magnus::exception::standard_error(), "no ruby"))?;
        let c = self.inner.connect().map_err(|e| rt_err(&ruby, e.to_string()))?;
        Ok(RbConnection { inner: c })
    }
}

impl RbConnection {
    fn execute(&self, sql: String, params: RArray) -> Result<u64, Error> {
        let ruby = Ruby::get().map_err(|_| Error::new(magnus::exception::standard_error(), "no ruby"))?;
        let p = ruby_array_to_params(&ruby, params)?;
        self.inner.execute(&sql, &p).map_err(|e| rt_err(&ruby, e.to_string()))
    }

    fn query(&self, sql: String, params: RArray) -> Result<RArray, Error> {
        let ruby = Ruby::get().map_err(|_| Error::new(magnus::exception::standard_error(), "no ruby"))?;
        let p = ruby_array_to_params(&ruby, params)?;
        let rows = self.inner.query(&sql, &p).map_err(|e| rt_err(&ruby, e.to_string()))?;
        let out = ruby.ary_new();
        for row in rows {
            let rb_row = ruby.ary_new();
            for val in &row.values {
                rb_row.push(value_to_ruby(&ruby, val))?;
            }
            out.push(rb_row)?;
        }
        Ok(out)
    }
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let turso = ruby.define_module("Beagle")?.define_module("Turso")?;
    let db = turso.define_class("Database", ruby.class_object())?;
    db.define_singleton_method("open_local", function!(RbDatabase::open_local, 1))?;
    db.define_method("connect", method!(RbDatabase::connect, 0))?;
    let conn = turso.define_class("Connection", ruby.class_object())?;
    conn.define_method("execute", method!(RbConnection::execute, 2))?;
    conn.define_method("query", method!(RbConnection::query, 2))?;
    Ok(())
}
```
Confirm `magnus::exception::standard_error()` exists (or use `ruby.exception_standard_error()`); it is only the "Ruby unavailable" fallback, which cannot occur when called from Ruby.

- [ ] **Step 4: Compile + run** — `bundle exec rake compile && bundle exec rspec spec/roundtrip_spec.rb` → PASS.

- [ ] **Step 5: Commit**
```bash
git add gems/beagle-turso/ext/beagle_turso/src/lib.rs gems/beagle-turso/spec/roundtrip_spec.rb
git commit -m "feat(gem): wrap Database/Connection with execute/query round-trip"
```

---

## Task 3: Value-kind coverage (nil / Integer / Float / String / Blob)

**Files:** `spec/values_spec.rb`.

- [ ] **Step 1: Write the failing spec**

```ruby
require "beagle/turso"

RSpec.describe "value kinds" do
  it "round-trips every kind" do
    db = Beagle::Turso::Database.open_local(":memory:")
    conn = db.connect
    conn.execute("CREATE TABLE k (i INTEGER, r REAL, t TEXT, b BLOB, n TEXT)", [])
    conn.execute("INSERT INTO k VALUES (?, ?, ?, ?, ?)", [42, 3.5, "hi", "\x01\x02\x03".b, nil])
    row = conn.query("SELECT i, r, t, b, n FROM k", []).first
    expect(row[0]).to eq(42)
    expect(row[1]).to eq(3.5)
    expect(row[2]).to eq("hi")
    expect(row[3]).to eq("\x01\x02\x03".b)
    expect(row[4]).to be_nil
  end
end
```

- [ ] **Step 2: Run it.** `bundle exec rspec spec/values_spec.rb`. It should PASS on the Task 2 code (all kinds already handled). If `Blob` (binary String) fails to bind, note that the param decoder maps any `String` to `Value::Text`; add binary-encoding detection: if `item`'s encoding is `ASCII-8BIT`, decode to `Value::Blob(bytes)` instead of `Text`. Confirm the Magnus API for reading a Ruby String's bytes + encoding, implement, re-run.

- [ ] **Step 3: Commit**
```bash
git add gems/beagle-turso/spec/values_spec.rb gems/beagle-turso/ext/beagle_turso/src/lib.rs
git commit -m "test(gem): all Value kinds round-trip; blob binds as BLOB"
```

---

## Task 4: Synced mode — `open` with remote + `push`/`pull` (env-gated)

**Files:** `ext/beagle_turso/src/lib.rs` (add `open`, `push`, `pull`); `lib/beagle/turso.rb` (keyword `Database.open`); `spec/sync_spec.rb`.

**Interfaces:**
- Produces (Ruby): `Beagle::Turso::Database.open(local_path:, remote_url: nil, auth_token: nil, bootstrap_if_empty: true)`; `Database#push -> nil`; `Database#pull -> Boolean`.

- [ ] **Step 1: Write the failing spec** (`spec/sync_spec.rb`)

```ruby
require "beagle/turso"

RSpec.describe "synced mode" do
  it "pushes a local write and a fresh replica pulls it" do
    url = ENV["TURSO_DATABASE_URL"]
    token = ENV["TURSO_AUTH_TOKEN"]
    skip "no TURSO creds" if url.nil? || url.empty? || token.nil? || token.empty?

    marker = "gem-#{Process.pid}-#{rand(1_000_000)}"
    a = "/tmp/bt_a_#{marker}.db"
    b = "/tmp/bt_b_#{marker}.db"

    da = Beagle::Turso::Database.open(local_path: a, remote_url: url, auth_token: token)
    ca = da.connect
    ca.execute("CREATE TABLE IF NOT EXISTS m (name TEXT)", [])
    ca.execute("INSERT INTO m (name) VALUES (?)", [marker])
    da.push

    db = Beagle::Turso::Database.open(local_path: b, remote_url: url, auth_token: token)
    db.pull
    n = db.connect.query("SELECT count(*) FROM m WHERE name = ?", [marker]).first.first
    expect(n).to eq(1)
  end
end
```

- [ ] **Step 2: Run it** — fails (`open`/`push`/`pull` missing). With creds it errors; without, it SKIPs.

- [ ] **Step 3: Implement.** In `lib.rs` add a class method that takes all four options and `push`/`pull`:

```rust
impl RbDatabase {
    fn open(ruby: &Ruby, args: &[magnus::Value]) -> Result<RbDatabase, Error> {
        // parse a single Ruby Hash of keyword args
        let hash: magnus::RHash = args.first().copied().unwrap_or_else(|| ruby.hash_new().as_value()).try_convert()?;
        let local_path: String = hash.fetch::<_, String>(magnus::Symbol::new("local_path"))?;
        let remote_url: Option<String> = hash.lookup(magnus::Symbol::new("remote_url"))?;
        let auth_token: Option<String> = hash.lookup(magnus::Symbol::new("auth_token"))?;
        let bootstrap: Option<bool> = hash.lookup(magnus::Symbol::new("bootstrap_if_empty"))?;
        let opts = OpenOptions {
            local_path,
            remote_url,
            auth_token,
            bootstrap_if_empty: bootstrap.unwrap_or(true),
        };
        let db = Database::open(opts).map_err(|e| rt_err(ruby, e.to_string()))?;
        Ok(RbDatabase { inner: db })
    }

    fn push(&self) -> Result<(), Error> {
        let ruby = Ruby::get().map_err(|_| Error::new(magnus::exception::standard_error(), "no ruby"))?;
        self.inner.push().map_err(|e| rt_err(&ruby, e.to_string()))
    }

    fn pull(&self) -> Result<bool, Error> {
        let ruby = Ruby::get().map_err(|_| Error::new(magnus::exception::standard_error(), "no ruby"))?;
        self.inner.pull().map_err(|e| rt_err(&ruby, e.to_string()))
    }
}
```
Register in `init` (confirm the Magnus keyword-args pattern — `function!` with `-1` arity passing `&[Value]`, then parse the hash; or use magnus `scan_args`):
```rust
db.define_singleton_method("open", function!(RbDatabase::open, -1))?;
db.define_method("push", method!(RbDatabase::push, 0))?;
db.define_method("pull", method!(RbDatabase::pull, 0))?;
```
(`open` returns `()` from `push` → Ruby `nil`.)

- [ ] **Step 4: Provision creds + run.**
```bash
export TURSO_DATABASE_URL=$(turso db show beagle-turso-ci --url 2>/dev/null || turso db show turso-spike --url)
export TURSO_AUTH_TOKEN=$(turso db tokens create beagle-turso-ci 2>/dev/null || turso db tokens create turso-spike)
cd gems/beagle-turso && bundle exec rake compile && bundle exec rspec spec/sync_spec.rb
```
Expected: PASS with creds (`n == 1`), SKIP without. **Do not print the token.**

- [ ] **Step 5: Commit**
```bash
git add gems/beagle-turso/ext/beagle_turso/src/lib.rs gems/beagle-turso/lib/beagle/turso.rb gems/beagle-turso/spec/sync_spec.rb
git commit -m "feat(gem): synced Database.open + push/pull (env-gated spec)"
```

---

## Task 5: Credential safety in Ruby

**Files:** `spec/no_secret_logging_spec.rb`; `ext/beagle_turso/src/lib.rs` or `lib/beagle/turso.rb`.

**Interfaces:** `Database`/`Connection` `#inspect` must not contain the auth token; `open` failures must not surface it.

- [ ] **Step 1: Write the failing spec**

```ruby
require "beagle/turso"

RSpec.describe "no credential leakage" do
  it "keeps the auth token out of inspect and errors" do
    token = "SECRET-eyJshh"
    db = Beagle::Turso::Database.open(local_path: ":memory:", remote_url: nil, auth_token: nil)
    expect(db.inspect).not_to include(token)

    err = (Beagle::Turso::Database.open(local_path: "/x.db", remote_url: "not-a-scheme://x", auth_token: token) rescue $!)
    expect(err).to be_a(StandardError)
    expect(err.message).not_to include(token)
    expect(err.inspect).not_to include(token)
  end
end
```

- [ ] **Step 2: Run it.** The core already redacts on its side and never puts the token in URLs/errors; the default Magnus `inspect` on a wrapped object prints the class + address (no fields), so this likely PASSES as-is. If any Ruby-side sugar stores/echoes the token, remove it. If it passes, keep the spec as the regression guard.

- [ ] **Step 3: Commit**
```bash
git add gems/beagle-turso/spec/no_secret_logging_spec.rb
git commit -m "test(gem): auth token never appears in inspect or errors"
```

---

## Task 6: README, gemspec metadata, and precompiled-gem CI

**Files:** `gems/beagle-turso/README.md`; `beagle-turso.gemspec` (metadata); `.github/workflows/gem.yml`.

- [ ] **Step 1: Write `README.md`** — install, the local example (`open_local`/`execute`/`query`), the synced example (`open` + `push`/`pull`), the on-sync-durability note, MIT. No fabricated URLs beyond the known repo.

- [ ] **Step 2: Fill gemspec metadata** — `spec.homepage`, `spec.metadata["source_code_uri"] = "https://github.com/BeagleSoftwareUK/beagle-turso"`, `spec.description`.

- [ ] **Step 3: Add cross-compile CI** (`.github/workflows/gem.yml`) using `oxidized-rb/actions/setup-ruby-and-rust` + `rb-sys-dock` to build native gems for `x86_64-linux`, `aarch64-linux`, `arm64-darwin`. Confirm the current rb-sys-dock action inputs. The job also runs `bundle exec rspec` (sync spec SKIPs — no creds in CI).

```yaml
name: gem
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: oxidized-rb/actions/setup-ruby-and-rust@v1
        with:
          ruby-version: "3.3"
          rustup-toolchain: stable
          bundler-cache: true
          cargo-cache: true
      - run: bundle install
        working-directory: gems/beagle-turso
      - run: bundle exec rake compile
        working-directory: gems/beagle-turso
      - run: bundle exec rspec
        working-directory: gems/beagle-turso
```

- [ ] **Step 4: Run the full gate locally** — `cd gems/beagle-turso && bundle exec rake compile && bundle exec rspec` (all specs green; sync SKIPs without creds).

- [ ] **Step 5: Commit**
```bash
git add gems/beagle-turso/README.md gems/beagle-turso/beagle-turso.gemspec .github/workflows/gem.yml
git commit -m "docs(gem): README, gemspec metadata, and cross-compile CI"
```

---

## Self-Review

**Spec coverage (Plan 2 = the `beagle-turso` Ruby gem):**
- Native ext build pipeline (rb-sys/rake-compiler) ✓ (Task 1). Persistent `Database`/`Connection` wrapping ✓ (Task 2, proven by spike). Value kinds ✓ (Task 3). Synced `open`/`push`/`pull` ✓ (Task 4). Credential safety ✓ (Task 5). README + cross-compile CI ✓ (Task 6).
- Deferred to Plan 3 (correctly out of scope): the ActiveRecord adapter, SyncManager, Solid Queue job.

**Placeholder scan:** No "TBD"/"handle errors". Soft spots are explicit "confirm the Magnus 0.8 signature" notes on keyword-arg parsing and blob encoding — the rest of the wrapping is lifted verbatim from the passing spike.

**Type consistency:** Ruby method names (`open`, `open_local`, `connect`, `execute`, `query`, `push`, `pull`) and Rust `RbDatabase`/`RbConnection` are consistent across tasks; `execute -> Integer`, `query -> Array<Array>`, `pull -> Boolean` stable throughout.

## Follow-on

- **Plan 3 — `activerecord-beagle-turso`:** `BeagleTursoAdapter < SQLite3Adapter` using this gem's `Database`/`Connection` as `raw_connection`, `SyncManager` + Solid Queue recurring job, dummy-app + AR shared-adapter-suite. Written against this gem's real API once Plan 2 lands.
