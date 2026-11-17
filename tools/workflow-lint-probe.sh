#!/bin/sh
# Proves that `mise run workflow-lint` rejects what it must, so a broken
# config or a check that has stopped checking cannot pass silently:
#
#   sh tools/workflow-lint-probe.sh    # run last by `mise run workflow-lint`
#
# 1. zizmor, with .github/zizmor.yml, must exit non-zero on
#    tests/workflow-lint/tag-pinned.yml, whose one action is pinned by a tag,
#    with an `unpinned-uses` finding.
# 2. In a temporary directory it copies the check with the workflows and
#    the files it reads (.github/workflows/ci.yml, build.yml and
#    release.yml, tools/ci/install-elan.sh, tools/linux/Dockerfile,
#    infra/github/actions.tf, mise.toml), a tree per case, and breaks the
#    check's rules one at a time: every rule at least once, with yq on the
#    tree's ci.yml, build.yml or release.yml or sed on another file, plus
#    the sha-pin case of a SHA with no `# v…` comment and the common rules
#    on build.yml and release.yml. The check runs on the tree's own copy of
#    the workflow, so the file's base name picks the rules, as in the
#    checkout; a copy of ci.yml saved as nightly.yml, a file the check has
#    no rules for, fails the rule `workflows`. The check must exit 1 on
#    each case, naming that rule and no other. Then it must pass the three
#    workflows of a tree rewritten by the same yq, so a mutation's failure
#    is the mutation's and not the rewrite's.
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

# The check, the workflows and the files it reads, copied: it finds them
# from its own place, so a copy of this tree is a checkout it can be run in.
fixture_files='tools/workflow-check.sh .github/workflows/ci.yml .github/workflows/build.yml .github/workflows/release.yml tools/ci/install-elan.sh tools/linux/Dockerfile infra/github/actions.tf mise.toml'

# copy_tree <dir>: the check and its files, unbroken, under <dir>.
copy_tree() {
  for f in $fixture_files; do
    mkdir -p "$1/$(dirname "$f")"
    cp "$root/$f" "$1/$f"
  done
}

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

# mutate_in <file> <rule> <what> <yq expression>: the check must fail on a
# tree whose .github/workflows/<file> has the expression applied, naming
# <rule> and no other rule.
mutate_in() {
  n=$((n + 1))
  copy_tree "$work/$n"
  wf="$work/$n/.github/workflows/$1"
  yq -i "$4" "$wf"
  expect "$2" "$3" "$work/$n" "$wf"
}

# mutate <rule> <what> <yq expression>: the same on the tree's ci.yml.
mutate() {
  mutate_in ci.yml "$@"
}

# mutate_build <rule> <what> <yq expression>: the same on the tree's
# build.yml.
mutate_build() {
  mutate_in build.yml "$@"
}

# mutate_release <rule> <what> <yq expression>: the same on the tree's
# release.yml.
mutate_release() {
  mutate_in release.yml "$@"
}

# mutate_file <rule> <what> <file> <sed expression>: the check must fail
# on the tree's unbroken ci.yml with <file> of its tree edited, naming
# <rule> and no other rule.
mutate_file() {
  n=$((n + 1))
  copy_tree "$work/$n"
  sed "$4" "$root/$3" >"$work/$n/$3"
  if cmp -s "$root/$3" "$work/$n/$3"; then
    fail "the mutation for $1 left $3 unchanged"
    return
  fi
  expect "$1" "$2" "$work/$n" "$work/$n/.github/workflows/ci.yml"
}

# The Gate's step, Lake's restore, elan's save and the `ci` job's checkout.
gate='.jobs.ci.steps[] | select(.run == "mise run ci")'
lake_restore='.jobs.ci.steps[] | select((.uses // "" | test("^actions/cache/restore@")) and .with.path == "lean/.lake")'
elan_save='.jobs.ci.steps[] | select((.uses // "" | test("^actions/cache/save@")) and .with.path == "~/.elan")'
checkout='.jobs.ci.steps[] | select(.uses // "" | test("^actions/checkout@"))'
mise_action='.jobs.ci.steps[] | select(.uses // "" | test("^jdx/mise-action@"))'
lake_steps='.jobs.ci.steps[] | select((.uses // "" | test("^actions/cache/(restore|save)@")) and .with.path == "lean/.lake")'

mutate triggers 'push filtered to main' '.on.push.branches = ["main"]'
mutate matrix 'no ubuntu-24.04 leg' '.jobs.ci.strategy.matrix.os = ["macos-26"]'
mutate matrix 'fail-fast on' '.jobs.ci.strategy["fail-fast"] = true'
mutate continue-on-error 'the Gate continuing on error' "($gate)[\"continue-on-error\"] = true"
mutate gate-step 'a condition on the Gate' "($gate).if = \"\${{ success() }}\""
mutate gate-step 'a second `mise run ci` step' '.jobs.ci.steps += [{"run": "mise run ci"}]'
mutate concurrency "main's runs cancelled in progress" '.concurrency["cancel-in-progress"] = true'
mutate mise-env 'MISE_AUTO_INSTALL a boolean, not a string' '.jobs.ci.env.MISE_AUTO_INSTALL = false'
mutate sha-pin 'checkout pinned by a tag' "($checkout | .uses) = \"actions/checkout@v7.0.1\""
mutate sha-pin 'a SHA pin with no tag comment' "($checkout | .uses) line_comment = \"\""
mutate cache-save 'Lake saving from any ref' '(.jobs.ci.steps[] | select((.uses // "" | test("^actions/cache/save@")) and .with.path == "lean/.lake") | .if) = "${{ !cancelled() }}"'
mutate cache-save 'the combined actions/cache' '.jobs.ci.steps += [{"uses": "actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9", "with": {"path": "x", "key": "x"}}] | .jobs.ci.steps[-1].uses line_comment = "v6.1.0"'
mutate cache-keys "elan's save key not its restore's" "($elan_save | .with.key) = \"elan-v2\""
mutate lake-key "Lake's restore-keys not its key's prefix" "($lake_restore | .with[\"restore-keys\"]) = \"lake-v1-\""
mutate lake-key "Lake's key not ending in the commit" "($lake_steps | .with.key) |= sub(\"-[\$][{][{] github[.]sha [}][}]\$\"; \"\")"
mutate rust-cache 'no rust-cache step' 'del(.jobs.ci.steps[] | select(.uses // "" | test("^Swatinem/rust-cache@")))'
mutate rust-cache 'rust-cache saving from any ref' 'del(.jobs.ci.steps[] | select(.uses // "" | test("^Swatinem/rust-cache@")) | .with["save-if"])'
mutate mise-action "mise-action at another mise version" '(.jobs.ci.steps[] | select(.uses // "" | test("^jdx/mise-action@")) | .with.version) = "2026.11.1"'
mutate mise-action 'mise-action saving from any ref' "($mise_action | .with.cache_save) = \"true\""
mutate install-args 'cargo-deny not installed' "($mise_action | .with.install_args) |= sub(\" aqua:EmbarkStudios/cargo-deny\"; \"\")"
mutate secrets-scan 'a shallow checkout for the scan' 'del(.jobs["secrets-scan"].steps[] | select(.uses // "" | test("^actions/checkout@")) | .with["fetch-depth"])'
mutate allowlist 'a third-party action not on the allowlist' '.jobs.ci.steps += [{"uses": "example/action@0123456789abcdef0123456789abcdef01234567"}] | .jobs.ci.steps[-1].uses line_comment = "v1.0.0"'
mutate_file elan-version "install-elan.sh's elan not the Dockerfile's" tools/ci/install-elan.sh 's/^ELAN_VERSION=.*/ELAN_VERSION=0.0.0/'
mutate_file install-args 'a tool named as not in the gate gone from mise.toml' mise.toml '/^opentofu = /d'

# A workflow file the check has no rules for.
n=$((n + 1))
copy_tree "$work/$n"
cp "$work/$n/.github/workflows/ci.yml" "$work/$n/.github/workflows/nightly.yml"
expect workflows 'a copy of ci.yml saved as nightly.yml' "$work/$n" "$work/$n/.github/workflows/nightly.yml"

# ci.yml's build jobs.
mutate build-gating 'build not needing ci' '.jobs.build.needs = ["build-id"]'
mutate build-gating "build's if not limited to main" ".jobs.build.if = \"\${{ github.event_name == 'push' }}\""
mutate build-gating 'build-id with no if' 'del(.jobs["build-id"].if)'

# ci.yml's release job, and who may write. build-id is given the write
# scope, since a scope on build would also break build-gating.
mutate release-gating 'release not needing secrets-scan' '.jobs.release.needs = ["ci", "build-id", "build"]'
mutate release-gating "release's if not limited to main" ".jobs.release.if = \"\${{ github.event_name == 'push' }}\""
mutate release-gating "release's token reading contents only" '.jobs.release.permissions.contents = "read"'
mutate release-concurrency 'the nightly cancelled in progress' '.jobs.release.concurrency["cancel-in-progress"] = true'
mutate release-concurrency 'the nightly group renamed' '.jobs.release.concurrency.group = "release"'
mutate write-scope 'build-id writing contents' '.jobs["build-id"].permissions = {"contents": "write"}'
mutate write-scope 'the workflow writing pages' '.permissions.pages = "write"'

# build.yml. Its steps: dmg-check's, the upload, and the Lake restore. The
# save of lean/.lake goes before the upload, which must stay last.
build_step='.jobs.build.steps[] | select(.run == "mise run dmg-check")'
upload='.jobs.build.steps[] | select(.uses // "" | test("^actions/upload-artifact@"))'
build_lake='.jobs.build.steps[] | select((.uses // "" | test("^actions/cache/restore@")) and .with.path == "lean/.lake")'
mutate_build build-trigger 'build.yml also run on push' '.on.push = {}'
mutate_build build-trigger 'the commit input not required' '.on.workflow_call.inputs.commit.required = false'
mutate_build build-job 'the build on macos-15' '.jobs.build["runs-on"] = "macos-15"'
mutate_build build-job 'no LEANMACS_COMMIT in the env' 'del(.jobs.build.env.LEANMACS_COMMIT)'
mutate_build build-steps 'a condition on the dmg check' "($build_step).if = \"\${{ success() }}\""
mutate_build build-steps "the upload's if-no-files-found warn" "($upload | .with[\"if-no-files-found\"]) = \"warn\""
mutate_build build-steps 'app-check after the dmg' '(.jobs.build.steps[] | select(.run == "mise run app-check") | .run) = "swap" | (.jobs.build.steps[] | select(.run == "mise run dmg") | .run) = "mise run app-check" | (.jobs.build.steps[] | select(.run == "swap") | .run) = "mise run dmg"'
mutate_build build-cache "a save of lean/.lake, guarded to main with the restore's key" ".jobs.build.steps |= (.[:-1] + [{\"if\": \"\${{ github.ref == 'refs/heads/main' }}\", \"uses\": \"actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9\", \"with\": {\"path\": \"lean/.lake\"}}] + .[-1:]) | .jobs.build.steps[-2].with.key = ($build_lake | .with.key) | .jobs.build.steps[-2].uses line_comment = \"v6.1.0\""
mutate_build build-cache "Lake's restore key not ci.yml's" "($build_lake | .with.key) |= sub(\"^lake-v1-\"; \"lake-v2-\")"
mutate_build sha-pin 'upload-artifact pinned by a tag' "($upload | .uses) = \"actions/upload-artifact@v7.0.2\""
mutate_build mise-env 'no MISE_AUTO_INSTALL in the build job' 'del(.jobs.build.env.MISE_AUTO_INSTALL)'

# release.yml. Its steps: the prepare, the publish (last, with the token)
# and the download.
prepare='.jobs.publish.steps[] | select(.run == "mise run nightly")'
download='.jobs.publish.steps[] | select(.uses // "" | test("^actions/download-artifact@"))'
mutate_release release-trigger 'release.yml also run on push' '.on.push = {}'
mutate_release release-job 'a checkout that keeps its credentials' 'del(.jobs.publish.steps[] | select(.uses // "" | test("^actions/checkout@")) | .with["persist-credentials"])'
mutate_release release-job 'the job also writing pages' '.jobs.publish.permissions.pages = "write"'
mutate_release release-job 'the release on ubuntu-24.04' '.jobs.publish["runs-on"] = "ubuntu-24.04"'
mutate_release release-steps 'a condition on the prepare' "($prepare).if = \"\${{ success() }}\""
mutate_release release-steps 'the publish, with its token, moved before the prepare' '.jobs.publish.steps |= ([.[-1]] + .[:-1])'
mutate_release release-steps 'a step after the publish' '.jobs.publish.steps += [{"run": "echo done"}]'
mutate_release release-steps 'gh release upload in the prepare' "($prepare).run = \"mise run nightly && gh release upload nightly target/nightly/Leanmacs.dmg\""
mutate_release release-token 'GH_TOKEN in the prepare too' "($prepare).env.GH_TOKEN = \"\${{ github.token }}\""
mutate_release release-token 'GH_TOKEN in the job env' ".jobs.publish.env.GH_TOKEN = \"\${{ github.token }}\""
mutate_release release-cache 'a rust-cache, saving from main only' ".jobs.publish.steps |= (.[:2] + [{\"uses\": \"Swatinem/rust-cache@d1527c8f67ef9af357290475d4af4b0fab8f12e0\", \"with\": {\"save-if\": \"\${{ github.ref == 'refs/heads/main' }}\"}}] + .[2:]) | .jobs.publish.steps[2].uses line_comment = \"v2.9.3\""
mutate_release sha-pin 'download-artifact pinned by a tag' "($download | .uses) = \"actions/download-artifact@v8.0.2\""

# The unbroken copies, rewritten by the same yq as the mutations.
n=$((n + 1))
copy_tree "$work/$n"
for f in ci.yml build.yml release.yml; do
  wf="$work/$n/.github/workflows/$f"
  yq -i '.' "$wf"
  if sh "$work/$n/tools/workflow-check.sh" "$wf" >"$work/unbroken.out" 2>&1; then
    printf 'workflow-lint-probe: workflow-check passes the unbroken %s: pass\n' "$f" >&2
  else
    cat "$work/unbroken.out" >&2
    fail "workflow-check failed on the unbroken copy of $f"
  fi
done

if [ -n "$failed" ]; then
  exit 1
fi
