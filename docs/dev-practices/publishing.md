# Publishing

The repository, `leanmacs/leanmacs` on GitHub, is made public by one
command the owner runs, `mise run infra-apply`. This document says what the
public repository holds and what it leaves out, how its history is checked
for secrets before that and after, and where its settings are kept as
code.

## What the public repository holds

Everything committed: every commit reachable from `main`. `main` is the
only branch and there are no tags on GitHub, so the scan of `main` below
covers all of it.

### `research_notes/` and `reports/` stay local

The research behind the design (the agent-workflow research pass and its
report, the Lean host spike, the Lean embedding experiments, the survey of
Rust editors) lives in `research_notes/` and `reports/` on the owner's
machine. Both are in `.gitignore` and have never been committed, so going
public does not publish them, and they stay unpublished:

- They hold absolute paths on the owner's machine and to uncommitted
  worktrees, and references into the owner's private plan data and a
  private project. Publishing them would mean scrubbing those first.
- They are working notes, and the report itself flags some of its sources
  as weak (read only from search summaries). The conclusions are in
  [`docs/design/`](../design/README.md), which says where a choice rests on
  the notes and when the source was weak.
- Nothing in the build, the tests or the documents' links needs them.

The cost: a reader of the public repository cannot follow a design
document's citation into the notes. The design documents say so where they
cite them.

To reverse this (the owner's call): remove `/research_notes` and
`/reports` from `.gitignore`, scrub the machine paths and the private
references, `git add` them, run `mise run secrets-scan` (its `--staged`
pass covers files once added), and commit.

## The secret scan

```sh
mise run secrets-scan
```

[gitleaks](https://github.com/gitleaks/gitleaks), pinned in `mise.toml`,
with its default rules (`.gitleaks.toml` changes none) and the reviewed
exceptions in `.gitleaksignore`. Every pass prints its findings redacted.
The four passes are defined in one place, `tools/secrets-scan.sh <repo>`,
which runs them all and fails if any fails:

1. Every commit reachable from the local `main` (`--log-opts=main`).
2. Every first-parent commit of `main`, with each merge diffed against its
   first parent (`--log-opts="-m --first-parent main"`). A plain `git log`
   shows no diff for a merge, so a secret typed into a conflict resolution
   is caught only here.
3. The unstaged changes to tracked files (`--pre-commit`).
4. The staged changes (`--staged`).

The task first runs `tools/secrets-scan-probe.sh`: in a throwaway
repository it plants a GitHub token-shaped string (made at random on each
run, never written in the script) where each of the four passes looks, and
only there, runs `tools/secrets-scan.sh` on it, and requires each pass to
report its token. A broken config, a wrong flag or a dropped pass in the
script fails here rather than passing silently. Then it runs
`tools/secrets-scan.sh .` on this repository.

Untracked files that are not staged are not scanned; stage them first.

`mise run infra-apply` runs it first, so the repository is never made
public, or its settings changed, past a red scan.

It is not part of the gate (`mise run ci`) or the hk hooks: `mise run
linux-ci` runs the gate in a copy of the checkout with no history, where a
history scan has nothing to read. A CI job that runs it must check out the
full history (no shallow clone) and have a local `main` branch.

The scan of `main` before going public, on 2026-11-17 (1092 commits, 10 of
them merges, with gitleaks 8.30.1), found nothing, so `.gitleaksignore`
holds no fingerprints; its header records that review.

### When it finds something

- **A real credential, or one that might be:** stop. Do not commit around
  it, add it to `.gitleaksignore`, or rewrite history to remove it. Tell the
  owner the rule, the commit and the file (never the value; the output is
  redacted). The credential must be revoked whatever happens to the
  history, and rewriting `main`'s history is the owner's decision alone.
- **Shown not to be a credential** (a test fixture, a hash, generated
  data): add the fingerprint gitleaks printed
  (`<commit>:<file>:<rule>:<line>`) to `.gitleaksignore`, under a `#` line
  saying what the matched text is and why it is not a secret. Never add a
  path- or pattern-wide allowlist to `.gitleaks.toml`: it would hide every
  later finding that matches, not just the one reviewed.

## The repository's settings as code

The repository's visibility, merge settings, secret scanning and push
protection, the ruleset that refuses a force-push to `main` or its
deletion, what Actions may run (SHA-pinned, from an allowlist) and what
their token may do, and Pages built from Actions are declared with
OpenTofu in [`infra/github/`](../../infra/github/README.md), which also
holds the owner's one-time setup and what to do after a lost state or
passphrase.

```sh
mise run infra-check   # offline: fmt, validate, mocked-provider tests, encryption guard
```

`infra-check` needs no credentials and no GitHub API, so anyone can run it
at any time; run it after any change under `infra/`. Like `secrets-scan`,
it is outside the gate.

Changing the live repository is the owner's alone: read
`mise run infra-plan`, then run `mise run infra-apply`, which runs
`secrets-scan` first and asks before applying. Both use the owner's `gh`
login and 1Password, and nothing else in the repository calls them. The
first apply, which makes the repository public, is two steps
(`infra/github/README.md`, "The first apply").
