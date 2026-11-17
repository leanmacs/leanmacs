#!/bin/sh
# Proves that `mise run workflow-lint` rejects what it must, so a broken
# config or a check that has stopped checking cannot pass silently:
#
#   sh tools/workflow-lint-probe.sh    # run last by `mise run workflow-lint`
#
# 1. zizmor, with .github/zizmor.yml, must exit non-zero on
#    tests/workflow-lint/tag-pinned.yml, whose one action is pinned by a tag,
#    with an `unpinned-uses` finding.
# 2. In a temporary directory it copies .github/workflows/ci.yml, and the
#    check with the files it reads (tools/ci/install-elan.sh,
#    tools/linux/Dockerfile, infra/github/actions.tf), and breaks the
#    check's rules one at a time: every rule at least once, with yq on the
#    workflow or sed on another file, plus the sha-pin case of a SHA with
#    no `# v…` comment. The check must exit 1 on each, naming that rule and
#    no other. Then it must pass on the unbroken copy, written by the same
#    yq, so a mutation's failure is the mutation's and not the rewrite's.
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

# The check and the files it reads, copied: it finds them from its own
# place, so a copy of this tree is a checkout it can be run in.
fixture_files='tools/workflow-check.sh tools/ci/install-elan.sh tools/linux/Dockerfile infra/github/actions.tf'

# copy_tree <dir>: the check and its files, unbroken, under <dir>.
copy_tree() {
  for f in $fixture_files; do
    mkdir -p "$1/$(dirname "$f")"
    cp "$root/$f" "$1/$f"
  done
}

# The unbroken copy of ci.yml, rewritten by yq as the mutations are.
unbroken="$work/unbroken.yml"
cp "$root/.github/workflows/ci.yml" "$unbroken"
yq -i '.' "$unbroken"

n=0

# expect <rule> <what> <tree> <workflow>: the check, run from <tree> on
# <workflow>, must exit 1 naming <rule> and no other rule.
expect() {
  rule=$1
  out="$work/$n.out"
  status=0
  sh "$3/tools/workflow-check.sh" "$4" >"$out" 2>&1 || status=$?
  named=$(sed -n 's/^workflow-check: \([a-z-]*\): .*/\1/p' "$out" | sort -u)
  if [ "$status" -ne 1 ]; then
    cat "$out" >&2
    fail "workflow-check exited $status, not 1, with $2"
  elif [ "$named" != "$rule" ]; then
    cat "$out" >&2
    fail "with $2, workflow-check named: $(printf '%s' "$named" | tr '\n' ' ')"
  else
    printf 'workflow-lint-probe: workflow-check rejects %s (%s): pass\n' "$2" "$rule" >&2
  fi
}

# mutate <rule> <what> <yq expression>: the check must fail on a copy of
# ci.yml with the expression applied, naming <rule> and no other rule.
mutate() {
  n=$((n + 1))
  copy_tree "$work/$n"
  wf="$work/$n.yml"
  cp "$root/.github/workflows/ci.yml" "$wf"
  yq -i "$3" "$wf"
  expect "$1" "$2" "$work/$n" "$wf"
}

# mutate_file <rule> <what> <file> <sed expression>: the check must fail
# on the unbroken ci.yml with <file> of its tree edited, naming <rule> and
# no other rule.
mutate_file() {
  n=$((n + 1))
  copy_tree "$work/$n"
  sed "$4" "$root/$3" >"$work/$n/$3"
  if cmp -s "$root/$3" "$work/$n/$3"; then
    fail "the mutation for $1 left $3 unchanged"
    return
  fi
  expect "$1" "$2" "$work/$n" "$unbroken"
}

# The Gate's step, Lake's restore, elan's save and the `ci` job's checkout.
gate='.jobs.ci.steps[] | select(.run == "mise run ci")'
lake_restore='.jobs.ci.steps[] | select((.uses // "" | test("^actions/cache/restore@")) and .with.path == "lean/.lake")'
elan_save='.jobs.ci.steps[] | select((.uses // "" | test("^actions/cache/save@")) and .with.path == "~/.elan")'
checkout='.jobs.ci.steps[] | select(.uses // "" | test("^actions/checkout@"))'

mutate triggers 'push filtered to main' '.on.push.branches = ["main"]'
mutate matrix 'no ubuntu-24.04 leg' '.jobs.ci.strategy.matrix.os = ["macos-26"]'
mutate continue-on-error 'the Gate continuing on error' "($gate)[\"continue-on-error\"] = true"
mutate gate-step 'a condition on the Gate' "($gate).if = \"\${{ success() }}\""
mutate concurrency "main's runs cancelled in progress" '.concurrency["cancel-in-progress"] = true'
mutate mise-env 'MISE_AUTO_INSTALL a boolean, not a string' '.jobs.ci.env.MISE_AUTO_INSTALL = false'
mutate sha-pin 'checkout pinned by a tag' "($checkout | .uses) = \"actions/checkout@v7.0.1\""
mutate sha-pin 'a SHA pin with no tag comment' "($checkout | .uses) line_comment = \"\""
mutate cache-save 'Lake saving from any ref' '(.jobs.ci.steps[] | select((.uses // "" | test("^actions/cache/save@")) and .with.path == "lean/.lake") | .if) = "${{ !cancelled() }}"'
mutate cache-keys "elan's save key not its restore's" "($elan_save | .with.key) = \"elan-v2\""
mutate lake-key "Lake's restore-keys not its key's prefix" "($lake_restore | .with[\"restore-keys\"]) = \"lake-v1-\""
mutate rust-cache 'rust-cache saving from any ref' 'del(.jobs.ci.steps[] | select(.uses // "" | test("^Swatinem/rust-cache@")) | .with["save-if"])'
mutate mise-action "mise-action at another mise version" '(.jobs.ci.steps[] | select(.uses // "" | test("^jdx/mise-action@")) | .with.version) = "2026.11.1"'
mutate secrets-scan 'a shallow checkout for the scan' 'del(.jobs["secrets-scan"].steps[] | select(.uses // "" | test("^actions/checkout@")) | .with["fetch-depth"])'
mutate allowlist 'a third-party action not on the allowlist' '.jobs.ci.steps += [{"uses": "example/action@0123456789abcdef0123456789abcdef01234567"}] | .jobs.ci.steps[-1].uses line_comment = "v1.0.0"'
mutate_file elan-version "install-elan.sh's elan not the Dockerfile's" tools/ci/install-elan.sh 's/^ELAN_VERSION=.*/ELAN_VERSION=0.0.0/'

# The unbroken copy.
wf=$unbroken
if sh "$root/tools/workflow-check.sh" "$wf" >"$work/unbroken.out" 2>&1; then
  printf 'workflow-lint-probe: workflow-check passes the unbroken workflow: pass\n' >&2
else
  cat "$work/unbroken.out" >&2
  fail 'workflow-check failed on the unbroken copy of ci.yml'
fi

if [ -n "$failed" ]; then
  exit 1
fi
