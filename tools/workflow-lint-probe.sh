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
#    the files it reads (.github/workflows/ci.yml, build.yml, release.yml
#    and stress.yml, tools/ci/install-elan.sh, tools/linux/Dockerfile,
#    infra/github/actions.tf, mise.toml), a tree per case, and breaks the
#    check's rules one at a time: every rule at least once, with yq on the
#    tree's ci.yml, build.yml, release.yml or stress.yml or sed on another
#    file, plus
#    the sha-pin case of a SHA with no `# v…` comment and the common rules
#    on build.yml and release.yml. The check runs on the tree's own copy of
#    the workflow, so the file's base name picks the rules, as in the
#    checkout; a copy of ci.yml saved as nightly.yml, a file the check has
#    no rules for, fails the rule `workflows`. The check must exit 1 on
#    each case, naming that rule and no other. Then it must pass the four
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
fixture_files='tools/workflow-check.sh .github/workflows/ci.yml .github/workflows/build.yml .github/workflows/release.yml .github/workflows/stress.yml tools/ci/install-elan.sh tools/linux/Dockerfile infra/github/actions.tf mise.toml'

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
mutate release-gating "release's token without id-token" 'del(.jobs.release.permissions["id-token"])'
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

# release.yml. Its steps: the prepare, the publish (last, with the token),
# the download, the page's render and its upload, and the deploy.
prepare='.jobs.publish.steps[] | select(.run == "mise run nightly")'
download='.jobs.publish.steps[] | select(.uses // "" | test("^actions/download-artifact@"))'
render='.jobs.publish.steps[] | select(.run == "mise run site -- target/nightly/build.json target/site")'
page_upload='.jobs.publish.steps[] | select(.uses // "" | test("^actions/upload-pages-artifact@"))'
deploy='.jobs.pages.steps[] | select(.uses // "" | test("^actions/deploy-pages@"))'
# step_index <run>: the index of the publish step running <run> in the
# checkout's release.yml.
step_index() {
  R=$1 yq '.jobs.publish.steps | to_entries | .[] | select(.value.run == strenv(R)) | .key' "$root/.github/workflows/release.yml"
}
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
mutate_release sha-pin 'deploy-pages pinned by a tag' "($deploy | .uses) = \"actions/deploy-pages@v5.0.1\""
mutate_release release-job 'a third job' '.jobs.extra = {"runs-on": "ubuntu-24.04", "env": {"MISE_AUTO_INSTALL": "false"}, "steps": [{"run": "true"}]}'

# The page: rendered from the prepared build.json, after the prepare, and
# uploaded after the render. Moving a step moves it to another index: the
# step is taken out and put back at that index.
prepare_at=$(step_index 'mise run nightly')
render_at=$(step_index 'mise run site -- target/nightly/build.json target/site')
mutate_release release-page 'the render deleted' "del($render)"
mutate_release release-page 'the render reading a re-downloaded build.json' "($render).run = \"mise run site -- dist/build.json target/site\""
mutate_release release-page 'the render moved before the prepare' "($render) as \$r | del($render) | .jobs.publish.steps |= (.[:$prepare_at] + [\$r] + .[$prepare_at:])"
mutate_release release-page 'the upload moved before the render' "($page_upload) as \$u | del($page_upload) | .jobs.publish.steps |= (.[:$render_at] + [\$u] + .[$render_at:])"
mutate_release release-page "the upload's path target" "($page_upload | .with.path) = \"target\""

# The deploy.
mutate_release pages-job 'pages not needing publish' 'del(.jobs.pages.needs)'
mutate_release pages-job 'pages deploying always' ".jobs.pages.if = \"\${{ always() }}\""
mutate_release pages-job 'pages also reading contents' '.jobs.pages.permissions.contents = "read"'
mutate_release pages-job 'pages on a runner outside the matrix' '.jobs.pages["runs-on"] = "macos-15"'
mutate_release pages-job 'pages without id-token' 'del(.jobs.pages.permissions["id-token"])'
mutate_release pages-job 'pages in another environment' '.jobs.pages.environment.name = "pages"'
mutate_release pages-job 'a checkout in pages' '.jobs.pages.steps = [{"uses": "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "with": {"persist-credentials": false}}] + .jobs.pages.steps | .jobs.pages.steps[0].uses line_comment = "v7.0.1"'
mutate_release pages-job 'the deploy without its id' "del(($deploy).id)"
mutate_release pages-concurrency 'the deploy cancelled in progress' '.jobs.pages.concurrency["cancel-in-progress"] = true'
mutate_release pages-concurrency 'the pages group renamed' '.jobs.pages.concurrency.group = "deploy"'

# stress.yml: on dispatch only, on both of the gate's legs, five shards
# each, the gate before the loop, a loop that names no suite, and the
# summary after the shards, over both legs.
mutate_in stress.yml stress-trigger 'stress.yml also run on push' '.on.push = {}'
mutate_in stress.yml stress-trigger 'no rounds input' 'del(.on.workflow_dispatch.inputs)'
mutate_in stress.yml stress-runner 'the macOS leg dropped' '.jobs.stress.strategy.matrix.os = ["ubuntu-24.04"]'
mutate_in stress.yml stress-runner 'the shards on one runner' '.jobs.stress["runs-on"] = "ubuntu-24.04"'
mutate_in stress.yml stress-runner 'the summary off the legs' '.jobs.summary["runs-on"] = "macos-15"'
mutate_in stress.yml stress-matrix 'four shards' '.jobs.stress.strategy.matrix.shard = [1, 2, 3, 4]'
mutate_in stress.yml stress-steps 'the loop before the gate' '(.jobs.stress.steps[] | select(.name == "Gate")) as $g | del(.jobs.stress.steps[] | select(.name == "Gate")) | .jobs.stress.steps += [$g]'
mutate_in stress.yml stress-steps 'the loop naming a suite' '(.jobs.stress.steps[] | select(.name == "Stress") | .run) |= sub("\\) \\| tee"; ")) config-wiring | tee")'
mutate_in stress.yml stress-summary 'a summary that does not wait for the shards' 'del(.jobs.summary.needs)'
mutate_in stress.yml stress-summary 'a summary over one leg' '.jobs.summary.env.LEGS = "ubuntu-24.04"'
mutate_in stress.yml sha-pin 'upload-artifact pinned by a tag' '(.jobs.stress.steps[] | select(.uses // "" | test("^actions/upload-artifact@")) | .uses) = "actions/upload-artifact@v7.0.2"'

# The unbroken copies, rewritten by the same yq as the mutations.
n=$((n + 1))
copy_tree "$work/$n"
for f in ci.yml build.yml release.yml stress.yml; do
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
