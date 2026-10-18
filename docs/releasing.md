# Releasing

How to cut a release of the four packages in this repo:

| Package | Registry | Version lives in |
| --- | --- | --- |
| `beagle_turso_core` | crates.io | `crates/beagle_turso_core/Cargo.toml` |
| `beagle-turso` | RubyGems (source + precompiled platform gems) | `gems/beagle-turso/lib/beagle/turso/version.rb` |
| `activerecord-beagle-turso` | RubyGems (pure Ruby) | `gems/activerecord-beagle-turso/lib/activerecord/beagle_turso/version.rb` |
| `sequel-beagle-turso` | RubyGems (pure Ruby) | `gems/sequel-beagle-turso/lib/sequel/beagle_turso/version.rb` |

A release is a `vX.Y.Z` tag pushed to GitHub. That triggers
[`.github/workflows/release.yml`](../.github/workflows/release.yml), which
publishes everything through **trusted publishing (OIDC)**. No registry token
is stored in this repo, in GitHub secrets, or on anyone's disk.

## How the pipeline runs

```
publish-crate ──┬── cross-gems (one job per platform) ──┬── publish-gems
                └── source-gem ─────────────────────────┘
```

1. **`publish-crate`** publishes `beagle_turso_core` to crates.io. It has to
   go first. Inside this repo, the gem's native extension uses the local
   crate through `[patch.crates-io]` in `gems/beagle-turso/Cargo.toml`. That
   patch does not ship in the source gem, so a source install resolves the
   crate from crates.io. If the crate version is already published, the job
   skips it, so re-running a failed release is safe.
2. **`cross-gems`** builds precompiled `beagle-turso` gems for `x86_64-linux`,
   `aarch64-linux`, `x86_64-linux-musl`, `arm64-darwin` and `x86_64-darwin`.
   Each gem bundles native libraries for Ruby 3.3, 3.4 and 4.0. The matrix
   uses `fail-fast: false`, so one platform failing does not cancel the
   others.
3. **`source-gem`** builds the `ruby`-platform `beagle-turso` gem, which
   compiles on install and needs Rust, and the two pure-Ruby adapter gems.
4. **`publish-gems`** pushes `beagle-turso` (every platform plus source)
   first, then `activerecord-beagle-turso` and `sequel-beagle-turso`, which
   depend on it. A version
   that was already pushed is skipped, so re-runs are safe.

## 1. Prepare the release

On a branch, before merging:

- **Bump versions.** They are bumped together but need not be equal:
  - `crates/beagle_turso_core/Cargo.toml`: `version`.
  - `gems/beagle-turso/ext/beagle_turso/Cargo.toml`: the
    `beagle_turso_core = "X.Y.Z"` dependency must name the new crate
    version. The source gem resolves exactly this from crates.io.
  - `gems/beagle-turso/lib/beagle/turso/version.rb`.
  - `gems/activerecord-beagle-turso/lib/activerecord/beagle_turso/version.rb`,
    plus its gemspec's `beagle-turso` dependency if the driver's minor
    version moved.
  - `gems/sequel-beagle-turso/lib/sequel/beagle_turso/version.rb`, plus its
    gemspec's `beagle-turso` dependency if the driver's minor version moved.
  - Run `cargo build` at the repo root and `bundle exec rake compile` in
    `gems/beagle-turso`, so both `Cargo.lock` files pick up the new crate
    version. Commit both lockfiles.
- **Check compatibility for existing users.** The READMEs recommend
  `"~> 0.1"`-style constraints, and those accept *any* later `0.x` version.
  A minor bump therefore reaches existing apps on their next
  `bundle update`. Keep it a drop-in upgrade: anything they rescue today must
  still be rescued, and error message text that callers might match on
  should stay the same. If a break is unavoidable, call it out in the
  release notes.
- **Run the full suite locally**, including the remote specs. They only run
  with credentials for a dedicated test database, created with
  `turso db create <name> --tursodb`:

  ```bash
  set -a; . ./.env; set +a            # TURSO_DATABASE_URL, TURSO_AUTH_TOKEN
  cargo test && cargo fmt --check && cargo clippy --all-targets -- -D warnings
  (cd gems/beagle-turso && bundle exec rake compile && bundle exec rspec)
  (cd gems/activerecord-beagle-turso && bundle exec rspec)
  (cd gems/sequel-beagle-turso && bundle exec rspec && script/sequel-integration)
  ```

  Check that the output shows **no pending** examples. A pending remote
  example means it skipped and proved nothing.
- **CI green** on the PR. That covers the Rust checks, the gem on Ruby 3.3
  and 4.0, and the adapter.
- **Write the release notes**, which become the GitHub release body: what
  changed, anything behaviour-visible, and the upgrade steps for apps.

Merge to `master`.

## 2. Trusted publishers (one-time setup)

These are already set up for the three packages released so far
(`beagle_turso_core`, `beagle-turso` and `activerecord-beagle-turso`).
`sequel-beagle-turso` needs a **pending publisher on RubyGems before its first
release**, set up as described below, or its first push will fail. Revisit this
section only when **adding a new package**, such as a new gem:

- **RubyGems** (rubygems.org → profile → Trusted Publishers → GitHub
  Actions): add a **pending** publisher for the new gem name. Use repository
  `BeagleSoftwareUK/beagle-turso`, workflow `release.yml`, and leave the
  environment blank. A pending publisher is what lets the first publish of a
  brand-new gem go out over OIDC.
- **crates.io**: in the crate's settings, under Trusted Publishing, use the
  same repository and workflow. If crates.io requires the crate to exist
  before a publisher can be attached, publish once with a short-lived token
  (`cargo login <token>`, then `cargo publish -p <crate>`), then revoke that
  token straight away.

A new gem also needs adding to `release.yml`: build it in `source-gem` and
push it in `publish-gems`, after its dependencies.

## 3. Tag and publish

```bash
git switch master && git pull
git tag vX.Y.Z
git push origin vX.Y.Z
```

Watch the `release` workflow run in the Actions tab. Things worth knowing:

- **The darwin platforms are best-effort.** If `arm64-darwin` or
  `x86_64-darwin` fails, the Linux gems and the source gem still publish.
  Users on a missing platform fall back to the source gem, which needs a
  Rust toolchain. That is acceptable for a release; fix it in the next one.
- **`rb_sys` version drift.** `oxidize-rb/actions/cross-gem` installs the
  *latest* `rb_sys`, not the one in the lockfile. If a `cross-gems` job fails
  with something that looks like an FFI or ABI mismatch rather than a real
  compile error, first check whether `rb_sys` shipped a new release just
  before the run.
- **Re-running is safe.** Both publish steps skip versions that already
  exist. After fixing a broken platform job, re-run the failed jobs. Do not
  re-tag.

## 4. Verify

- crates.io: <https://crates.io/crates/beagle_turso_core> shows the new
  version.
- `gem list -r -e beagle-turso --all` shows the new version, with the
  platforms that published listed on the version line. `-e` matters: without
  it, the adapter gem matches too. `aarch64-linux`, `x86_64-linux` and
  `x86_64-linux-musl` must be present.
- `gem list -r -e activerecord-beagle-turso --all` shows the new version.
- `gem list -r -e sequel-beagle-turso --all` shows the new version.
- On a supported platform, `gem install beagle-turso -v X.Y.Z` installs
  without compiling. A `cargo` or `rustc` step in the output means it fell
  back to the source gem.

## 5. Roll out to apps

The app serves from its local replica, so a broken sync is invisible from
outside: HTTP 200 throughout. Upgrade **one app at a time**:

1. `bundle update beagle-turso activerecord-beagle-turso`, and deploy as
   usual. With Kamal, run `bin/kamal app stop` first, because the replica
   file is locked to one process (see the
   [setup guide](rails-app-setup.md)).
2. Confirm the replica opens on the new version, then make a write and check
   that the off-box copy advances. That means checking the remote database,
   not the site.
3. Only then upgrade the next app.

When the engine version (`turso`) changes in a release, step 2 is how you
learn whether an existing synced replica upgrades cleanly in place. Do not
skip it.

## Rollback

- **Apps first.** Pin the previous version in the app's Gemfile
  (`gem "beagle-turso", "= X.Y.(Z-1)"`), then `bundle update` and redeploy.
  This is the fastest fix and does not depend on the registries.
- **Yank a bad gem.** `gem yank` with no `--platform` only yanks the
  *source* gem, so every precompiled build stays installable. Yank each
  platform that published:

  ```bash
  gem list -r -e beagle-turso --all          # see which platforms published
  gem yank beagle-turso -v X.Y.Z --platform ruby
  gem yank beagle-turso -v X.Y.Z --platform x86_64-linux
  gem yank beagle-turso -v X.Y.Z --platform aarch64-linux
  gem yank beagle-turso -v X.Y.Z --platform x86_64-linux-musl
  gem yank beagle-turso -v X.Y.Z --platform arm64-darwin    # if it published
  gem yank beagle-turso -v X.Y.Z --platform x86_64-darwin   # if it published
  gem yank activerecord-beagle-turso -v X.Y.Z               # pure Ruby: one gem
  gem yank sequel-beagle-turso -v X.Y.Z                     # pure Ruby: one gem
  ```

- **Yank a bad crate.** Run `cargo yank --version X.Y.Z beagle_turso_core`.
  A yank stops new lockfiles from resolving that version but never deletes
  it. Publishing to crates.io is permanent, so the fix is always a new
  version.
- A yanked version number cannot be reused on either registry. Ship the fix
  as the next patch version.
