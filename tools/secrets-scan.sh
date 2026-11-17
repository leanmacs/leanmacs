#!/bin/sh
# The secret scan's gitleaks passes, defined here and nowhere else:
#
#   sh tools/secrets-scan.sh <repo> [report-dir]
#
# `mise run secrets-scan` runs `tools/secrets-scan-probe.sh`, then this on
# `.`. The probe runs this same script on its throwaway repository, so the
# passes it proves are the passes the scan runs (docs/dev-practices/
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
#
# With <report-dir> (an existing directory), pass <label> writes its JSON
# report to <report-dir>/<label>.json, its output to <label>.out and its
# exit status to <label>.status, instead of printing. gitleaks writes no
# report when it fails before scanning (a missing config, a bad flag).
set -eu

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  printf 'usage: sh tools/secrets-scan.sh <repo> [report-dir]\n' >&2
  exit 2
fi
repo=$1
reports=${2:-}
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
  if [ -n "$reports" ]; then
    gitleaks git "$@" \
      --report-format json --report-path "$reports/$label.json" \
      "$repo" >"$reports/$label.out" 2>&1 || status=$?
    printf '%s\n' "$status" >"$reports/$label.status"
  else
    printf 'secrets-scan: %s pass\n' "$label" >&2
    gitleaks git "$@" "$repo" || status=$?
  fi
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
