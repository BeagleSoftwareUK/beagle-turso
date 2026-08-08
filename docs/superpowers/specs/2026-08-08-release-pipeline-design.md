# beagle-turso Release Pipeline — Design

**Date:** 2026-08-08
**Status:** Approved (ready for implementation plan)

## Goal

Publish the three beagle-turso artifacts to public registries so consumers
(starting with ripponden_app) install them without a Rust toolchain or a git
clone at install/deploy time:

| Artifact | Registry | Kind |
| --- | --- | --- |
| `beagle_turso_core` | crates.io | Rust crate (the shared sync core) |
| `beagle-turso` | RubyGems | native ext — **precompiled** platform gems + a source fallback |
| `activerecord-beagle-turso` | RubyGems | pure Ruby (depends on `beagle-turso`) |

Success = `bundle install` on a supported platform pulls a prebuilt `.so`; the
ripponden_app Docker build no longer needs Rust/clang or the git-clone
hardening.

## Decisions locked during brainstorming

1. **Core crate → crates.io.** The ext's `beagle_turso_core = { path = … }`
   monorepo dep breaks when packaged. Publish the crate; the ext depends on the
   published version, with a workspace `[patch.crates-io]` keeping local/CI
   builds on the repo copy. Cleanest, makes the core reusable (the original
   "shared core for an Elixir/Ecto wrapper later" goal), and the source-gem
   fallback then compiles on any platform.
2. **Standard Rails-gem platform matrix** for the precompiled `beagle-turso`
   gem: `x86_64-linux`, `aarch64-linux`, `x86_64-linux-musl`, `arm64-darwin`,
   `x86_64-darwin`, plus a source gem fallback. No Windows.
3. **Trusted publishing (OIDC)** for both registries — no long-lived tokens
   stored in CI.

## Component 1 — packaging fixes

- `gems/beagle-turso/ext/beagle_turso/Cargo.toml`: change
  `beagle_turso_core = { path = "../../../../crates/beagle_turso_core" }` to
  `beagle_turso_core = "0.1.0"`. Keep `publish = false` on the ext crate itself
  (it ships inside the gem, never to crates.io).
- Root `Cargo.toml`: add
  ```toml
  [patch.crates-io]
  beagle_turso_core = { path = "crates/beagle_turso_core" }
  ```
  so in-repo builds (dev, `cargo test`, the CI cross-compile) resolve the local
  crate, while the packaged source gem's `ext/.../Cargo.toml` (which carries
  `= "0.1.0"` and no workspace) fetches `beagle_turso_core 0.1.0` from
  crates.io at a consumer's install.
- **Ordering consequence:** the crate must be published to crates.io *before*
  the gems, or a source-gem install can't resolve the core dep.
- `beagle_turso_core`'s `Cargo.toml` already has the crates.io-required metadata
  (license, description, repository, readme). Confirm `cargo publish --dry-run`
  (or `cargo package`) is clean; add `keywords`/`categories` if `cargo publish`
  warns, but nothing here is a blocker.
- Gemspec `spec.files` for `beagle-turso` already includes `ext/**/*.{rb,rs,toml}`
  — the crate source is intentionally NOT in the gem (crates.io provides it).
  No gemspec files change is needed for the crate.

## Component 2 — release workflow (`.github/workflows/release.yml`)

Trigger: push of a tag matching `v*` (e.g. `v0.1.0`). Jobs:

1. **publish-crate** (runs first): `cargo publish -p beagle_turso_core` via
   crates.io **trusted publishing** (OIDC — `rust-lang/crates-io-auth-action`
   or the documented crates.io OIDC exchange; no `CARGO_REGISTRY_TOKEN`
   secret). Guard so a re-run against an already-published version is a clean
   skip, not a hard failure.
2. **cross-compile** (matrix over the 5 platforms): `oxidize-rb/cross-gem-action`
   builds each precompiled `beagle-turso` platform gem from the existing
   `RbSys::ExtensionTask`; a separate step builds the source gem
   (`gem build gems/beagle-turso/beagle-turso.gemspec` or `rake build`). Upload
   all `.gem` artifacts.
3. **publish-gems** (needs 1 + 2): push every platform gem + the source gem to
   RubyGems via **trusted publishing** (`rubygems/configure-rubygems-credentials`
   OIDC, or `rubygems/release-gem`), then build + push `activerecord-beagle-turso`
   (pure Ruby, no matrix). Publish `beagle-turso` before the adapter.

### Key technical risk (call it out in the plan)

The ext needs `libclang`/bindgen to compile (why ripponden's Dockerfile added
`clang`/`libclang-dev`). Cross-compiling a bindgen-using crate for
`x86_64-linux-musl` and both `*-darwin` targets inside `rake-compiler-dock` is
the known friction point of this effort. The plan must **verify each platform
actually cross-compiles**; if a target won't build cleanly, drop it from the
matrix (consumers on it fall back to the source gem) rather than blocking the
release. `aarch64-linux` (the deploy target) and `x86_64-linux` (dev/CI) are
the must-haves; the rest are best-effort.

## Component 3 — trusted-publisher setup (operator / user, one-time)

I cannot do these — they are dashboard actions in the user's accounts. The plan
produces a short doc (`docs/superpowers/plans/…-release-runbook.md`) with the
exact values:

- **rubygems.org:** a pending trusted publisher for **each** gem
  (`beagle-turso`, `activerecord-beagle-turso`): GitHub repo
  `BeagleSoftwareUK/beagle-turso`, workflow `release.yml`, environment (if used)
  blank. RubyGems supports pending publishers for gems that don't exist yet, so
  no bootstrap manual push is required.
- **crates.io:** a trusted publisher for `beagle_turso_core`: same repo +
  workflow. If crates.io still requires the crate to exist first, the runbook
  documents a one-time manual `cargo publish` with a short-lived token as the
  bootstrap, then trusted publishing thereafter.

## Component 4 — release (operator)

All artifacts are `0.1.0`. Release = push tag `v0.1.0` → CI publishes crate →
gems. The runbook covers verifying each publish (crates.io page,
`gem list -r beagle-turso --all`, the platform gems present) and a re-run/yank
note if a step fails midway.

## Component 5 — switch ripponden_app to the published gems (the payoff)

After a successful publish, in the ripponden_app repo:

- `Gemfile`: replace the two `github:` git sources with
  `gem "beagle-turso", "~> 0.1"` and `gem "activerecord-beagle-turso", "~> 0.1"`
  (drop `require: false`? keep — `beagle-turso`'s lib entry is still
  `beagle/turso`; the adapter requires it). `bundle update` pulls the
  precompiled `aarch64-linux` binary — no compile.
- **Dockerfile:** remove the Rust toolchain block, the `clang`/`libclang-dev`
  apt additions, the `BUNDLE_DEPLOYMENT=false` + retry/clean/assert bundle-install
  hardening — none are needed once no native ext compiles at build. The build
  returns to a plain `bundle install`.
- Verify: local `bundle install` resolves the binary gem (no Rust invoked); a
  `docker build` succeeds without a toolchain; deploy staging (`-d beta`) — a
  fast, clone-free, flake-free build — and confirm health + sync still green.
- Keep the pin loose (`~> 0.1`) so patch releases flow in.

## Build vs. operator split (sequencing)

- **Built via SDD (this effort):** Components 1 + 2 (packaging fixes + the
  release workflow), and the runbook doc for 3/4. Verifiable locally:
  `cargo build`/`cargo test` with the patch, `cargo publish --dry-run`,
  `gem build` both gems, `cross-gem-action` config lint. The workflow itself
  can't fully run until a real tag + the user's trusted publishers exist.
- **Operator steps (with the user, after the branch merges):** Component 3
  (configure trusted publishers), Component 4 (tag `v0.1.0`, watch CI publish),
  Component 5 (switch ripponden_app + simplify the Dockerfile + deploy).

## Risks

- **bindgen cross-compile** (Component 2) — the primary risk; mitigated by
  verify-per-platform + source fallback.
- **Trusted-publishing first-release bootstrap** — crates.io/RubyGems pending-
  publisher support for not-yet-existing packages; runbook documents the manual
  bootstrap fallback if needed.
- **`turso = "=0.7.2"` exact pin** — fine for 0.1.0; note it so a future turso
  bump is a deliberate release.
- **Version coupling** — `activerecord-beagle-turso` depends on `beagle-turso`;
  keep their versions moving together (both 0.1.0 now). Add an explicit
  `"~> 0.1"` dependency floor in the adapter gemspec so an old driver can't be
  paired with a newer adapter.
