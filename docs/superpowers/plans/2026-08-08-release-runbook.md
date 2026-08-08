# beagle-turso v0.1.0 Release Runbook

**Audience:** operator (you), working with the assistant. Everything in this
document happens outside the SDD loop — it needs real registry accounts and a
real tag push, neither of which the pipeline can do on its own.

**Prereq:** `release-pipeline` branch merged to `master`; `.github/workflows/release.yml`
present on `master` (that's the workflow this runbook triggers).

## Global constraints (recap)

- All three artifacts (`beagle_turso_core`, `beagle-turso`, `activerecord-beagle-turso`)
  are version **`0.1.0`**; the release tag is **`v0.1.0`**.
- The crate publishes to crates.io **before** either gem — both gems' native
  ext resolves `beagle_turso_core` from crates.io once the workspace
  `[patch.crates-io]` no longer applies (i.e. outside this monorepo).
- **Trusted publishing (OIDC) only.** No registry token is stored in this repo,
  in GitHub secrets, or on disk anywhere. `release.yml`'s publishing jobs carry
  `permissions: id-token: write` and nothing else auth-related.

## 1. Configure trusted publishers (one-time, in your accounts)

- **RubyGems** (rubygems.org → your profile → Trusted Publishers → GitHub
  Actions), one **pending** publisher per gem (`beagle-turso`,
  `activerecord-beagle-turso`):
  - Repository: `BeagleSoftwareUK/beagle-turso`
  - Workflow filename: `release.yml`
  - Environment: (leave blank)

  RubyGems supports registering a pending publisher for a gem name that
  doesn't exist yet — that's what lets the very first publish of each gem go
  out via OIDC instead of a bootstrap token.

- **crates.io** (crate settings → Trusted Publishing, or the pending-publisher
  flow if the crate doesn't exist yet):
  - Repository: `BeagleSoftwareUK/beagle-turso`
  - Workflow filename: `release.yml`

  If crates.io requires the crate to already exist before you can attach a
  trusted publisher to it, bootstrap once with a short-lived token:
  `cargo login <token>` then `cargo publish -p beagle_turso_core`, then
  **remove the token** (`cargo logout` / revoke it on crates.io) and rely on
  trusted publishing for every release after this one.

## 2. Release

- `git tag v0.1.0 && git push origin v0.1.0`
- Watch the `release` workflow run:
  `publish-crate` → `cross-gems` (matrix) + `source-gem` → `publish-gems`.

### Things to confirm on this first real run

The workflow has never executed for real before — everything below was either
proven with a local stand-in (`rb-sys-dock`, not the actual composite action)
or left as an explicit best-effort. Watch for these specifically:

- **Platforms expected to succeed** (validated locally in Task 3 with
  `rb-sys-dock`, the same underlying mechanism `oxidize-rb/actions/cross-gem`
  wraps): `aarch64-linux` (the deploy target, and the MUST-HAVE platform) and
  `x86_64-linux-musl` both cross-compiled cleanly end-to-end, including the
  bindgen/libclang step that was the anticipated risk for musl. Confirm both
  show up as `0.1.0` platform gems on RubyGems.
- **Platforms that are best-effort and unproven locally**: `arm64-darwin` and
  `x86_64-darwin`. Nothing about them has actually been exercised — they're
  in the matrix on faith. `fail-fast: false` on the `cross-gems` job means a
  failure on either one does not block the Linux platforms or the source gem;
  consumers on a failed platform silently fall back to installing the source
  gem (which compiles locally, needing Rust). If one of these fails, that's
  an acceptable, anticipated outcome — not a stop-the-release problem.
- **`rb_sys` version drift in `cross-gems`**: `oxidize-rb/actions/cross-gem`'s
  "Setup rb-sys" step installs the *latest* `rb_sys` release from the remote,
  not the version pinned in `Gemfile.lock` — a known quirk of that third-party
  action, not a bug in this repo. It's usually harmless, but if a `cross-gems`
  matrix job fails in a way that doesn't look like a real compile error (odd
  FFI/ABI mismatch, an `rb_sys` API that doesn't match what's vendored
  locally), check whether upstream shipped a new `rb_sys` release right
  before this run — that's the first thing to rule out before treating it as
  a real cross-compile regression.

## 3. Verify

- crates.io: <https://crates.io/crates/beagle_turso_core> shows `0.1.0`.
- `gem list -r -e beagle-turso --all` shows `0.1.0` (the `-e`/`--exact` flag
  matters — without it, `gem list` does unanchored substring matching and the
  output also picks up `activerecord-beagle-turso`). The same command's
  output lists the published platforms inline on the version line (e.g.
  `0.1.0 ruby aarch64-linux x86_64-linux ...`) — no separate `--platform`
  flag exists for `gem list`. Cross-check the platform list against the
  "things to confirm" list above (`aarch64-linux`, `x86_64-linux`, and
  `x86_64-linux-musl` must be present; `arm64-darwin`/`x86_64-darwin` are
  nice-to-have); the
  RubyGems web page for the gem shows the same platform breakdown if you'd
  rather read it there.
- `gem list -r -e activerecord-beagle-turso --all` shows `0.1.0`.
- On a supported platform: `gem install beagle-turso` pulls a precompiled gem
  (no `cargo`/`rustc` invoked — watch the install output for a compile step,
  which would mean it silently fell back to the source gem instead of a
  platform gem).

## 4. Switch ripponden_app (the payoff)

- **Gemfile**: replace the two `github:` sources with:
  ```ruby
  gem "beagle-turso", "~> 0.1", require: false
  gem "activerecord-beagle-turso", "~> 0.1"
  ```
  (keep `require: false` on `beagle-turso` — its lib entry point isn't
  `beagle-turso`, so a bare `require` would `LoadError`; the adapter requires
  it internally). Then `bundle update beagle-turso activerecord-beagle-turso`.
- **Dockerfile**: remove the Rust toolchain block (`rustup`, `ENV
  RUSTUP_HOME`/`CARGO_HOME`/`PATH`), drop `clang`/`libclang-dev` from the
  `apt-get install` line, remove `RUN gem update --system 4.0.18`, and remove
  the `BUNDLE_DEPLOYMENT=false` retry/clean/assert bundle-install hardening —
  revert all of it to a plain `RUN bundle install`. All of that existed only
  to make Bundler actually invoke `cargo`/`rb_sys` for the git-sourced gem;
  none of it is needed once the gems are precompiled RubyGems.
- **Verify, in order**:
  1. Local `bundle install` — confirm it pulls the precompiled binary gem
     (no Rust/cargo invocation in the output).
  2. `docker build` succeeds with no Rust/clang toolchain in the image at all.
  3. `bin/kamal deploy -d beta` (staging) — should be noticeably faster and
     clone-free (no `github:` source to `git clone`/`git fetch`). Confirm
     health check green and DB sync/behavior unchanged.
  4. Once staging looks right, deploy prod the same way.

## Rollback

- **A bad gem version**: `gem yank beagle-turso -v 0.1.0` with no
  `--platform` only yanks the *source* (`ruby`-platform) gem — every
  precompiled platform build stays live and installable, including
  whichever one is ripponden_app's actual deploy target (`aarch64-linux`).
  Yank every platform that actually published, explicitly:
  ```
  # List what actually published, then yank each platform shown:
  gem list -r -e beagle-turso --all
  gem yank beagle-turso -v 0.1.0 --platform ruby
  gem yank beagle-turso -v 0.1.0 --platform aarch64-linux
  gem yank beagle-turso -v 0.1.0 --platform x86_64-linux
  gem yank beagle-turso -v 0.1.0 --platform x86_64-linux-musl
  # ...and any darwin platforms that built (arm64-darwin / x86_64-darwin)
  gem yank activerecord-beagle-turso -v 0.1.0   # pure-Ruby, single platform — fine as-is
  ```
  ripponden_app can stay pinned to the `github:` source (i.e. don't do the
  Gemfile switch in section 4, or revert it if already done) until a fixed
  version ships.
- **A bad crate version**: `cargo yank --version 0.1.0 beagle_turso_core`.
