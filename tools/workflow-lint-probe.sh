#!/bin/sh
# Proves that `mise run workflow-lint` rejects what it must, so a broken
# config or a check that has stopped checking cannot pass silently:
#
#   sh tools/workflow-lint-probe.sh    # run last by `mise run workflow-lint`
#
# 1. zizmor, with .github/zizmor.yml, must exit non-zero on
#    tests/workflow-lint/tag-pinned.yml, whose one action is pinned by a tag,
#    with an `unpinned-uses` finding.
# 2. In a temporary directory it copies .github/workflows/ci.yml and breaks
#    one rule of tools/workflow-check.sh at a time with yq: cancel main's
#    runs in progress, drop the ubuntu-24.04 leg, let rust-cache save from
#    any ref, let Lake's cache save from any ref, pin checkout by a tag.
#    The check must exit 1 on each, naming that rule and no other. Then it
#    must pass on the unbroken copy, written by the same yq, so a mutation's
#    failure is the mutation's and not the rewrite's.
#
# The fixtures are outside .github/workflows/, so GitHub never runs them
# and the lint's own pass never reads them (tests/workflow-lint/README.md).
# It needs no network and leaves nothing behind (docs/dev-practices/ci.md).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=

fail() {
  printf 'workflow-lint-probe: FAIL: %s\n' "$1" >&2
  failed=1
}

# ---- 1. zizmor rejects a tag pin
status=0
zizmor --offline --config "$root/.github/zizmor.yml" \
  "$root/tests/workflow-lint/tag-pinned.yml" >"$work/zizmor.out" 2>&1 || status=$?
if [ "$status" -eq 0 ]; then
  fail 'zizmor passed tests/workflow-lint/tag-pinned.yml, a tag-pinned action'
elif ! grep -q 'unpinned-uses' "$work/zizmor.out"; then
  cat "$work/zizmor.out" >&2
  fail "zizmor failed on tag-pinned.yml (exit $status) without an unpinned-uses finding"
else
  printf 'workflow-lint-probe: zizmor rejects a tag-pinned action: pass\n' >&2
fi

# ---- 2. the structural check rejects each broken rule

# mutate <rule> <yq expression>: the check must fail on a copy of ci.yml
# with the expression applied, naming <rule> and no other rule.
mutate() {
  rule=$1
  wf="$work/$rule.yml"
  cp "$root/.github/workflows/ci.yml" "$wf"
  yq -i "$2" "$wf"
  status=0
  sh "$root/tools/workflow-check.sh" "$wf" >"$work/$rule.out" 2>&1 || status=$?
  named=$(sed -n 's/^workflow-check: \([a-z-]*\): .*/\1/p' "$work/$rule.out" | sort -u)
  if [ "$status" -ne 1 ]; then
    cat "$work/$rule.out" >&2
    fail "workflow-check exited $status, not 1, with $rule broken"
  elif [ "$named" != "$rule" ]; then
    cat "$work/$rule.out" >&2
    fail "with $rule broken, workflow-check named: $(printf '%s' "$named" | tr '\n' ' ')"
  else
    printf 'workflow-lint-probe: workflow-check rejects a broken %s: pass\n' "$rule" >&2
  fi
}

mutate concurrency '.concurrency["cancel-in-progress"] = true'
mutate matrix '.jobs.ci.strategy.matrix.os = ["macos-26"]'
mutate rust-cache 'del(.jobs.ci.steps[] | select(.uses // "" | test("^Swatinem/rust-cache@")) | .with["save-if"])'
mutate cache-save '(.jobs.ci.steps[] | select((.uses // "" | test("^actions/cache/save@")) and .with.path == "lean/.lake") | .if) = "${{ !cancelled() }}"'
mutate sha-pin '(.jobs.ci.steps[] | select(.uses // "" | test("^actions/checkout@")) | .uses) = "actions/checkout@v7.0.1"'

# The unbroken copy, rewritten by yq as the mutations are.
wf="$work/unbroken.yml"
cp "$root/.github/workflows/ci.yml" "$wf"
yq -i '.' "$wf"
if sh "$root/tools/workflow-check.sh" "$wf" >"$work/unbroken.out" 2>&1; then
  printf 'workflow-lint-probe: workflow-check passes the unbroken workflow: pass\n' >&2
else
  cat "$work/unbroken.out" >&2
  fail 'workflow-check failed on the unbroken copy of ci.yml'
fi

if [ -n "$failed" ]; then
  exit 1
fi
