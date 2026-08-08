# beagle-turso Release Pipeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish `beagle_turso_core` (crates.io) and precompiled `beagle-turso` + pure-Ruby `activerecord-beagle-turso` (RubyGems) via a tag-triggered, trusted-publishing (OIDC) release pipeline, so consumers install without a Rust toolchain or a git clone.

**Architecture:** Fix the ext's monorepo crate path by depending on a published `beagle_turso_core` version with a workspace `[patch.crates-io]` for local/CI dev; a `release.yml` workflow publishes the crate first, then cross-compiles the ext for 5 platforms (`oxidize-rb/cross-gem-action`) + a source fallback, then pushes all gems. Local `rb-sys-dock` runs de-risk the cross-compile before any tag.

**Tech Stack:** Rust (cargo, rb-sys, magnus), Ruby gems (rake-compiler, RbSys::ExtensionTask), GitHub Actions (`oxidize-rb/*`, `rubygems/*`, `rust-lang/crates-io-auth-action`), crates.io + RubyGems trusted publishing.

**Spec:** `docs/superpowers/specs/2026-08-08-release-pipeline-design.md`.

## Global Constraints

- All three artifacts are version **`0.1.0`**; the release tag is **`v0.1.0`**.
- The crate publishes **before** the gems (a source-gem install resolves `beagle_turso_core` from crates.io).
- **Trusted publishing (OIDC) only** — no registry tokens stored in the repo/CI. Jobs that publish set `permissions: id-token: write`. Never echo/log a token.
- Platform matrix: `x86_64-linux`, `aarch64-linux`, `x86_64-linux-musl`, `arm64-darwin`, `x86_64-darwin`, plus a Ruby (source) gem. **`aarch64-linux` + `x86_64-linux` are must-build**; the other three are best-effort — if one won't cross-compile, drop it from the matrix (consumers fall back to source) rather than block the release.
- The ext crate (`beagle_turso`) keeps `publish = false`; `beagle_turso_core` is the only crates.io publish.
- `required_ruby_version >= 3.3`; adapter depends on `activerecord ~> 8.1`.
- In-repo `cargo test` / `bundle exec rake compile` / `rspec` must stay green after the packaging change (the `[patch.crates-io]` keeps dev on the local crate).

---

### Task 1: Packaging — publishable crate dep + workspace patch + adapter version floor

**Files:**
- Modify: `gems/beagle-turso/ext/beagle_turso/Cargo.toml`
- Modify: `Cargo.toml` (repo root — add `[patch.crates-io]`)
- Modify: `gems/activerecord-beagle-turso/activerecord-beagle-turso.gemspec`

**Interfaces:**
- Produces: an in-repo build that still resolves the local `beagle_turso_core` (via the patch), and a packaged ext `Cargo.toml` that carries `beagle_turso_core = "0.1.0"` for source-gem consumers. Consumed by Tasks 2 + 3.

- [ ] **Step 1: Establish the baseline (green in-repo build)**

Run: `cargo test -p beagle_turso_core` and `cd gems/beagle-turso && bundle exec rake compile`
Expected: both succeed today (sanity before the change).

- [ ] **Step 2: Point the ext at the published crate version**

In `gems/beagle-turso/ext/beagle_turso/Cargo.toml`, change:
```toml
beagle_turso_core = { path = "../../../../crates/beagle_turso_core" }
```
to:
```toml
beagle_turso_core = "0.1.0"
```
(Leave `publish = false` and everything else as-is.)

- [ ] **Step 3: Add the workspace patch so in-repo builds use the local crate**

In the repo-root `Cargo.toml`, append:
```toml
[patch.crates-io]
beagle_turso_core = { path = "crates/beagle_turso_core" }
```

- [ ] **Step 4: Add the adapter's version floor on the driver**

In `gems/activerecord-beagle-turso/activerecord-beagle-turso.gemspec`, change:
```ruby
spec.add_dependency "beagle-turso"
```
to:
```ruby
spec.add_dependency "beagle-turso", "~> 0.1"
```

- [ ] **Step 5: Verify in-repo build + tests still green (patch resolves local crate)**

Run: `cargo build` and `cargo test -p beagle_turso_core` (from repo root)
Expected: PASS — cargo prints a `Patch ... was not used`-free resolve; the ext builds against the local crate via the patch.
Run: `cd gems/beagle-turso && bundle exec rake compile && bundle exec rspec`
Expected: compile + specs green (creds-gated sync specs SKIP).
Run: `cd gems/activerecord-beagle-turso && bundle install && bundle exec rspec`
Expected: green.

- [ ] **Step 6: Verify the crate is publish-ready**

Run: `cargo publish -p beagle_turso_core --dry-run --allow-dirty`
Expected: packages cleanly (no missing-metadata errors). If `cargo` warns about missing `keywords`/`categories`, add them to `crates/beagle_turso_core/Cargo.toml` (e.g. `keywords = ["turso", "sqlite", "database", "sync"]`, `categories = ["database"]`) and re-run. A `beagle_turso_core = "0.1.0"` "not found in registry" note for the ext under `--dry-run` is expected (it isn't published yet) and is NOT a blocker for the crate's own dry-run.

- [ ] **Step 7: Verify both gems build**

Run: `cd gems/beagle-turso && gem build beagle-turso.gemspec` and `cd gems/activerecord-beagle-turso && gem build activerecord-beagle-turso.gemspec`
Expected: both produce a `.gem` with no errors. (The `beagle-turso` gem built here is the *source* gem; it carries the ext source + the `= "0.1.0"` Cargo dep.)

- [ ] **Step 8: Commit**

```bash
git add gems/beagle-turso/ext/beagle_turso/Cargo.toml Cargo.toml gems/activerecord-beagle-turso/activerecord-beagle-turso.gemspec crates/beagle_turso_core/Cargo.toml Cargo.lock
git commit -m "Make beagle_turso_core a published-version dep with [patch.crates-io] for dev"
```

---

### Task 2: Release workflow (`.github/workflows/release.yml`)

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: the packaging from Task 1 (crate version dep + patch).
- Produces: a `v*`-tag-triggered pipeline: publish crate → cross-compile gems → publish gems. Validated locally (dry-run steps + actionlint); the full run needs a real tag + configured trusted publishers (operator, post-plan).

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/release.yml`. Pin action versions to the current latest at authoring time and **verify each against its README** (`oxidize-rb/cross-gem-action`, `rubygems/configure-rubygems-credentials`, `rust-lang/crates-io-auth-action`) — the OIDC/trusted-publishing surface evolves, so confirm input/output names rather than trusting this snapshot blindly:

```yaml
name: release
on:
  push:
    tags: ["v*"]

jobs:
  publish-crate:
    runs-on: ubuntu-latest
    permissions:
      id-token: write   # crates.io trusted publishing (OIDC)
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - uses: rust-lang/crates-io-auth-action@v1
        id: auth
      - name: Publish beagle_turso_core (skip if version already on crates.io)
        run: |
          if cargo publish -p beagle_turso_core 2>publish.err; then
            echo "published"
          elif grep -q "already exists" publish.err; then
            echo "already published — skipping"; cat publish.err
          else
            cat publish.err; exit 1
          fi
        env:
          CARGO_REGISTRY_TOKEN: ${{ steps.auth.outputs.token }}

  cross-gems:
    needs: publish-crate
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        platform:
          - x86_64-linux
          - aarch64-linux
          - x86_64-linux-musl
          - arm64-darwin
          - x86_64-darwin
    steps:
      - uses: actions/checkout@v4
      - uses: oxidize-rb/actions/setup-ruby-and-rust@v1
        with:
          ruby-version: "3.3"
          rustup-toolchain: stable
          bundler-cache: true
          cargo-cache: true
          working-directory: gems/beagle-turso
      - uses: oxidize-rb/cross-gem-action@main
        with:
          platform: ${{ matrix.platform }}
          ruby-versions: "3.3,3.4"
          working-directory: gems/beagle-turso
      - uses: actions/upload-artifact@v4
        with:
          name: cross-gem-${{ matrix.platform }}
          path: gems/beagle-turso/pkg/*.gem

  source-gem:
    needs: publish-crate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with: { ruby-version: "3.3" }
      - run: gem build beagle-turso.gemspec
        working-directory: gems/beagle-turso
      - run: gem build activerecord-beagle-turso.gemspec
        working-directory: gems/activerecord-beagle-turso
      - uses: actions/upload-artifact@v4
        with:
          name: source-gems
          path: |
            gems/beagle-turso/*.gem
            gems/activerecord-beagle-turso/*.gem

  publish-gems:
    needs: [cross-gems, source-gem]
    runs-on: ubuntu-latest
    permissions:
      id-token: write   # RubyGems trusted publishing (OIDC)
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with: { ruby-version: "3.3" }
      - uses: actions/download-artifact@v4
        with: { path: dist, merge-multiple: true }
      - uses: rubygems/configure-rubygems-credentials@v1
      - name: Push beagle-turso (platform gems + source), then the adapter
        run: |
          set -e
          # beagle-turso platform + source gems first (adapter depends on it)
          for g in $(ls dist/beagle-turso-*.gem); do gem push "$g"; done
          # then the pure-Ruby adapter
          gem push dist/activerecord-beagle-turso-*.gem
```

Notes to encode while writing:
- If `rubygems/configure-rubygems-credentials` is not the current OIDC action name, use `rubygems/release-gem@v1` per its README instead — the requirement is *trusted publishing, no stored token*.
- `cross-gem-action`'s exact inputs (`platform`, `ruby-versions`, `working-directory`) must match its current README; adjust names if they differ.

- [ ] **Step 2: Lint the workflow**

Run: `actionlint .github/workflows/release.yml` (install via `go install github.com/rhysd/actionlint/cmd/actionlint@latest` or `brew install actionlint` if not present; if actionlint is genuinely unavailable in this environment, say so in the report and instead hand-verify YAML validity with `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml")'`).
Expected: no errors.

- [ ] **Step 3: Verify the locally-runnable publish steps work**

Run: `cargo publish -p beagle_turso_core --dry-run --allow-dirty`
Expected: clean (same as Task 1 Step 6).
Run: `cd gems/beagle-turso && gem build beagle-turso.gemspec && cd ../activerecord-beagle-turso && gem build activerecord-beagle-turso.gemspec`
Expected: both build (the workflow's `source-gem` job commands, run locally).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Add tag-triggered release pipeline (crate + precompiled gems, OIDC)"
```

---

### Task 3: De-risk the cross-compile locally (bindgen + workspace-patch visibility)

**Files:** none created — this task is a verification gate that may feed a matrix change back into Task 2's `release.yml`.

**Interfaces:**
- Consumes: Task 1's packaging + Task 2's platform list.
- Produces: confirmation that the must-have targets cross-compile, plus a documented list of any target dropped to source-fallback (which edits Task 2's matrix).

**Context:** The ext transitively needs `libclang`/bindgen (that's why ripponden_app's Docker build added `clang`/`libclang-dev`). Cross-compiling that for musl/darwin is the primary risk. Also, the `[patch.crates-io]` lives in the repo-root `Cargo.toml`, so the dock build MUST see the workspace root (not just `gems/beagle-turso`) or it will try to fetch `beagle_turso_core 0.1.0` from crates.io (not published during local testing) and fail. Ensure the dock mounts/uses the repo root.

- [ ] **Step 1: Build the must-have target in rake-compiler-dock**

Run (from `gems/beagle-turso`): `bundle exec rb-sys-dock --platform aarch64-linux --build`
(Requires Docker; the first run pulls a multi-hundred-MB `rake-compiler-dock` image — that's expected, not a hang. Run backgrounded/polled if it risks the 10-min cap.)
Expected: produces `gems/beagle-turso/pkg/beagle-turso-0.1.0-aarch64-linux.gem`.
If it fails resolving `beagle_turso_core` from crates.io, the workspace root isn't visible to the dock build — fix by pointing rb-sys-dock at the repo root (e.g. run from the repo root with the gem's directory configured, or set the mount) so the `[patch.crates-io]` applies. Document the exact invocation that works.

- [ ] **Step 2: Confirm the built gem contains the native library**

Run: `tar -xf gems/beagle-turso/pkg/beagle-turso-0.1.0-aarch64-linux.gem -O data.tar.gz | tar -tzf - | grep -E 'beagle_turso\.so'`
Expected: lists `lib/beagle_turso/beagle_turso.so` (the precompiled ext is inside the platform gem).

- [ ] **Step 3: Probe the bindgen-heavy target (musl)**

Run (from `gems/beagle-turso`): `bundle exec rb-sys-dock --platform x86_64-linux-musl --build`
Expected: either it builds a `-x86_64-linux-musl.gem` (good), OR it fails on a bindgen/libclang error. If it fails after a genuine attempt to make it work (e.g. the dock image lacks a cross `libclang` and there's no supported knob), **remove `x86_64-linux-musl` from `release.yml`'s matrix** and note it in the report + runbook (musl/Alpine consumers fall back to the source gem). Do the same probe for `arm64-darwin`/`x86_64-darwin` only if cheap; otherwise leave them in the matrix and let the first real CI run be their proof (they're best-effort, and `fail-fast: false` isolates a failed platform).

- [ ] **Step 4: Commit any matrix change**

If Task 2's matrix changed, commit it:
```bash
git add .github/workflows/release.yml
git commit -m "Drop <platform> from release matrix (cross-compile unsupported; source fallback)"
```
If no change was needed, record "matrix unchanged; aarch64-linux verified locally" in the task report and skip the commit.

---

### Task 4: Release runbook (operator steps)

**Files:**
- Create: `docs/superpowers/plans/2026-08-08-release-runbook.md`

**Interfaces:**
- Consumes: the workflow (Task 2) + verified matrix (Task 3).
- Produces: the exact operator procedure for trusted-publisher setup, tagging, verification, and the ripponden_app switch.

- [ ] **Step 1: Write the runbook**

Create `docs/superpowers/plans/2026-08-08-release-runbook.md` capturing:

```markdown
# beagle-turso v0.1.0 Release Runbook

Prereq: `release-pipeline` branch merged to master; `release.yml` present.

## 1. Configure trusted publishers (one-time, in your accounts)
- RubyGems (rubygems.org → Trusted Publishers → GitHub Actions), one PENDING
  publisher per gem (`beagle-turso`, `activerecord-beagle-turso`):
    Repository: BeagleSoftwareUK/beagle-turso
    Workflow filename: release.yml
    Environment: (leave blank)
  RubyGems supports pending publishers for gems that don't exist yet.
- crates.io (crate settings → Trusted Publishing, or the pending-publisher flow):
    Repository: BeagleSoftwareUK/beagle-turso
    Workflow filename: release.yml
  If crates.io requires the crate to exist first, bootstrap once with a
  short-lived token: `cargo login <token>` then `cargo publish -p beagle_turso_core`,
  then remove the token and rely on trusted publishing for later releases.

## 2. Release
- `git tag v0.1.0 && git push origin v0.1.0`
- Watch the `release` workflow: publish-crate → cross-gems (matrix) + source-gem → publish-gems.

## 3. Verify
- crates.io: https://crates.io/crates/beagle_turso_core shows 0.1.0.
- `gem list -r beagle-turso --all` shows 0.1.0; `gem list -r beagle-turso --platform` (or the RubyGems web page) shows the precompiled platforms present.
- `gem list -r activerecord-beagle-turso --all` shows 0.1.0.
- On a supported platform: `gem install beagle-turso` pulls a precompiled gem (no cargo/rustc invoked).

## 4. Switch ripponden_app (the payoff)
- Gemfile: replace the two `github:` sources with
    gem "beagle-turso", "~> 0.1"
    gem "activerecord-beagle-turso", "~> 0.1"
  (keep `require: false` on beagle-turso). `bundle update beagle-turso activerecord-beagle-turso`.
- Dockerfile: remove the Rust toolchain block, `clang`/`libclang-dev`,
  `RUN gem update --system 4.0.18`, and the `BUNDLE_DEPLOYMENT=false` retry/clean/assert
  bundle-install hardening — revert to a plain `RUN bundle install`.
- Verify: local `bundle install` uses the binary (no Rust), `docker build` succeeds
  without a toolchain, `bin/kamal deploy -d beta` is fast + clone-free, health + sync green.
  Then prod.

## Rollback
- A bad gem version: `gem yank beagle-turso -v 0.1.0` (and the adapter); ripponden_app
  stays on the git source until a fixed version ships. Crate yanks: `cargo yank --version 0.1.0`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/plans/2026-08-08-release-runbook.md
git commit -m "Add v0.1.0 release runbook (trusted publishers, tag, verify, ripponden switch)"
```

---

## Post-plan (operator, with the user)

After the final whole-branch review + merge: execute the **runbook** — configure trusted publishers, push `v0.1.0`, watch CI publish, verify, then switch ripponden_app to the published gems and strip the Docker toolchain/hardening. These need the user's registry accounts and a real tag, so they are intentionally outside the SDD loop.
