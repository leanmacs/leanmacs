#!/bin/sh
# The structural check of the CI workflow, run by `mise run workflow-lint`:
#
#   sh tools/workflow-check.sh <workflow.yml>
#
# actionlint checks that the workflow is valid and zizmor that it is safe;
# neither knows what this repository needs of it. This checks that, with yq
# (pinned in mise.toml), and fails on each rule broken
# (docs/dev-practices/ci.md):
#
#   triggers           every push to any branch and every pull request
#   matrix             the `ci` job's legs are exactly macos-26 and
#                      ubuntu-24.04, with fail-fast off
#   continue-on-error  no job or step continues on error: a red leg fails
#                      the workflow
#   gate-step          the `ci` job runs `mise run ci` in exactly one step,
#                      unconditionally
#   concurrency        the group is per workflow and ref, and a run on main
#                      is never cancelled in progress
#   mise-env           every job sets MISE_AUTO_INSTALL "false", and `ci`
#                      sets MISE_ENV "ci" (mise.ci.toml)
#   sha-pin            every `uses:` names a full commit SHA, with the
#                      release tag in a trailing `# v…` comment
#   cache-save         no combined `actions/cache`, and every
#                      `actions/cache/save` is guarded to main
#   cache-keys         every save's key and path are a restore's in the
#                      same job
#   lake-key           Lake's cache key hashes the toolchain and the
#                      manifest and ends in the commit, and its restore-keys
#                      is that key without the commit
#   rust-cache         every rust-cache saves from main only
#   mise-action        every mise-action saves its cache from main only, at
#                      the Linux container's mise version
#   install-args       the `ci` job's mise-action installs every mise.toml
#                      tool the gate runs (MISE_AUTO_INSTALL is false)
#   secrets-scan       the `secrets-scan` job checks out the full history
#                      and runs `mise run secrets-scan`
#   allowlist          every third-party action has its pattern in
#                      infra/github/actions.tf's patterns_allowed
#   elan-version       tools/ci/install-elan.sh pins the Dockerfile's elan
#
# The other files are read from this checkout, found from the script's own
# place. It prints every rule broken, then exits 1; 0 when none is.
set -eu

if [ $# -ne 1 ]; then
  printf 'usage: sh tools/workflow-check.sh <workflow.yml>\n' >&2
  exit 2
fi
wf=$1
root=$(cd "$(dirname "$0")/.." && pwd)
failed=

fail() {
  printf 'workflow-check: %s: %s\n' "$1" "$2" >&2
  failed=1
}

# q <expression>: yq's output for the workflow, scalars unquoted,
# structures as one line of JSON.
q() {
  yq -o=json -I=0 "$1" "$wf" | sed 's/^"\(.*\)"$/\1/'
}

# The expression every main-only save is guarded by, and the comparison in
# it; exported for yq's strenv().
MAIN_REF="github.ref == 'refs/heads/main'"
ON_MAIN="\${{ $MAIN_REF }}"
export MAIN_REF ON_MAIN
on_main=$ON_MAIN

# ---- triggers
if [ "$(q '.on | has("push")')" != true ]; then
  fail triggers 'on: must have push'
elif [ "$(q '.on.push.branches // ["**"]')" != '["**"]' ] ||
  [ "$(q '.on.push | (. // {}) | (has("branches-ignore") or has("paths") or has("paths-ignore") or has("tags") or has("tags-ignore"))')" != false ]; then
  fail triggers "push must run on every branch: branches [\"**\"] and no other filter"
fi
if [ "$(q '.on | has("pull_request")')" != true ]; then
  fail triggers 'on: must have pull_request'
elif [ "$(q '.on.pull_request | (. // {}) | length')" != 0 ]; then
  fail triggers 'pull_request must have no filter'
fi

# ---- matrix
if [ "$(q '.jobs.ci.strategy.matrix')" != '{"os":["macos-26","ubuntu-24.04"]}' ]; then
  fail matrix 'jobs.ci.strategy.matrix must be exactly os: [macos-26, ubuntu-24.04]'
fi
if [ "$(q '.jobs.ci.strategy["fail-fast"]')" != false ]; then
  fail matrix 'jobs.ci.strategy["fail-fast"] must be false'
fi
if [ "$(q '.jobs.ci["runs-on"]')" != "\${{ matrix.os }}" ]; then
  fail matrix 'jobs.ci.runs-on must be ${{ matrix.os }}'
fi

# ---- continue-on-error
if [ "$(q '[.jobs[] | select(has("continue-on-error"))] + [.jobs[].steps[]? | select(has("continue-on-error"))] | length')" != 0 ]; then
  fail continue-on-error 'no job or step may set continue-on-error'
fi

# ---- gate-step
if [ "$(q '[.jobs.ci.steps[]? | select(.run == "mise run ci")] | length')" != 1 ]; then
  fail gate-step 'jobs.ci must have exactly one step whose run is `mise run ci`'
elif [ "$(q '[.jobs.ci.steps[]? | select(.run == "mise run ci" and has("if"))] | length')" != 0 ]; then
  fail gate-step 'the `mise run ci` step must have no if:'
fi

# ---- concurrency
if [ "$(q '.concurrency.group')" != "\${{ github.workflow }}-\${{ github.ref }}" ]; then
  fail concurrency 'concurrency.group must be ${{ github.workflow }}-${{ github.ref }}'
fi
if [ "$(q '.concurrency["cancel-in-progress"]')" != "\${{ github.ref != 'refs/heads/main' }}" ]; then
  fail concurrency "concurrency.cancel-in-progress must be \${{ github.ref != 'refs/heads/main' }}"
fi

# ---- mise-env
bad=$(q '[.jobs | to_entries[] | select((.value.env.MISE_AUTO_INSTALL | tag) != "!!str" or .value.env.MISE_AUTO_INSTALL != "false") | .key] | join(" ")')
if [ -n "$bad" ]; then
  fail mise-env "jobs without env MISE_AUTO_INSTALL: \"false\": $bad"
fi
if [ "$(q '.jobs.ci.env.MISE_ENV')" != ci ]; then
  fail mise-env 'jobs.ci.env.MISE_ENV must be ci'
fi

# ---- sha-pin
# Every `uses:` but a local `./` one, which names no ref.
uses=$(yq '[.jobs[].steps[]?.uses, .jobs[].uses] | .[] | select(. != null)' "$wf")
for u in $uses; do
  case $u in
  ./*) continue ;;
  esac
  if ! printf '%s\n' "$u" | grep -Eq '^[^@]+@[0-9a-f]{40}$'; then
    fail sha-pin "not pinned by a full commit SHA: $u"
  fi
done
grep -E '^[[:space:]]*(-[[:space:]]+)?uses:' "$wf" |
  grep -vE 'uses:[[:space:]]*["'\'']?\./' |
  grep -vE 'uses:[[:space:]]*[^[:space:]#]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9]' |
  while IFS= read -r line; do
    printf 'workflow-check: sha-pin: no full SHA with a trailing `# v…` tag comment: %s\n' \
      "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')" >&2
    echo x
  done | grep -q x && failed=1

# ---- cache-save
if [ "$(q '[.jobs[].steps[]? | select(.uses // "" | test("^actions/cache@"))] | length')" != 0 ]; then
  fail cache-save 'use actions/cache/restore and actions/cache/save, not actions/cache: it saves from any ref'
fi
if [ "$(q '[.jobs[].steps[]? | select(.uses // "" | test("^actions/cache/save@")) | select((.if // "") | contains(strenv(MAIN_REF)) | not)] | length')" != 0 ]; then
  fail cache-save "every actions/cache/save step's if: must contain github.ref == 'refs/heads/main'"
fi

# ---- cache-keys
# Each save's key and path must be a restore's in the same job.
for job in $(q '.jobs | keys | .[]' | tr -d '"'); do
  restores=$(J=$job yq -o=json -I=0 '.jobs[strenv(J)].steps[]? | select(.uses // "" | test("^actions/cache/restore@")) | [.with.key, .with.path]' "$wf")
  J=$job yq -o=json -I=0 '.jobs[strenv(J)].steps[]? | select(.uses // "" | test("^actions/cache/save@")) | [.with.key, .with.path]' "$wf" |
    while IFS= read -r pair; do
      if ! printf '%s\n' "$restores" | grep -qxF "$pair"; then
        printf 'workflow-check: cache-keys: a save in job %s has no restore with the same key and path: %s\n' "$job" "$pair" >&2
        echo x
      fi
    done | grep -q x && failed=1
done

# ---- lake-key
n=$(q '[.jobs.ci.steps[]? | select((.uses // "" | test("^actions/cache/restore@")) and .with.path == "lean/.lake")] | length')
if [ "$n" != 1 ]; then
  fail lake-key 'jobs.ci must have exactly one actions/cache/restore of lean/.lake'
else
  key=$(yq '.jobs.ci.steps[] | select((.uses // "" | test("^actions/cache/restore@")) and .with.path == "lean/.lake") | .with.key' "$wf")
  restore_keys=$(yq '.jobs.ci.steps[] | select((.uses // "" | test("^actions/cache/restore@")) and .with.path == "lean/.lake") | .with["restore-keys"]' "$wf")
  sha_suffix="\${{ github.sha }}"
  case $key in
  *"$sha_suffix") ;;
  *) fail lake-key "Lake's cache key must end in $sha_suffix" ;;
  esac
  case $key in
  *"hashFiles('lean/lean-toolchain', 'lean/lake-manifest.json')"*) ;;
  *) fail lake-key "Lake's cache key must hash lean/lean-toolchain and lean/lake-manifest.json" ;;
  esac
  if [ "$restore_keys" != "${key%"$sha_suffix"}" ]; then
    fail lake-key "Lake's restore-keys must be its key without the trailing $sha_suffix"
  fi
fi

# ---- rust-cache
if [ "$(q '[.jobs.ci.steps[]? | select(.uses // "" | test("^Swatinem/rust-cache@"))] | length')" = 0 ]; then
  fail rust-cache 'jobs.ci must use Swatinem/rust-cache'
fi
if [ "$(q '[.jobs[].steps[]? | select(.uses // "" | test("^Swatinem/rust-cache@")) | select(.with["save-if"] != strenv(ON_MAIN))] | length')" != 0 ]; then
  fail rust-cache "every rust-cache step must have save-if: $on_main"
fi

# ---- mise-action
mise_version=$(sed -n 's/^ARG MISE_VERSION=//p' "$root/tools/linux/Dockerfile")
if [ -z "$mise_version" ]; then
  fail mise-action 'no ARG MISE_VERSION in tools/linux/Dockerfile'
fi
if [ "$(q '[.jobs[].steps[]? | select(.uses // "" | test("^jdx/mise-action@")) | select(.with.cache_save != strenv(ON_MAIN))] | length')" != 0 ]; then
  fail mise-action "every mise-action step must have cache_save: $on_main"
fi
if [ "$(V=$mise_version yq '[.jobs[].steps[]? | select(.uses // "" | test("^jdx/mise-action@")) | select((.with.version // "" | tostring) != strenv(V))] | length' "$wf")" != 0 ]; then
  fail mise-action "every mise-action step must have version: $mise_version, the Dockerfile's MISE_VERSION"
fi

# ---- install-args
# With MISE_AUTO_INSTALL "false", the gate finds only the tools the `ci`
# job's mise-action installs, so its install_args must name every tool the
# gate runs. That list is mise.toml's [tools], read here, less the tools the
# gate never runs, named below; a tool added to mise.toml is required here
# until it is either installed or named below.
#
#   hk                      runs `mise run ci`, but the job runs it directly
#   pkl                     hk.pkl's language, read only by hk
#   aqua:gitleaks/gitleaks  `mise run secrets-scan`, the secrets-scan job's
#   opentofu                `mise run infra-*`, never run in CI
not_in_gate='hk pkl aqua:gitleaks/gitleaks opentofu'
mise_tools=$(yq -p toml -o yaml '.tools | keys | .[]' "$root/mise.toml")
if [ -z "$mise_tools" ]; then
  fail install-args 'no [tools] in mise.toml'
fi
for t in $not_in_gate; do
  if ! printf '%s\n' "$mise_tools" | grep -qxF "$t"; then
    fail install-args "$t is named as not in the gate but is not in mise.toml's [tools]"
  fi
done
if [ "$(q '[.jobs.ci.steps[]? | select(.uses // "" | test("^jdx/mise-action@"))] | length')" != 1 ]; then
  fail install-args 'jobs.ci must have exactly one jdx/mise-action step'
else
  install_args=$(yq '.jobs.ci.steps[] | select(.uses // "" | test("^jdx/mise-action@")) | .with.install_args // ""' "$wf")
  for t in $mise_tools; do
    case " $not_in_gate " in
    *" $t "*) continue ;;
    esac
    found=
    for a in $install_args; do
      if [ "${a%%@*}" = "$t" ]; then
        found=1
      fi
    done
    if [ -z "$found" ]; then
      fail install-args "jobs.ci's mise-action install_args must name $t (mise.toml [tools]; MISE_AUTO_INSTALL is false)"
    fi
  done
fi

# ---- secrets-scan
if [ "$(q '[.jobs["secrets-scan"].steps[]? | select((.uses // "" | test("^actions/checkout@")) and .with["fetch-depth"] == 0)] | length')" != 1 ]; then
  fail secrets-scan 'jobs.secrets-scan must check out with fetch-depth: 0'
fi
if [ "$(q '[.jobs["secrets-scan"].steps[]? | select(.run == "mise run secrets-scan")] | length')" != 1 ]; then
  fail secrets-scan 'jobs.secrets-scan must run `mise run secrets-scan`'
fi

# ---- allowlist
# GitHub's own actions (`actions/*`, `github/*`) are allowed by
# github_owned_allowed and need no pattern.
allowed=$(awk '/patterns_allowed[[:space:]]*=[[:space:]]*\[/ { on = 1; next } on && /\]/ { on = 0 } on' "$root/infra/github/actions.tf")
for u in $uses; do
  case $u in
  ./* | actions/* | github/*) continue ;;
  esac
  repo=$(printf '%s\n' "${u%%@*}" | cut -d/ -f1-2)
  if ! printf '%s\n' "$allowed" | grep -qF "\"$repo@*\""; then
    fail allowlist "$repo has no \"$repo@*\" in infra/github/actions.tf patterns_allowed"
  fi
done

# ---- elan-version
ci_elan=$(sed -n 's/^ELAN_VERSION=//p' "$root/tools/ci/install-elan.sh")
docker_elan=$(sed -n 's/^ARG ELAN_VERSION=//p' "$root/tools/linux/Dockerfile")
if [ -z "$ci_elan" ] || [ "$ci_elan" != "$docker_elan" ]; then
  fail elan-version "tools/ci/install-elan.sh pins elan '$ci_elan', the Dockerfile '$docker_elan'"
fi

if [ -n "$failed" ]; then
  exit 1
fi
printf 'workflow-check: %s holds every rule\n' "$wf" >&2
