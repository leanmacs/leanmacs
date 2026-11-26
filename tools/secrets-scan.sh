#!/bin/sh
# The secret scan's gitleaks passes, defined here and nowhere else:
#
#   sh tools/secrets-scan.sh <repo>
#
# `mise run secrets-scan` runs this on `.` (docs/dev-practices/
# publishing.md, "The secret scan").
#
# Each pass is gitleaks (pinned in mise.toml) with this repository's
# `.gitleaks.toml` and `.gitleaksignore`, output redacted, over <repo>:
#
#   plain       every commit reachable from the local `main`;
#   merges      every first-parent commit of `main`, each merge diffed
#               against its first parent (a secret typed into a conflict
#               resolution is in no parent's diff, so `plain` misses it);
#   pre-commit  the unstaged changes to tracked files;
#   staged      the staged changes.
#
# Every pass runs, even after one fails. The script exits 0 if all are
# clean and 1 if any failed (a finding, or a gitleaks error), naming them.
set -eu

if [ $# -ne 1 ]; then
  printf 'usage: sh tools/secrets-scan.sh <repo>\n' >&2
  exit 2
fi
repo=$1
root=$(cd "$(dirname "$0")/.." && pwd)
failed=

# pass <label> <gitleaks git flags...>
pass() {
  label=$1
  shift
  set -- --no-banner --redact \
    --config "$root/.gitleaks.toml" \
    --gitleaks-ignore-path "$root/.gitleaksignore" \
    "$@"
  status=0
  printf 'secrets-scan: %s pass\n' "$label" >&2
  gitleaks git "$@" "$repo" || status=$?
  if [ "$status" -ne 0 ]; then
    failed="$failed $label"
  fi
}

pass plain --log-opts=main
pass merges '--log-opts=-m --first-parent main'
pass pre-commit --pre-commit
pass staged --staged

if [ -n "$failed" ]; then
  printf 'secrets-scan: failed:%s\n' "$failed" >&2
  exit 1
fi
