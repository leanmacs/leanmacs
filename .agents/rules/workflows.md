# The CI workflows

What this repository needs of `.github/workflows/`. actionlint checks that
a workflow is valid and zizmor that it is safe (`mise run workflow-lint`,
part of the gate); zizmor's `unpinned-uses` holds every `uses:` to a full
commit SHA and its `artipacked` holds checkouts to dropping their
credentials. Neither knows the rules below, and no gate step checks them
(`gates.md`): review holds a change to a workflow, and to the files named
here that a workflow must agree with, to them.
`docs/dev-practices/ci.md` says what each workflow does and why.

## Every workflow

- No job or step sets `continue-on-error`: a red leg fails the workflow.
- Every job sets `MISE_AUTO_INSTALL: "false"`, but a job that calls a
  reusable workflow, which cannot set `env`.
- Every SHA-pinned `uses:` carries its release tag in a trailing
  `# v…` comment.
- No combined `actions/cache`: caches are restored with
  `actions/cache/restore` and saved with `actions/cache/save`, and every
  save is guarded to `main`. Every save's `key` and `path` are those of a
  restore in the same job.
- `Swatinem/rust-cache` saves from `main` only (`save-if`), and so does
  `jdx/mise-action` (`cache_save`).
- `jdx/mise-action`'s `version` equals `MISE_VERSION` in
  `tools/linux/Dockerfile`, and `ELAN_VERSION` in
  `tools/ci/install-elan.sh` equals the Dockerfile's.
- Every third-party action has its pattern in `infra/github/actions.tf`'s
  `patterns_allowed`.

## ci.yml

- It runs on every push to any branch and every pull request, with no
  path or branch filter.
- The `ci` job's legs are exactly `macos-26` and `ubuntu-24.04`, with
  `fail-fast: false`, and it runs `mise run ci` in exactly one step, with
  no `if:`.
- The concurrency group is per workflow and ref, and a run on `main` is
  never cancelled in progress.
- Lake's cache key hashes `lean/lean-toolchain` and
  `lean/lake-manifest.json` and ends in the commit; its `restore-keys` is
  that key without the commit.
- The `ci` job's mise-action `install_args` names exactly the
  `mise.toml` `[tools]` that `mise run ci` runs: with
  `MISE_AUTO_INSTALL` false, a tool it leaves out is missing.
- The `secrets-scan` job checks out the full history (`fetch-depth: 0`)
  and runs `mise run secrets-scan`.
- A `build-id` job that needs exactly `ci`, and a `build` job that needs
  `ci` and `build-id`, both on pushes to `main` only; `build` calls
  build.yml with the build ID, and `github.sha` as commit and ref, with
  the token reading contents only.
- A `release` job that needs `ci`, `build-id`, `build` and
  `secrets-scan`, on pushes to `main` only, calling release.yml with the
  build ID and `github.sha` as commit and ref, with permissions exactly
  `contents: write`, `pages: write` and `id-token: write`; its
  concurrency is the group `nightly-release`, never cancelled in progress.
- The top-level permissions are exactly `contents: read`, and no job but
  `release` names a write scope.

## build.yml and release.yml

- Each is triggered by `workflow_call` alone, with exactly the inputs
  `build-id`, `commit` and `ref`, each a required string.
- Each job runs on a leg of ci.yml's matrix, with `LEANMACS_BUILD_ID` and
  `LEANMACS_COMMIT` from the inputs and no `MISE_ENV`, and checks out the
  `ref` input.
- build.yml has one job, `build`, which builds the app (`mise run app`),
  packs it (`mise run dmg`) and checks the image (`mise run dmg-check`),
  each in one unconditional step in that order, then uploads
  `dist/*.dmg`, failing when there is none. It saves no cache, and its
  Lake and elan restores have ci.yml's keys.
- release.yml has two jobs, `publish` and `pages`. The top-level
  permissions are `{}`; `publish`'s are exactly `contents: write`, and
  `pages`' exactly `pages: write` and `id-token: write`.
- `publish` downloads the image, prepares the nightly (`mise run
  nightly`), renders the page from its `build.json` and uploads it as the
  Pages artifact, and publishes last. No step has an `if:`, and none runs
  `gh release`, `gh api`, `git push` or `git tag`.
- The token is named in the publish step's `env` alone; no other value
  names `github.token` or `secrets.`. `publish` uses no cache but
  mise-action's.
- `pages` needs exactly `publish`, has no `if:`, runs in the
  `github-pages` environment with the concurrency group `pages`, never
  cancelled in progress, and has one step, `actions/deploy-pages`.

## stress.yml

- It runs on `workflow_dispatch` alone, with the one input `rounds`.
- The `stress` job's matrix is exactly ci.yml's legs times the shards
  1 to 5, with `fail-fast: false`. It runs `mise run ci` in one step with
  no `if:`, then `tools/stress.sh` on its rounds alone, naming no suite,
  and uploads the shard's summary and its logs alone.
