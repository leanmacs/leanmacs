#!/bin/sh
# Proves that `mise run secrets-scan` catches what it must, so a broken
# config or a wrong flag cannot pass silently:
#
#   sh tools/secrets-scan-probe.sh    # run first by `mise run secrets-scan`
#
# In a throwaway repository under `mktemp -d` it plants four GitHub
# token-shaped strings, each where exactly one of the task's passes looks:
#
# (a) in an ordinary commit on `main`: the plain pass (`--log-opts=main`);
# (b) only in a merge commit's conflict resolution, in neither parent: the
#     `-m --first-parent` pass, which diffs a merge against its first
#     parent. The plain pass must miss it, which is why that pass exists;
# (c) staged and not committed: the `--staged` pass;
# (d) in an unstaged change to a tracked file: the `--pre-commit` pass.
#
# It runs gitleaks with the same flags as the task, against this
# repository's `.gitleaks.toml` and `.gitleaksignore`, and requires each
# pass to exit 1 with a `github-pat` finding at the planted place, not just
# a non-zero exit. The tokens are made at run time from /dev/urandom and
# never written here, so scanning this repository does not flag this file.
# It needs no network and leaves nothing behind (docs/dev-practices/
# publishing.md, "The secret scan").
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The probe repository ignores the user's and the system's git config
# (signing, hooks, templates) and names its own author.
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_NOSYSTEM=1
GIT_AUTHOR_NAME=probe
GIT_AUTHOR_EMAIL=probe@example.invalid
GIT_COMMITTER_NAME=probe
GIT_COMMITTER_EMAIL=probe@example.invalid
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_AUTHOR_NAME \
  GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# token: a string of the shape gitleaks' `github-pat` rule matches, random
# on every run. tr reads a bounded 4 KiB (about 1000 alphanumerics), not
# /dev/urandom itself: where SIGPIPE is ignored, tr would never stop.
token() {
  printf 'ghp_%s' \
    "$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 36)"
}

repo="$work/repo"
git init -q -b main "$repo"
g() { git -C "$repo" "$@"; }

printf 'probe\n' >"$repo/README"
printf 'base\n' >"$repo/conflict.txt"
g add README conflict.txt
g commit -q -m initial

# (a) An ordinary commit on main.
printf 'TOKEN=%s\n' "$(token)" >"$repo/a.env"
g add a.env
g commit -q -m "plant (a)"
commit_a=$(g rev-parse HEAD)

# (b) Both sides change conflict.txt; the resolution is a third text, the
# token, so it appears only in the merge commit's diff.
g checkout -q -b side
printf 'side\n' >"$repo/conflict.txt"
g commit -q -am side
g checkout -q main
printf 'main\n' >"$repo/conflict.txt"
g commit -q -am main
if g merge -q --no-edit side >/dev/null 2>&1; then
  printf 'FAIL: the probe merge did not conflict\n' >&2
  exit 1
fi
printf 'TOKEN=%s\n' "$(token)" >"$repo/conflict.txt"
g add conflict.txt
g commit -q --no-edit
commit_b=$(g rev-parse HEAD)

# (c) Staged, not committed.
printf 'TOKEN=%s\n' "$(token)" >"$repo/c.env"
g add c.env

# (d) An unstaged change to a tracked file.
printf 'TOKEN=%s\n' "$(token)" >>"$repo/README"

# scan <label> <gitleaks git flags...>: run one pass; it must exit 1 and
# write its JSON report to $work/<label>.json. gitleaks also exits 1 on a
# fatal error (a missing config, a bad flag), which writes no report, so the
# report's existence is checked as well as the status.
scan() {
  label=$1
  shift
  status=0
  gitleaks git --no-banner --redact --log-level error \
    --config "$root/.gitleaks.toml" \
    --gitleaks-ignore-path "$root/.gitleaksignore" \
    --report-format json --report-path "$work/$label.json" \
    "$@" "$repo" >/dev/null 2>"$work/$label.err" || status=$?
  if [ "$status" -ne 1 ] || [ ! -f "$work/$label.json" ]; then
    printf 'FAIL: %s pass: gitleaks exited %s with no finding report\n' \
      "$label" "$status" >&2
    cat "$work/$label.err" >&2
    exit 1
  fi
}

# expect <label> <fingerprint prefix> <what>: the pass's report has a
# finding whose fingerprint (`[<commit>:]<file>:<rule>:<line>`) starts with
# the prefix, so the rule and the place are matched in the same finding.
expect() {
  if ! grep -q "\"Fingerprint\": *\"$2" "$work/$1.json"; then
    printf 'FAIL: %s pass: no finding %s... (%s)\n' "$1" "$2" "$3" >&2
    cat "$work/$1.json" >&2
    exit 1
  fi
  printf 'ok: %s pass catches %s\n' "$1" "$3"
}

scan plain --log-opts=main
expect plain "$commit_a:a.env:github-pat:" "(a), a token committed on main"
if grep -q "\"Commit\": *\"$commit_b\"" "$work/plain.json"; then
  printf 'FAIL: plain pass now sees merge diffs; revisit the -m pass\n' >&2
  exit 1
fi
printf 'ok: plain pass misses (b), so the merge pass is needed\n'

scan merges '--log-opts=-m --first-parent main'
expect merges "$commit_b:conflict.txt:github-pat:" \
  "(b), a token only in a merge's resolution"

scan staged --staged
expect staged "c.env:github-pat:" "(c), a staged token"

scan pre-commit --pre-commit
expect pre-commit "README:github-pat:" "(d), an unstaged token in a tracked file"
