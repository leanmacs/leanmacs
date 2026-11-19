# CI

`.github/workflows/ci.yml` runs [the gate](the-gate.md) on GitHub Actions
on every push to any branch and on every pull request. Tags are not pushed,
so a tag push runs nothing. On a push to `main`, once the gate has passed
on both legs, it also builds the nightly's `.dmg` and uploads it as a
workflow artifact (`.github/workflows/build.yml`), then publishes it as the
rolling `nightly` prerelease and deploys the download page,
<https://leanmacs.github.io/leanmacs/>, for that build
(`.github/workflows/release.yml`).

## The jobs

### `ci`: the gate on two legs

One matrix job runs `mise run ci`, unchanged, in its step named "Gate", on
each leg:

| Leg | Why |
|---|---|
| `macos-26` (Apple silicon) | The platform the app ships for. |
| `ubuntu-24.04` (x86-64) | Keeps the gate holding on Linux, as `mise run linux-ci` does on the owner's machine (arm64, in a container). |

The runner images are pinned by name, so a change of image is a reviewed
diff. `fail-fast` is off, so one leg's failure does not cancel the other's
result. No job or step continues on error, so a red leg fails the workflow.

The job sets:

- `MISE_AUTO_INSTALL: "false"`: mise installs only what the mise-action
  step names (Rust, cargo-deny, clang-format and the workflow lint's three
  tools), never the rest of `mise.toml` (hk, pkl, OpenTofu, gitleaks).
- `CARGO_PROFILE_DEV_DEBUG: "0"`: the runner's disk is small, and nothing
  the gate checks reads debug information (`tools/linux/run.sh` does the
  same, for the same reason).

Lean is not installed by mise on a runner. On the owner's machine `lean`
and `lake` come from a local mise plugin in the owner's global config, which
a runner has none of. The job installs elan instead, as the Linux container
does: `tools/ci/install-elan.sh` downloads the elan release the Dockerfile
pins, checks its SHA-256, and installs it into `~/.elan`. elan then reads
`lean/lean-toolchain`, which stays the one pin of the toolchain, and
installs that toolchain on first use.

**Deployment target.** Every build, local and CI alike, targets macOS
26.0: `MACOSX_DEPLOYMENT_TARGET` in `mise.toml`'s `[env]`, the executable's
`minos`, equals `appMinimumSystemVersion` in `lean/lakefile.lean`, the
bundle's `LSMinimumSystemVersion`. The download page's "macOS … or later"
reads the same variable (`mise run site`), so it has no copy of its own. There is no CI profile of `mise.toml`
and no `MISE_ENV`. The owner chose 26.0 on 2026-11-17, lowering it from
27.2, because:

1. The Apple-silicon runner is fixed at `macos-26`, and dyld refuses to
   start a Mach-O whose `minos` is newer than the host. A bundle built for
   27.2 could not have its headless mode run by `app-check` on the runner,
   or its `--version` run by `dmg-check`, and the `.dmg` is uploaded only
   after both pass.
2. 26.0 is proven: the gate builds the whole tree for it and runs all its
   tests on `macos-26`, and `build` runs the shipped bundle itself there
   (relocated, with an empty environment, elaborating config from the
   bundle's own modules) before every upload. That meets the lakefile's
   rule, "the lowest macOS the bundle has been run on", as far as
   `app-check` exercises the app.
3. One value, not two. Keeping 27.2 for the bundle while linking CI's
   executable for 26.0 would ship an app Finder refuses to open on macOS 26
   although it runs there, weaken `app-check`, and keep a CI-only profile.
4. The nightly is for sharing, and most Apple-silicon Macs it is shared
   with run 26 or later.

The residual risk: nobody has opened the window (winit, wgpu on Metal,
Core Text) on macOS 26. Owner check 8 below opens the nightly once on a
macOS 26 Mac.

### `build-id`: one build ID for the run

On a push to `main` only (`if: github.event_name == 'push' && github.ref
== 'refs/heads/main'`), after `ci` (`needs: ci`), on `ubuntu-24.04`. It
installs Rust alone with mise-action and runs `mise run build-id`: HEAD's
committer time in UTC as `YYYYMMDDHHMMSS`, worked out by
`crates/editor-release` ([`building.md`](building.md), "The app bundle").
Its output `id` is the run's one build ID, so the `.dmg`, the release and,
in a later phase, its page all name the same build, as in ev-nova.

### `build`: the .dmg

On a push to `main` only, after both legs of `ci` and `build-id` (`needs:
[ci, build-id]`), with a token that reads contents only. It calls the
reusable workflow `.github/workflows/build.yml` with the inputs
`build-id` (`build-id`'s output), `commit` and `ref` (both `github.sha`).
`concurrency` never cancels a run on `main` in progress, so a build is
never cut off halfway. Its `uses:` carries an inline
`# zizmor: ignore[self-repository]`: zizmor asks for the newer
`$/.github/workflows/…` form, which the pinned actionlint refuses, and
`./` names this repository's file at the commit being run either way. It
does not wait for `secrets-scan`: the `.dmg` holds no history, and
`release`, which publishes it, does wait.

`build.yml` has one job, `build`, on `macos-26`, with
`MISE_AUTO_INSTALL: "false"`, `CARGO_PROFILE_DEV_DEBUG: "0"`, and the
stamp, `LEANMACS_BUILD_ID` and `LEANMACS_COMMIT`, from its inputs (inputs
reach a step only through `env:`, never inside `run:`). Its steps:

1. Check out `ref`, without leaving the token in `.git/config`.
2. mise-action, installing Rust alone.
3. Restore `~/.elan` with `ci`'s key, and install elan as `ci` does.
4. rust-cache, in an entry of this job's own.
5. Restore `lean/.lake` with `ci`'s key and restore-keys: the exact key is
   the one `ci (macos-26)` just saved for this commit, so no Lean module is
   rebuilt.
6. "App check": `mise run app-check`, which builds the bundle stamped with
   the run's build ID and commit (`mise run app`) and checks it
   ([`on-demand-checks.md`](on-demand-checks.md)).
7. "Pack": `mise run dmg`, which packs `dist/Leanmacs-<build-id>.dmg`.
8. "Check the dmg": `mise run dmg-check`, which mounts the image and checks
   its entries, their bytes, the app's signature, stamp and `--version`.
9. Upload `dist/*.dmg` as the workflow artifact `Leanmacs-dmg`, kept 14
   days, failing if there is no `.dmg` (`if-no-files-found: error`).

Every step runs unconditionally, so a failed check uploads nothing. The
artifact is on `main`'s runs only; a branch or a pull request builds no
`.dmg`. Download it from the run's "Artifacts" list: a zip holding
`Leanmacs-<build-id>.dmg`.

### `release`: the nightly

On a push to `main` only, after both legs of `ci`, `build-id`, `build` and
`secrets-scan` (`needs: [ci, build-id, build, secrets-scan]`), so a branch
or a pull request publishes nothing, moves no tag and deploys no page. It
is the only job in the workflow that writes: its `permissions` are exactly
`contents: write`, for the release's assets and the tag, and
`pages: write` and `id-token: write`, for the page's deploy, while the
workflow's top-level token reads contents only. A called workflow's jobs
can never hold more than the calling job grants, so it grants the union of
`release.yml`'s two jobs, and each of those names exactly its own. It sits in a concurrency
group of its own, `nightly-release`, never cancelled in progress, so two
nightlies never publish at once and none is cut off halfway. It calls the
reusable workflow `.github/workflows/release.yml` with the inputs
`build-id` (`build-id`'s output), `commit` and `ref` (both `github.sha`),
with the same `# zizmor: ignore[self-repository]` as `build`.

`release.yml` has two jobs, `publish` and `pages`. `publish` runs on
`macos-26`, with top-level `permissions: {}` and the job's exactly
`contents: write`,
`MISE_AUTO_INSTALL: "false"`, and `LEANMACS_BUILD_ID` and
`LEANMACS_COMMIT` from its inputs. It runs on macOS because it mounts the
`.dmg` to read the published app's `Info.plist` with `hdiutil` and
`plutil`, the tools `dmg-check` already trusts; the repository is public,
so macOS minutes are free. Its steps:

1. Check out `ref`, without leaving the token in `.git/config`.
2. mise-action, installing Rust alone. Its tool cache is the job's only
   cache, saved from `main` only by the common `mise-action` rule: it is
   written only by `main`'s own runs, holds only the pinned toolchain, and
   no branch or pull request can write it. There is no rust-cache and no
   `actions/cache` step; the release tool, `crates/editor-release-std`,
   has no third-party dependency and is built from source here.
3. Download the workflow artifact `Leanmacs-dmg` into `dist/`.
4. "Prepare the nightly": `mise run nightly`, with no token. It builds the
   release tool and runs `leanmacs-release nightly dist target/nightly`
   (`crates/editor-release`, `nightly`): it mounts
   `dist/Leanmacs-<build-id>.dmg`, checks that the file name names the
   run's build and that the app's `CFBundleVersion` and `LeanmacsCommit`
   are the run's build ID and commit, detaches it, and writes to
   `target/nightly` the two images, `Leanmacs.dmg.sha256`, `build.json`
   and the release notes, made from the same ID and commit it checked. A
   mismatch fails here, before anything is uploaded.
5. "Render the download page": `mise run site -- target/nightly/build.json
   target/site`, with no token (`crates/editor-release`, `site`). It
   reads the `build.json` the step above wrote, the very file the publish
   step re-reads and uploads, so the page names the build this run
   publishes; a re-download would need a token and network and could
   race a newer nightly. The minimum macOS is `MACOSX_DEPLOYMENT_TARGET`.
   It writes `target/site/index.html`, one self-contained page that loads
   no resource (no script, stylesheet, font or image): the build ID,
   commit, date, size and SHA-256, the link to `Leanmacs.dmg` and its
   checksum, the requirements, the install and first-launch steps
   (`packaging/macos/README.txt`'s, word for word) and `editor
   --version`. A page that cannot be rendered stops the nightly here.
6. `actions/upload-pages-artifact`, of `target/site`, still with no token:
   the `github-pages` artifact `pages` deploys.
7. "Publish the nightly": `target/debug/leanmacs-release publish
   target/nightly`, the last step and the only one with a token
   (`GH_TOKEN`, the job's own). It compiles nothing. It refuses to run
   except on a push to `refs/heads/main`, reads `build.json` and the
   checksum back and refuses them unless they describe this build and
   `Leanmacs.dmg`'s size. It copies `Leanmacs.dmg`, `Leanmacs.dmg.sha256`
   and `build.json` to the same names with `.new` appended (an asset is
   named after its file), and re-checks the SHA-256 of the build-ID copy
   and of `Leanmacs.dmg.new`, the file that goes up. Then, each step only
   if the one before it succeeded:
   1. on the first run, `gh release create nightly --prerelease --target
      <commit>`, which creates the tag at the commit;
   2. delete any `*.new` asset a failed run left behind;
   3. upload `Leanmacs-<build-id>.dmg` (a new name, so the old nightly is
      untouched), then `Leanmacs.dmg.new`, `Leanmacs.dmg.sha256.new` and
      `build.json.new`, beside the old assets. Nothing is uploaded with
      `--clobber` over a live name: `gh release upload --clobber` deletes
      the old asset *before* uploading the new one, so the permanent link
      would 404 for the whole upload and stay gone if it failed. A failed
      upload here leaves the old nightly whole;
   4. list the asset ids (`gh api repos/<repo>/releases/tags/nightly`) and,
      for `Leanmacs.dmg`, then `Leanmacs.dmg.sha256`, then `build.json`
      last, delete the old asset and rename the new one to its name
      (`gh api --method DELETE` then `--method PATCH
      repos/<repo>/releases/assets/<id> -f name=<name>`), so each name is
      missing only between those two calls and `build.json` never names a
      build whose `.dmg` is not up yet;
   5. move the tag to the commit through the API (`gh api --method PATCH
      repos/<repo>/git/refs/tags/nightly`), so no git credentials are ever
      set up;
   6. set the title, "Leanmacs nightly", and the notes, as a prerelease;
   7. delete old build-ID copies: the release keeps the newest **10**
      `Leanmacs-<build-id>.dmg`, by build ID, the current one always among
      them, and never deletes the fixed names or a name it does not
      recognise.

No step has an `if:`, so a failure before the last step leaves the
previous nightly's assets and tag as they were, and so does a failure in
the uploads. A failure partway through the swaps can leave some names on
the new build and the rest on the old one, or one name missing with its
`.new` beside it: the next green push deletes the `.new` leftovers and
fixes it.

The assets, at permanent links under
`https://github.com/leanmacs/leanmacs/releases/download/nightly/`:

| Asset | What |
|---|---|
| `Leanmacs.dmg` | The newest build: [`…/nightly/Leanmacs.dmg`](https://github.com/leanmacs/leanmacs/releases/download/nightly/Leanmacs.dmg). |
| `Leanmacs-<build-id>.dmg` | The same image under its build's name; the newest 10 are kept. |
| `Leanmacs.dmg.sha256` | `<sha-256>  Leanmacs.dmg`: `shasum -a 256 -c Leanmacs.dmg.sha256` beside the download checks it. |
| `build.json` | The build, for the download page. |

`build.json`'s keys, in this order, with a two-space indent and a final
newline:

```json
{
  "build_id": "<14 digits>",
  "commit": "<40 hex>",
  "date": "YYYY-MM-DDTHH:MM:SSZ",
  "size": <bytes>,
  "sha256": "<64 hex>",
  "file": "Leanmacs.dmg",
  "build_file": "Leanmacs-<build-id>.dmg"
}
```

`date` comes from the build ID: it is the commit's time in UTC, not the
time of the run. The release notes give the build ID, the commit with its
link, the date, the size, the SHA-256, "macOS 26.0 or later, on Apple
silicon", the first-launch steps of `packaging/macos/README.txt` ("Open
Anyway", and the `xattr` fallback) and `editor --version`. The
first-launch and `--version` text is `crates/editor-release`'s `install`
module, which the download page renders too, so the notes, the page and
the README say the same words.

`pages` needs `publish` and has no `if:`, so it runs only after a publish
that succeeded. On `ubuntu-24.04`, with exactly `pages: write` and
`id-token: write`, in the `github-pages` environment, which only `main`
may deploy to (`infra/github/pages.tf`), and in a concurrency group of its
own, `pages`, never cancelled in progress. Its one step is
`actions/deploy-pages`: it checks out nothing and runs no code of this
repository, so the job holding the deploy scopes runs only a GitHub-owned
action. The environment's URL is the deployment's `page_url`.

**Do not re-run an old run's `release / publish` job.** It would republish
that older build over a newer one, and its page with it. Push again
instead.

### `secrets-scan`

`mise run secrets-scan` ([`publishing.md`](publishing.md), "The secret
scan"): the probe, then gitleaks over `main`'s history, its merges and the
uncommitted tree. It is a job of its own because it needs the full history
(`fetch-depth: 0`), which the gate does not, and only gitleaks.

`tools/secrets-scan.sh` scans the local `main` by name, so a step first
makes the local `main` the commit under test: on `main` it is `main`
itself; on another branch or a pull request's merge ref, `main` is made
the commit checked out. Its history is `main`'s plus the commits being
pushed, which are public once pushed, so they are scanned too.

## Concurrency

Runs are grouped per workflow and ref
(`${{ github.workflow }}-${{ github.ref }}`). GitHub keeps one pending run
per group, so a newer push supersedes an older push's pending run. On a
branch or a pull request a newer run also cancels the one in progress. On
`main` a running run is never cancelled (`cancel-in-progress` is false
there): the build and release jobs must never be cut off halfway.

The `release` job is also in a job-level group of its own,
`nightly-release`, with `cancel-in-progress: false`: two nightlies never
publish at once, even from two runs, and a running one is never cancelled.
GitHub keeps one pending job per group, so of several queued releases only
the newest waits. The group holds the whole called workflow, `pages`
included, so one run's deploy finishes before the next run's publish
starts, and the page never names an older build than the release. `pages`
also has a group of its own, `pages`, never cancelled in progress, as
`actions/deploy-pages` recommends.

## Caches

Every cache is restored on any ref and saved only from `main`. A cache
saved under a branch or a pull request's `refs/pull/N/merge` is invisible
to `main` and to other branches, so saving there would only spend the
repository's cache space; every ref can restore `main`'s.

| What | Path | Key | Saved |
|---|---|---|---|
| mise and the tools it installed | mise's data directory | mise-action's default key: the mise version, the config files and the install args | By mise-action itself, at the end of its step, from `main` only (`cache_save`). |
| elan and the Lean toolchains it installed | `~/.elan` | `elan-v1-<OS>-<arch>-<hash of lean/lean-toolchain and tools/ci/install-elan.sh>` | By an `actions/cache/save` step after the gate, from `main` only, not when the exact key was restored. |
| Cargo's registry and the third-party dependencies' build artifacts. Not the workspace's own crates: rust-cache prunes them from `target/` before saving (`cache-workspace-crates` is off), so they and the `target/release/libeditor_ffi.a` Lake's `rustlib` builds are rebuilt on every run, against cached dependencies | `~/.cargo`, `target/` | rust-cache's own: the Rust version, `Cargo.lock` and the Cargo manifests | By rust-cache's post step at the end of the job, from `main` only (`save-if`), even when the gate failed (`cache-on-failure`). |
| Lake's build output and fetched packages | `lean/.lake` | `lake-v1-<OS>-<arch>-<hash of lean/lean-toolchain and lean/lake-manifest.json>-<commit>`, restoring the newest entry with the same prefix when the commit has none | By an `actions/cache/save` step after the gate, from `main` only, not when the exact key was restored. |

`build.yml`'s job restores `ci`'s elan and Lake entries, with `ci`'s keys,
and saves neither: it has no `actions/cache/save` step. The rule dates
from when the bundle (813 MB on 2026-11-19) was built under `lean/.lake`
and must not enter the cache. The bundle is now built under `packages/.lake`
(`packages/.lake/build/Leanmacs.app`), which no cache step names, and the
rule and the workflow's comment were left as they were. Its rust-cache entry is its own (rust-cache keys on the job),
saved from `main` only, as is its mise-action's.

`release.yml`'s jobs have no cache step at all: the only cache either uses
is `publish`'s mise-action's, saved from `main` only like every other.

The two `actions/cache/save` steps of `ci` run after the gate, so they hold the
built tree, and they run when the gate failed too (not when the run was
cancelled), so a red `main` still refreshes them. The combined
`actions/cache` action is not used: it saves from any ref.

Lake's key ends in the commit, so `main` saves a fresh entry for each
commit, and a later run on any ref restores the newest one for the same
toolchain and manifest, from which Lake rebuilds only what changed. A
re-run of the same commit on `main` restores the exact key, rebuilds no
Lean module (Lake still runs Cargo for `rustlib` on every build, which
rebuilds the workspace's crates and `libeditor_ffi.a` since rust-cache
does not hold them, and may relink), and saves nothing. A change of `lean/lean-toolchain` or
`lean/lake-manifest.json` starts Lake's and elan's caches afresh.

**What the Lake entry holds since the editor is built from a package set**
([packages.md](../design/packages.md), "The package set and its build"):

- **The core's build output and the formatter's clone**, as before. The
  formatter is required by its host (`tools/lean-fmt/`), whose
  `packagesDir` is `lean/.lake/packages`, so the clone and its build are
  still under `lean/.lake`. On an entry without it, the first `lean-fmt`
  step clones it there at the revision the host's manifest pins and builds
  it (20 s on a developer's Mac).
- **Not the sets' or the packages' build output**: `packages/.lake`,
  `packages/shipped-themes/.lake`, `tests/packages/.lake`, each fixture
  package's `.lake` and `tests/empty-set/.lake` are in no cache. So every
  run writes and compiles the three generated roots, links the default
  set's editor, the fixture set's and the one built from the core alone,
  builds the default package `shipped-themes` and the fixture packages,
  and links the two linked tests: seconds on a developer's Mac
  ([packages.md](../design/packages.md), "Build times"), not measured on
  a runner.
- **The key no longer hashes the formatter's pin**, which moved from
  `lean/lake-manifest.json` to `tools/lean-fmt/lake-manifest.json`. The
  formatter's releases are tagged with the Lean toolchain they are built
  for, so its pin changes with `lean/lean-toolchain`, which the key
  hashes. A change of the formatter's revision alone would restore an
  entry that holds the old clone; that case has not been run.
- **The first run after this change starts from no Lake entry**: the
  core's Lake package was renamed, and its manifest, which the key
  hashes, changed with it. So it clones the formatter and builds every
  Lean module once.

## Owner checks after the first push

Nothing here can be checked offline: the gate's own run (`mise run ci`)
checks the workflow's shape, but only GitHub runs it. After this workflow
lands, the owner confirms it live, in this order.

1. **Before the first push, apply the allowlist.** `Swatinem/rust-cache@*`
   is newly in `infra/github/actions.tf`'s `patterns_allowed`; until it is
   applied, the `ci` jobs fail at startup. Run `mise run infra-apply`. If
   the repository's settings have never been applied, that is the two-step
   first apply in [`infra/github/README.md`](../../infra/github/README.md),
   "The first apply".
2. **First push to `main`.** On the Actions tab, the run of "CI" shows three
   green jobs: `ci (macos-26)`, `ci (ubuntu-24.04)` and `secrets-scan`.
   - In each `ci` leg's "Gate" step, the log ends with mise finishing the
     `ci` task with no error.
   - In `secrets-scan`, the log shows four `secrets-scan: … pass` lines and
     no `failed:`.
3. **(Optional) a red leg fails the workflow.** Push a throwaway branch with
   an unformatted `.rs` file. The workflow is red, the `fmt` failure appears
   in both legs, and then delete the branch.
4. **The caches restore.** On that `main` run, choose "Re-run all jobs",
   with no new commit. In each `ci` leg:
   - The rust-cache step logs `Restored from cache key "v0-rust-…"` with
     `full match: true`.
   - The Lake restore step logs
     `Cache restored from key: lake-v1-<OS>-<ARCH>-<hash>-<that commit's sha>`.
   - The elan restore step logs `Cache restored from key: elan-v1-…`.
   - In the Gate log, the `lean` task prints no `Built Editor.` lines for
     Lean modules. Lines for `rustlib`, the C glue or the executable's link
     may appear: Lake reruns Cargo on every build, and the workspace's own
     crates are rebuilt because rust-cache does not hold them.
   - Both `actions/cache/save` steps are skipped: the exact keys were
     restored.

### After the .dmg lands

5. **Push to `main`.** The "CI" run shows these jobs green: `ci (macos-26)`,
   `ci (ubuntu-24.04)`, `secrets-scan`, `build-id` and `build / build`.
   - `ci (macos-26)` passes with no `MISE_ENV`, at 26.0 from `mise.toml`.
   - The `build-id` step's log prints a 14-digit ID equal to
     `TZ=UTC git log -1 --date=format-local:%Y%m%d%H%M%S --format=%cd` of
     the pushed commit.
   - The `build` job's Lake restore step logs a cache hit on the
     `…-<sha>` key.
   - "App check" ends `app-check: ok`.
   - The run's Artifacts list `Leanmacs-dmg`. Download it and unzip it: it
     holds `Leanmacs-<that ID>.dmg`. Open the `.dmg`: it shows
     `Leanmacs.app`, `Applications`, `LICENSE` and `README.txt`.
6. **Install from that .dmg.** Follow `README.txt`'s first-launch steps.
   Then `/Applications/Leanmacs.app/Contents/MacOS/editor --version`
   prints `Leanmacs 0.1.0`, `build <the ID>` and
   `commit <git rev-parse origin/main>`.
7. **Push a throwaway branch.** `build-id` and `build` are skipped, and the
   gate still runs. Delete the branch.
8. **Open the nightly once on a macOS 26 Mac** (the minimum was lowered
   to 26.0; see "Deployment target" above). The window opens and edits a
   file. If not, file a bug.

### After the nightly release lands

9. **Push to `main`.** The "CI" run shows `release / publish` green after
   `build / build` and `secrets-scan`. Releases shows the prerelease
   "Leanmacs nightly" (not Latest), tagged `nightly`, holding
   `Leanmacs.dmg`, `Leanmacs-<id>.dmg`, `Leanmacs.dmg.sha256` and
   `build.json`. Then:
   - `git ls-remote origin refs/tags/nightly` prints the pushed SHA.
   - `curl -L https://github.com/leanmacs/leanmacs/releases/download/nightly/build.json`
     shows that ID and commit.
   - `curl -LO …/nightly/Leanmacs.dmg -LO …/nightly/Leanmacs.dmg.sha256 &&
     shasum -a 256 -c Leanmacs.dmg.sha256` passes.
   - The release body names the ID, the commit and the date, and gives the
     "Open Anyway" steps.
   - After a second push, the tag and all four assets move, and the first
     build's ID copy remains.
10. **Push a throwaway branch and open a pull request from it.** `release`
    is skipped in both runs. `git ls-remote origin refs/tags/nightly` and
    the assets' `updated_at` (`gh release view nightly --json assets`) are
    unchanged. Delete the branch.
11. **A failing release leaves the old nightly whole (optional, owner fork
    only).** This is confirmed offline: the `nightly` module's tests show
    that a mismatched stamp is refused before any `gh` call, and the
    workflow lint's `release-steps` and `release-token` rules hold that
    the publish is the last step and the only one with a token. To also
    see it live, do this in an owner fork with Actions on, never in
    leanmacs/leanmacs. The mutation must keep the gate green, or `release`
    is skipped and the check proves nothing:
    - In the fork's `ci.yml`, change the `release` job's `commit:` input
      to another valid 40-hex SHA (any other commit on `main`).
    - Drop `workflow-lint` from the fork's `[tasks.ci].depends`, since the
      `release-gating` rule would otherwise fail the gate.
    - Pass: in `release / publish`, "Prepare the nightly" ran and failed
      with a mismatch naming both commits; "Publish the nightly" did not
      run; the fork's `nightly` tag and assets are as before. A run where
      `release` was skipped does not count.
12. **Repository settings.** If "immutable releases" is ever turned on,
    the asset deletes and renames fail, so leave it off for the `nightly`
    prerelease. No tag ruleset may protect `nightly`: one would block the
    tag's move.

### After the download page lands

13. **Before pushing:** `mise run infra-check`; then the one-time manual
    import of the `github-pages` environment's `main` policy
    ([`infra/github/README.md`](../../infra/github/README.md), "Taking over
    `github-pages`"); then `mise run infra-plan`, which must show only
    `github_repository_environment.github_pages` imported and **0 to add,
    0 to change, 0 to destroy** (a change means a declared value differs
    from the live one: align it); then `mise run infra-apply`.
14. **Push to `main`.** `release / publish` and then `release / pages` are
    green, and `pages` shows the `github-pages` deployment URL.
15. **The page names the release's build.** These print the same 14
    digits (allow up to 10 minutes for the Pages CDN):

    ```sh
    curl -sL https://github.com/leanmacs/leanmacs/releases/download/nightly/build.json | grep build_id
    curl -s https://leanmacs.github.io/leanmacs/ | grep -o 'id="build-id">[0-9]*'
    ```
16. **On a Mac,** open the page, click Download, install with the page's
    steps, and `/Applications/Leanmacs.app/Contents/MacOS/editor
    --version` prints that build ID. On a phone, the page has no sideways
    scroll.
17. **Push a branch:** `release`, and so `pages`, is skipped, and the page
    is unchanged.

## The workflow lint

```sh
mise run workflow-lint
```

Part of the gate (`mise run ci`), offline, and it reads no git history, so
it runs the same in `linux-ci`'s copy of the checkout. It runs, in order:

1. [actionlint](https://github.com/rhysd/actionlint) over
   `.github/workflows/*.yml`: syntax, expressions, runner labels, and a
   local reusable workflow's `with:` against its inputs. Its
   shellcheck and pyflakes passes are off, because neither is pinned here.
2. [zizmor](https://docs.zizmor.sh) over `.github/workflows`, offline,
   with `.github/zizmor.yml`, which requires every `uses:`, GitHub's own
   actions included, to name a full commit SHA. A finding fails the gate;
   fix the workflow. An ignore that is truly needed goes inline as
   `# zizmor: ignore[<rule>]`, with a comment saying why.
3. `tools/workflow-check.sh` on each file in `.github/workflows`, written
   with yq: what this repository needs of the workflows, that neither tool
   knows. The rules are picked by the file's base name, and a workflow
   file with no rules fails the rule `workflows`, so a new one cannot go
   unchecked.
   - On every file: that nothing continues on error, the mise env of each
     job (a job that calls a reusable workflow cannot set one and is
     skipped), that every `uses:` is a full SHA with a `# v…` tag comment,
     that every cache saves from `main` only and saves the key a restore
     uses, that mise-action's version is the Dockerfile's `MISE_VERSION`,
     and that every third-party action is on the allowlist (below).
   - On `ci.yml`: the triggers, the two legs and `fail-fast: false`, the
     single "Gate" step, the concurrency group, Lake's key, that `ci` uses
     rust-cache, that the `ci` job's mise-action `install_args` names every
     `mise.toml` tool the gate runs (with `MISE_AUTO_INSTALL` false, a tool
     left out is missing on the runner; the tools the gate never runs are
     named in the check), the `secrets-scan` job, that
     `tools/ci/install-elan.sh` pins the Dockerfile's elan,
     `build-gating`: `build-id` and `build` on `main` pushes only, after
     the gate, `build` calling `build.yml` with the run's ID and commit,
     `release-gating` (`release` on `main` pushes only, after `ci`,
     `build-id`, `build` and `secrets-scan`, calling `release.yml` with
     the ID and commit, with exactly `contents: write`, `pages: write` and
     `id-token: write`), `release-concurrency`
     (the group `nightly-release`, never cancelled) and `write-scope` (the
     workflow's token reads contents only, and no job but `release` names
     a write scope).
   - On `build.yml`: `build-trigger` (`workflow_call` alone, its three
     inputs required strings), `build-job` (one job on `macos-26`, a leg of
     `ci.yml`'s matrix, stamped from the inputs, checking out `ref`),
     `build-steps` (app-check, dmg, dmg-check in that order and
     unconditional, then the upload, which fails with no `.dmg`) and
     `build-cache` (no save, and `ci.yml`'s Lake and elan keys).
   - On `release.yml`: `release-trigger` (`workflow_call` alone, its three
     inputs required strings), `release-job` (exactly the jobs `publish`
     and `pages`; `publish` on `macos-26`, top-level permissions `{}` and
     its exactly
     `contents: write`, stamped from the inputs, one checkout of `ref`,
     every checkout without persisted credentials), `release-steps` (the
     download of `Leanmacs-dmg`, then `mise run nightly`, and last, once,
     the publish command; no `if:`; no step running `gh release`, `gh
     api`, `git push` or `git tag`), `release-token` (exactly one step has
     a token in its env, the one running the publish command; none in the
     job's or workflow's env; no other value names `github.token` or
     `secrets.`), `release-cache` (no rust-cache or `actions/cache`
     step), `release-page` (one render of `target/nightly/build.json` into
     `target/site` after `mise run nightly`, and one
     `actions/upload-pages-artifact` of `target/site` after it),
     `pages-job` (`pages` needs exactly `publish`, has no `if:`, runs on a
     leg of `ci.yml`'s matrix with exactly `pages: write` and
     `id-token: write` in the `github-pages` environment, and has one
     step, `actions/deploy-pages` with `id: deployment`) and
     `pages-concurrency` (the group `pages`, never cancelled).

   Each failure names its rule; the script's header lists them.
4. `tools/workflow-lint-probe.sh`: zizmor must reject
   `tests/workflow-lint/tag-pinned.yml`, a tag-pinned action, with
   `unpinned-uses`; and the check must reject copies of `ci.yml`,
   `build.yml` and `release.yml` (or of a file it reads) broken one rule
   at a time, every
   rule at least once, naming that rule and no other, and pass the
   unbroken copies. A new rule in the check needs its mutation in the
   probe, and a new workflow file its rules in the check. A config or a
   check that stopped checking fails here.

actionlint, zizmor and yq are pinned in `mise.toml`, installed by mise's
aqua backend as prebuilt, checksum-checked binaries. Pin a release that
is at least two weeks old.

## Adding or bumping an action

Every `uses:` names a full commit SHA, with the release tag in a trailing
comment:

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

To bump one, resolve the tag's commit (for an annotated tag, the `^{}`
line is the commit; use that one):

```sh
git ls-remote https://github.com/<owner>/<repo> 'refs/tags/<tag>' 'refs/tags/<tag>^{}'
```

GitHub's Actions settings allow only GitHub's own actions and the
third-party patterns in `infra/github/actions.tf`'s `patterns_allowed`
(today `Swatinem/rust-cache@*` and `jdx/mise-action@*`). A new third-party
action needs its `<owner>/<repo>@*` pattern there, applied with `mise run
infra-apply` **before** the workflow that uses it is pushed, or that
workflow's jobs fail at startup. `tools/workflow-check.sh` fails on a
third-party action with no pattern there, so the gate catches it before
the push ([`publishing.md`](publishing.md), "The repository's settings as
code").
