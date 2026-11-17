# CI

`.github/workflows/ci.yml` runs [the gate](the-gate.md) on GitHub Actions
on every push to any branch and on every pull request. Tags are not pushed,
so a tag push runs nothing. On a push to `main`, once the gate has passed
on both legs, it also builds the nightly's `.dmg` and uploads it as a
workflow artifact (`.github/workflows/build.yml`). It publishes no release
yet: the release and its page come in later phases.

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
bundle's `LSMinimumSystemVersion`. There is no CI profile of `mise.toml`
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
Its output `id` is the run's one build ID, so the `.dmg` and, in later
phases, the release and its page all name the same build, as in ev-nova.

### `build`: the .dmg

On a push to `main` only, after both legs of `ci` and `build-id` (`needs:
[ci, build-id]`), with a token that reads contents only. It calls the
reusable workflow `.github/workflows/build.yml` with the inputs
`build-id` (`build-id`'s output), `commit` and `ref` (both `github.sha`).
`concurrency` never cancels a run on `main` in progress, so a build is
never cut off halfway. Its `uses:` carries an inline
`# zizmor: ignore[self-repository]`: zizmor asks for the newer
`$/.github/workflows/…` form, which the pinned actionlint refuses, and
`./` names this repository's file at the commit being run either way. It does not wait for `secrets-scan`: the `.dmg`
holds no history, and the release that publishes it is where to add that.

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
there): the release jobs later added to `main`'s runs must never be cut off
halfway.

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
and saves neither: it has no `actions/cache/save` step, because
`lean/.lake` there holds the bundle, about 600 MB, which must not enter
the cache. Its rust-cache entry is its own (rust-cache keys on the job),
saved from `main` only, as is its mise-action's.

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
     `tools/ci/install-elan.sh` pins the Dockerfile's elan, and
     `build-gating`: `build-id` and `build` on `main` pushes only, after
     the gate, `build` calling `build.yml` with the run's ID and commit.
   - On `build.yml`: `build-trigger` (`workflow_call` alone, its three
     inputs required strings), `build-job` (one job on `macos-26`, a leg of
     `ci.yml`'s matrix, stamped from the inputs, checking out `ref`),
     `build-steps` (app-check, dmg, dmg-check in that order and
     unconditional, then the upload, which fails with no `.dmg`) and
     `build-cache` (no save, and `ci.yml`'s Lake and elan keys).

   Each failure names its rule; the script's header lists them.
4. `tools/workflow-lint-probe.sh`: zizmor must reject
   `tests/workflow-lint/tag-pinned.yml`, a tag-pinned action, with
   `unpinned-uses`; and the check must reject copies of `ci.yml` and
   `build.yml` (or of a file it reads) broken one rule at a time, every
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
