# CI

`.github/workflows/ci.yml` runs [the gate](the-gate.md) on GitHub Actions
on every push to any branch and on every pull request. Tags are not pushed,
so a tag push runs nothing. It publishes nothing: the release jobs come
later and are not in it yet.

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
- `MISE_ENV: ci`, which reads [`mise.ci.toml`](../../mise.ci.toml) on top of
  `mise.toml`. Its one value lowers `MACOSX_DEPLOYMENT_TARGET` from 27.2 to
  26.0. The gate runs what it builds (the `cargo test` binaries, `ffi-test`,
  `bundle-test`, the headless runs), and dyld refuses to start a binary
  whose `minos` is newer than the running macOS. A value exported in the
  job's env would not help: mise's `[env]` overrides the process
  environment. Linux ignores the value. Nothing else sets `MISE_ENV`
  (`tools/linux/run.sh` does not).
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

**Open point for the release builds.** The gate on `macos-26` builds for
macOS 26.0. The app ships with a minimum of 27.2 (`mise.toml`,
`appMinimumSystemVersion` in `lean/lakefile.lean`, checked by `mise run
app-check`, which is outside the gate). Which host builds the shipped app,
and for which minimum, is decided with the release build jobs, not here.

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

The two `actions/cache/save` steps run after the gate, so they hold the
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

## The workflow lint

```sh
mise run workflow-lint
```

Part of the gate (`mise run ci`), offline, and it reads no git history, so
it runs the same in `linux-ci`'s copy of the checkout. It runs, in order:

1. [actionlint](https://github.com/rhysd/actionlint) over
   `.github/workflows/*.yml`: syntax, expressions, runner labels. Its
   shellcheck and pyflakes passes are off, because neither is pinned here.
2. [zizmor](https://docs.zizmor.sh) over `.github/workflows`, offline,
   with `.github/zizmor.yml`, which requires every `uses:`, GitHub's own
   actions included, to name a full commit SHA. A finding fails the gate;
   fix the workflow. An ignore that is truly needed goes inline as
   `# zizmor: ignore[<rule>]`, with a comment saying why.
3. `tools/workflow-check.sh .github/workflows/ci.yml`, written with yq: what
   this repository needs of the workflow, that neither tool knows. It
   checks the triggers, the two legs and `fail-fast: false`, that nothing
   continues on error, the single "Gate" step, the concurrency group, the
   mise env of each job, that every `uses:` is a full SHA with a `# v…` tag
   comment, that every cache saves from `main` only and saves the key a
   restore uses, Lake's key, that mise-action's version is the
   Dockerfile's `MISE_VERSION`, the `secrets-scan` job, that every
   third-party action is on the allowlist (below), and that
   `tools/ci/install-elan.sh` pins the Dockerfile's elan. Each failure
   names its rule; the script's header lists them.
4. `tools/workflow-lint-probe.sh`: zizmor must reject
   `tests/workflow-lint/tag-pinned.yml`, a tag-pinned action, with
   `unpinned-uses`; and the check must reject copies of `ci.yml` (or of
   a file it reads) broken one rule at a time, every rule at least once,
   naming that rule and no other, and pass the unbroken copy. A new rule
   in the check needs its mutation in the probe. A
   config or a check that stopped checking fails here.

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
