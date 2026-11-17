# infra/github

OpenTofu configuration for the `leanmacs/leanmacs` GitHub repository's
security-relevant settings: its visibility, its merge and feature settings,
secret scanning, the `main` branch ruleset, what Actions may run and what
their token may do, and GitHub Pages. Cosmetic settings (description,
homepage, topics) are out of scope and ignored. Plan and apply run only on
the owner's machine, never in CI. Why the repository is public and what it
holds is in
[`docs/dev-practices/publishing.md`](../../docs/dev-practices/publishing.md).

| File | Manages |
|---|---|
| `repository.tf` | `github_repository.leanmacs`: visibility, features, merge settings, secret scanning and push protection (imported) |
| `rulesets.tf` | `github_repository_ruleset.main`, `protect-main` (created) |
| `actions.tf` | `github_actions_repository_permissions.leanmacs` and `github_workflow_repository_permissions.leanmacs` (imported) |
| `pages.tf` | `github_repository_pages.leanmacs` (created) |
| `versions.tf` | The OpenTofu and provider pins, and the state encryption |

## One-time setup

1. `mise install` in the checkout (`mise.toml` pins OpenTofu and gitleaks).
2. `gh auth login` as an owner of the `leanmacs` organisation or an admin
   of the repository. The `infra-*` tasks pass `gh auth token` to the
   GitHub provider as `GITHUB_TOKEN`; no PAT is stored.
3. The 1Password desktop app, with the CLI integration enabled (Settings >
   Developer > "Integrate with 1Password CLI"), and the `op` CLI on `PATH`.
4. A 1Password vault named `leanmacs-ci` holding one item:

   | Item (title) | Category | Field | Feeds |
   |---|---|---|---|
   | `opentofu-state-encryption` | Password | `password`: random, at least 16 characters (`pbkdf2`'s minimum) | the state passphrase, through `op.env` |

   This root manages no secrets, so nothing else is read from 1Password.

## The plan/apply loop

```sh
mise run infra-plan    # read the diff
mise run infra-apply   # runs secrets-scan, then applies: check the summary, type `yes`
```

Each runs `tofu init` and then `plan` or `apply` inside one
`op run --env-file=infra/github/op.env`, which sets
`TF_VAR_state_passphrase` from
`op://leanmacs-ci/opentofu-state-encryption/password` for that child
process only. `infra-apply` first runs `mise run secrets-scan` and stops if
it fails. Nothing else in the repository calls `op` or `gh`: `mise run ci`,
`mise run infra-check` and the hk hooks never touch 1Password, GitHub or
the state.

Never run `tofu destroy`. `prevent_destroy` is set on the repository, and
apply never runs with `-auto-approve` against a plan that changes anything.

### The first apply

Every value in `repository.tf` and `actions.tf` is the live value read on
2026-11-17, except those changed on purpose. The first apply is two steps,
because of how the provider orders its requests.

`resourceGithubRepositoryUpdate` in provider 6.13.0
(`github/resource_github_repository.go`) clears the visibility from the
request, sends everything else, `security_and_analysis` included, as one
`PATCH /repos/leanmacs/leanmacs`, and returns at once if that fails. Only
after it succeeds does it send a second `PATCH` with the visibility. Secret
scanning and push protection may be refused on a private repository on the
free plan, and if the first request is refused the visibility never
changes, so the same apply fails the same way every time. The first step
therefore leaves the block out:

```sh
TF_VAR_enable_security_and_analysis=false mise run infra-plan
TF_VAR_enable_security_and_analysis=false mise run infra-apply
```

With the variable false, `repository.tf` declares no
`security_and_analysis` block. The provider marks the attribute computed,
so its absence plans no change and the first request carries none. This
plan should read:

- `github_repository.leanmacs`: imported and updated in place, visibility
  `private` to `public`, and nothing in `security_and_analysis`.
- `github_actions_repository_permissions.leanmacs`: imported and updated
  in place, from all actions allowed without SHA pinning to the allowlist
  below with `sha_pinning_required`.
- `github_workflow_repository_permissions.leanmacs`: imported, no change.
- `github_repository_ruleset.main` and `github_repository_pages.leanmacs`:
  created. Neither is available on a private repository on the free plan
  (the API answers 403), so both refer to the repository resource, which
  orders them after the change of visibility in the same apply.

Anything else in the plan is a reason to stop and read before typing
`yes`.

The second step is the ordinary loop, with the variable at its default
(`true`), on the now-public repository:

```sh
mise run infra-plan    # only security_and_analysis changes on github_repository.leanmacs
mise run infra-apply
```

Its plan should change only `security_and_analysis` on
`github_repository.leanmacs`, to secret scanning and push protection
`enabled`; after it, `mise run infra-plan`
shows no changes. Every later apply runs with the default, so never set the
variable false again: it is not a way to turn the two off, since a block
left out plans no change and the provider would leave them enabled.

## Actions settings

| Setting | Managed by | Value |
|---|---|---|
| Actions enabled | `github_actions_repository_permissions.enabled` | `true` |
| Allowed actions | `allowed_actions` and `allowed_actions_config` | `selected`: GitHub-owned, no verified creators, `jdx/mise-action@*` |
| SHA pinning | `sha_pinning_required` | `true`: every external `uses:` is a full commit SHA, with the release tag in a trailing comment |
| Default `GITHUB_TOKEN` permissions | `github_workflow_repository_permissions.default_workflow_permissions` | `read` |
| Actions may approve PRs | `can_approve_pull_request_reviews` | `false` |
| Secret scanning | `github_repository.security_and_analysis.secret_scanning` | `enabled` |
| Push protection | `github_repository.security_and_analysis.secret_scanning_push_protection` | `enabled` |

**The allowlist rule.** A workflow may use only GitHub-owned actions and
the `patterns_allowed` entries in `actions.tf`. Before a workflow change
adds a third-party action, add its pattern there and apply it, or the jobs
that use it fail at startup. A composite action's own nested `uses:` count
too. To bump a pinned action, resolve the new tag with `git ls-remote` (the
peeled `^{}` commit for an annotated tag) and change the SHA and the
comment together.

## Pages

`pages.tf` enables GitHub Pages with `build_type = "workflow"` and no
`source` branch: the site is deployed from an Actions artifact, so no
branch holds built files. It is a resource of its own because provider
6.13.0 deprecates the `pages` block on `github_repository`. No custom
domain. Enabling Pages makes GitHub create the `github-pages` environment,
which this config does not manage.

## Main branch ruleset

`rulesets.tf` declares one ruleset, `protect-main`, active on
`refs/heads/main` (named explicitly, not `~DEFAULT_BRANCH`, so renaming the
default branch can't move it). It has two rules: `non_fast_forward` (no
force-push) and `deletion`. Every rule that would refuse a direct push is
left out on purpose, because landing pushes straight to `main`:

| Rule left out | Why |
|---|---|
| `required_linear_history` | Landing may land a merge commit ([`AGENTS.md`](../../AGENTS.md), "Landing work on `main`") |
| `pull_request` | The owner lands without PRs |
| `required_status_checks` | A landing push is the commit's first appearance on GitHub, so it has no checks yet; the gate runs locally (`mise run ci`) |
| `update`, `creation`, `required_signatures` | `update` refuses every push, `main` already exists, and commits here aren't signed |

**Bypass.** Only the repository admin role (`RepositoryRole`, id 5), in
`pull_request` mode, so direct pushes stay enforced for everyone, the
admin included. In an emergency, edit or disable the ruleset in the GitHub
UI (admins always can), then fix the config and apply.

**Probing it.** Never test against `main`. Add a throwaway ref such as
`refs/heads/ruleset-probe/force-push` to `include` and apply; push
`main`'s tip there; check that a force-push and a delete of that ref are
both refused (`GH013`); remove it from `include` and apply; only then
delete the ref.

## State

The state is local (`terraform.tfstate`, gitignored) and encrypted with
OpenTofu's native encryption: a `pbkdf2` key from the passphrase and the
`aes_gcm` method, for state and plan files, with `enforced = true` and no
`fallback`, so an unencrypted state is refused, not read.
`.terraform.lock.hcl` is committed, for macOS on arm64 and Linux on amd64
and arm64.

- **Lost state:** the `import` blocks adopt the repository and the two
  Actions resources again on the next apply, with no change. The ruleset
  and Pages have no `import` block (they were created by this config):
  import them first, inside the same `op run` and `GITHUB_TOKEN` wrapping
  as the tasks, or the apply tries to create them again:

  ```sh
  gh api repos/leanmacs/leanmacs/rulesets --jq '.[] | {id, name}'
  tofu -chdir=infra/github import github_repository_ruleset.main leanmacs:<id>
  tofu -chdir=infra/github import github_repository_pages.leanmacs leanmacs
  ```

  (Check the Pages import ID against the provider's `github_repository_pages`
  documentation for 6.13.0 before running it.)
- **Lost passphrase:** delete `terraform.tfstate` and handle it as a lost
  state.
- **Rotating the passphrase:** `pbkdf2` stores its salt in the state under
  the key provider's label, and the encryption block takes only static
  references, so a rotation is two applies under temporary edits, each
  planning no change: keep the old passphrase in a second 1Password item,
  add a `next` key provider on the new passphrase with the old one as
  `fallback` and apply, then point `main` at the new passphrase with `next`
  as `fallback` and apply again, then restore `versions.tf` and `op.env`
  from git and check that `mise run infra-plan` reports no changes. ev-nova's
  `infra/github/README.md`, "Rotating the passphrase", has the blocks to
  paste. `mise run infra-check` fails while the temporary blocks are in
  place, so never commit them.

## Checks

`mise run infra-check` runs `tofu fmt -check`, `tofu init -backend=false
-lockfile=readonly`, `tofu validate`, `tofu test` with a mocked provider
(`tests/*.tftest.hcl`), and `infra/check-encryption.sh infra/github`. It
needs no credentials and no GitHub API, only the OpenTofu registry the
first time, to download the provider. It is not part of `mise run ci` or
the hk hooks; run it after any change here.

`tofu test` plans each file's runs against the mock and asserts what this
config must hold: the repository public, with its live settings and secret
scanning; the ruleset's target, its two rules, the rules left out and its
bypass; the Actions allowlist, SHA pinning and the read-only token; Pages
built from Actions. It can't plan an `import` block, even against a mock
(OpenTofu 1.13 panics), so the tests set `import_existing = false`, which
empties the imports' `for_each`. Nothing else sets that variable.

`tofu test` can't see the encryption block either, so
`infra/check-encryption.sh` guards it by behaviour, in a temporary
directory with copies of the `*.tf` files: the config must refuse a
planted plaintext state and plaintext plan ("unencrypted payload"), and an
override adding an `unencrypted` fallback to the `state` block, then to the
`plan` block, must be refused ("enforced flag is set"). It never reads the
real state.

## Adding a resource

For a setting that already exists on GitHub, add an `import` block with
the same `for_each = var.import_existing ? ...` guard and declare the
resource with today's live values, so the plan reads only imports; only
then change values on purpose. A resource that doesn't exist yet is
created, with no `import` block; add it to "Lost state" above. Add a
mocked-provider test for what it must hold, and see it fail first.

After changing a provider pin, regenerate and commit the lock file:

```sh
tofu -chdir=infra/github providers lock -platform=darwin_arm64 -platform=linux_amd64 -platform=linux_arm64
```
