#!/bin/sh
# The structural check of the CI workflows, run by `mise run workflow-lint`
# on each file in .github/workflows:
#
#   sh tools/workflow-check.sh <workflow.yml>
#
# actionlint checks that a workflow is valid and zizmor that it is safe;
# neither knows what this repository needs of it. This checks that, with yq
# (pinned in mise.toml), and fails on each rule broken
# (docs/dev-practices/ci.md). The rules it runs are picked by the file's
# base name: the common rules on every file, then ci.yml's, build.yml's,
# release.yml's or stress.yml's.
#
# Every file:
#
#   workflows          the file is ci.yml, build.yml, release.yml or
#                      stress.yml: a
#                      workflow file with no rules here fails, so none
#                      goes unchecked
#   continue-on-error  no job or step continues on error: a red leg fails
#                      the workflow
#   mise-env           every job sets MISE_AUTO_INSTALL "false", but a job
#                      that calls a reusable workflow, which cannot set env
#   sha-pin            every `uses:` names a full commit SHA, with the
#                      release tag in a trailing `# v…` comment
#   cache-save         no combined `actions/cache`, and every
#                      `actions/cache/save` is guarded to main
#   cache-keys         every save's key and path are a restore's in the
#                      same job
#   rust-cache         every rust-cache saves from main only
#   mise-action        every mise-action saves its cache from main only, at
#                      the Linux container's mise version
#   allowlist          every third-party action has its pattern in
#                      infra/github/actions.tf's patterns_allowed
#
# ci.yml:
#
#   triggers           every push to any branch and every pull request
#   matrix             the `ci` job's legs are exactly macos-26 and
#                      ubuntu-24.04, with fail-fast off
#   gate-step          the `ci` job runs `mise run ci` in exactly one step,
#                      unconditionally
#   concurrency        the group is per workflow and ref, and a run on main
#                      is never cancelled in progress
#   lake-key           Lake's cache key hashes the toolchain and the
#                      manifest and ends in the commit, and its restore-keys
#                      is that key without the commit
#   rust-cache         the `ci` job uses rust-cache
#   install-args       the `ci` job's mise-action installs every mise.toml
#                      tool the gate runs (MISE_AUTO_INSTALL is false)
#   secrets-scan       the `secrets-scan` job checks out the full history
#                      and runs `mise run secrets-scan`
#   elan-version       tools/ci/install-elan.sh pins the Dockerfile's elan
#   build-gating       a `build-id` job that needs exactly `ci`, and a
#                      `build` job that needs `ci` and `build-id`, both on
#                      main pushes only; `build` calls build.yml with the
#                      ID, `github.sha` as commit and ref, and the token
#                      reading contents only. The input names are
#                      actionlint's to check: it validates a local reusable
#                      workflow's `with:` against its inputs
#   release-gating     a `release` job that needs ci, build-id, build and
#                      secrets-scan, on main pushes only, calling
#                      release.yml with the ID and `github.sha` as commit
#                      and ref, with permissions exactly contents: write,
#                      pages: write and id-token: write (the union of
#                      release.yml's jobs': a called job can't exceed it)
#   release-concurrency  the `release` job's concurrency is exactly the
#                      group nightly-release, never cancelled in progress
#   write-scope        the top-level permissions are exactly contents:
#                      read, and no job but `release` names a write scope
#
# build.yml:
#
#   build-trigger      `workflow_call` alone, with exactly the inputs
#                      build-id, commit and ref, each a required string
#   build-job          one job, `build`, on macos-26, a leg of ci.yml's
#                      matrix, with LEANMACS_BUILD_ID and LEANMACS_COMMIT
#                      from the inputs, no MISE_ENV, and a checkout of the
#                      `ref` input
#   build-steps        `mise run app-check`, `dmg` and `dmg-check`, each in
#                      exactly one step, in that order, unconditionally, and
#                      last an upload-artifact of dist/*.dmg that fails
#                      when there is none, unconditionally
#   build-cache        no cache save, and the Lake and elan restores have
#                      ci.yml's keys (and Lake's restore-keys)
#
# release.yml:
#
#   release-trigger    `workflow_call` alone, with exactly the inputs
#                      build-id, commit and ref, each a required string
#   release-job        two jobs, `publish` and `pages`; `publish` on
#                      macos-26, a leg of ci.yml's matrix; top-level
#                      permissions {} and `publish`'s exactly
#                      contents: write; LEANMACS_BUILD_ID and
#                      LEANMACS_COMMIT from the inputs, no MISE_ENV; one
#                      checkout of the `ref` input, and every checkout
#                      with persist-credentials false
#   release-steps      one download-artifact of Leanmacs-dmg into dist,
#                      then exactly one `mise run nightly`, and last, once,
#                      `target/debug/leanmacs-release publish
#                      target/nightly`; no step has an if:, and no step
#                      runs gh release, gh api, git push or git tag
#   release-token      exactly one step names GH_TOKEN or GITHUB_TOKEN in
#                      its env, and its run is the publish command; no
#                      token in the job's or the workflow's env; and no
#                      value but that one names github.token or secrets.
#                      (where it falls among the steps is release-steps')
#   release-cache      no rust-cache and no actions/cache step: the only
#                      cache is mise-action's, saved from main only
#   release-page       `publish` renders the page in exactly one step,
#                      `mise run site -- target/nightly/build.json
#                      target/site`, after `mise run nightly`, and uploads
#                      it in exactly one actions/upload-pages-artifact of
#                      target/site, after the render (that the publish
#                      stays last is release-steps')
#   pages-job          `pages` needs exactly publish, has no if:, runs on a
#                      leg of ci.yml's matrix, with permissions exactly
#                      pages: write and id-token: write, in the
#                      github-pages environment, and has one step: an
#                      actions/deploy-pages with id deployment
#   pages-concurrency  `pages`' concurrency is exactly the group pages,
#                      never cancelled in progress
#
# stress.yml:
#
#   stress-trigger     `workflow_dispatch` alone, so a push never runs it,
#                      with the one input `rounds`
#   stress-runner      the `stress` job runs on `${{ matrix.os }}`, its
#                      matrix's os exactly ci.yml's legs, and every other
#                      job on a leg of ci.yml's matrix
#   stress-matrix      the `stress` job's matrix is exactly os × shard: [1,
#                      2, 3, 4, 5], with fail-fast off
#   stress-steps       the `stress` job runs `mise run ci` in exactly one
#                      step, with no if:, and after it exactly one step
#                      that runs tools/stress.sh on its rounds alone,
#                      naming no suite, so the loop runs the script's
#                      default, the wiring set
#   stress-summary     a `summary` job that needs exactly `stress` and adds
#                      up the counts for each of ci.yml's legs (its env
#                      LEGS)
#
# The other files, ci.yml for build.yml's and release.yml's rules among
# them, are read from
# this checkout, found from the script's own place. It prints every rule
# broken, then exits 1; 0 when none is.
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

name=$(basename "$wf")
# ci.yml, which build.yml's rules compare it with.
ci_wf="$root/.github/workflows/ci.yml"

# ==== The rules every workflow file holds.

# ---- continue-on-error
if [ "$(q '[.jobs[] | select(has("continue-on-error"))] + [.jobs[].steps[]? | select(has("continue-on-error"))] | length')" != 0 ]; then
  fail continue-on-error 'no job or step may set continue-on-error'
fi

# ---- mise-env
# A job that calls a reusable workflow (a job-level `uses:`) cannot set
# env; the called workflow's own jobs are checked in its own file.
bad=$(q '[.jobs | to_entries[] | select(.value | has("uses") | not) | select((.value.env.MISE_AUTO_INSTALL | tag) != "!!str" or .value.env.MISE_AUTO_INSTALL != "false") | .key] | join(" ")')
if [ -n "$bad" ]; then
  fail mise-env "jobs without env MISE_AUTO_INSTALL: \"false\": $bad"
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
# Each save's key and path must be a restore's in the same job. yq makes
# `[]` of a job with none, which `select(length == 2)` drops.
for job in $(q '.jobs | keys | .[]' | tr -d '"'); do
  restores=$(J=$job yq -o=json -I=0 '.jobs[strenv(J)].steps[]? | select(.uses // "" | test("^actions/cache/restore@")) | [.with.key, .with.path] | select(length == 2)' "$wf")
  J=$job yq -o=json -I=0 '.jobs[strenv(J)].steps[]? | select(.uses // "" | test("^actions/cache/save@")) | [.with.key, .with.path] | select(length == 2)' "$wf" |
    while IFS= read -r pair; do
      if ! printf '%s\n' "$restores" | grep -qxF "$pair"; then
        printf 'workflow-check: cache-keys: a save in job %s has no restore with the same key and path: %s\n' "$job" "$pair" >&2
        echo x
      fi
    done | grep -q x && failed=1
done

# ---- rust-cache
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

# ==== ci.yml's rules.
ci_rules() {
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

  # ---- rust-cache (ci.yml uses it)
  if [ "$(q '[.jobs.ci.steps[]? | select(.uses // "" | test("^Swatinem/rust-cache@"))] | length')" = 0 ]; then
    fail rust-cache 'jobs.ci must use Swatinem/rust-cache'
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
  #   aqua:junegunn/fzf       `mise run find-file-bench`, never run in CI; the
  #                           gate's checks stand a fixture in for it
  not_in_gate='hk pkl aqua:gitleaks/gitleaks opentofu aqua:junegunn/fzf'
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

  # ---- elan-version
  ci_elan=$(sed -n 's/^ELAN_VERSION=//p' "$root/tools/ci/install-elan.sh")
  docker_elan=$(sed -n 's/^ARG ELAN_VERSION=//p' "$root/tools/linux/Dockerfile")
  if [ -z "$ci_elan" ] || [ "$ci_elan" != "$docker_elan" ]; then
    fail elan-version "tools/ci/install-elan.sh pins elan '$ci_elan', the Dockerfile '$docker_elan'"
  fi

  # ---- build-gating
  # The build-id and build jobs run on main pushes only, after the gate; the
  # build is build.yml, handed the run's ID and commit. That the input names
  # are build.yml's is actionlint's check: it validates a local reusable
  # workflow's `with:` against its inputs.
  main_push="\${{ github.event_name == 'push' && github.ref == 'refs/heads/main' }}"
  export main_push
  if [ "$(q '.jobs | has("build-id")')" != true ]; then
    fail build-gating 'jobs must have build-id'
  else
    if [ "$(q '[.jobs["build-id"].needs] | flatten')" != '["ci"]' ]; then
      fail build-gating 'jobs.build-id.needs must be exactly ci'
    fi
    if [ "$(q '.jobs["build-id"].if == strenv(main_push)')" != true ]; then
      fail build-gating "jobs.build-id.if must be $main_push"
    fi
  fi
  if [ "$(q '.jobs | has("build")')" != true ]; then
    fail build-gating 'jobs must have build'
  else
    if [ "$(q '[.jobs.build.needs] | flatten | (contains(["ci"]) and contains(["build-id"]))')" != true ]; then
      fail build-gating 'jobs.build.needs must include ci and build-id'
    fi
    if [ "$(q '.jobs.build.if == strenv(main_push)')" != true ]; then
      fail build-gating "jobs.build.if must be $main_push"
    fi
    if [ "$(q '.jobs.build.uses')" != ./.github/workflows/build.yml ]; then
      fail build-gating 'jobs.build.uses must be ./.github/workflows/build.yml'
    fi
    if [ "$(q '.jobs.build.with["build-id"]')" != "\${{ needs.build-id.outputs.id }}" ]; then
      fail build-gating 'jobs.build.with.build-id must be ${{ needs.build-id.outputs.id }}'
    fi
    for input in commit ref; do
      if [ "$(I=$input yq '.jobs.build.with[strenv(I)]' "$wf")" != "\${{ github.sha }}" ]; then
        fail build-gating "jobs.build.with.$input must be \${{ github.sha }}"
      fi
    done
    if [ "$(q '.jobs.build.permissions')" != '{"contents":"read"}' ]; then
      fail build-gating 'jobs.build.permissions must be exactly contents: read'
    fi
  fi

  # ---- release-gating
  # The nightly is published on main pushes only, after the gate, the build
  # and the secret scan, by release.yml handed the run's ID and commit.
  if [ "$(q '.jobs | has("release")')" != true ]; then
    fail release-gating 'jobs must have release'
  else
    if [ "$(q '[.jobs.release.needs] | flatten | (contains(["ci"]) and contains(["build-id"]) and contains(["build"]) and contains(["secrets-scan"]))')" != true ]; then
      fail release-gating 'jobs.release.needs must include ci, build-id, build and secrets-scan'
    fi
    if [ "$(q '.jobs.release.if == strenv(main_push)')" != true ]; then
      fail release-gating "jobs.release.if must be $main_push"
    fi
    if [ "$(q '.jobs.release.uses')" != ./.github/workflows/release.yml ]; then
      fail release-gating 'jobs.release.uses must be ./.github/workflows/release.yml'
    fi
    if [ "$(q '.jobs.release.with["build-id"]')" != "\${{ needs.build-id.outputs.id }}" ]; then
      fail release-gating 'jobs.release.with.build-id must be ${{ needs.build-id.outputs.id }}'
    fi
    for input in commit ref; do
      if [ "$(I=$input yq '.jobs.release.with[strenv(I)]' "$wf")" != "\${{ github.sha }}" ]; then
        fail release-gating "jobs.release.with.$input must be \${{ github.sha }}"
      fi
    done
    if [ "$(q '.jobs.release.permissions | to_entries | sort_by(.key) | from_entries')" != '{"contents":"write","id-token":"write","pages":"write"}' ]; then
      fail release-gating 'jobs.release.permissions must be exactly contents: write, pages: write and id-token: write'
    fi
  fi

  # ---- release-concurrency
  # Two nightlies never publish at once, and one is never cut off halfway.
  if [ "$(q '.jobs.release.concurrency')" != '{"group":"nightly-release","cancel-in-progress":false}' ]; then
    fail release-concurrency 'jobs.release.concurrency must be exactly group: nightly-release, cancel-in-progress: false'
  fi

  # ---- write-scope
  # The token reads by default, and only `release` may write.
  if [ "$(q '.permissions')" != '{"contents":"read"}' ]; then
    fail write-scope 'the top-level permissions must be exactly contents: read'
  fi
  bad=$(q '[.jobs | to_entries[] | select(.key != "release") | select(.value.permissions // {} | tojson | test("write")) | .key] | join(" ")')
  if [ -n "$bad" ]; then
    fail write-scope "jobs other than release name a write scope: $bad"
  fi
}

# ==== build.yml's rules.
build_rules() {
  # ---- build-trigger
  # Called by ci.yml alone, with exactly its three string inputs, each
  # required.
  if [ "$(q '.on | keys')" != '["workflow_call"]' ]; then
    fail build-trigger 'on: must be workflow_call alone'
  fi
  if [ "$(q '.on.workflow_call.inputs | keys | sort')" != '["build-id","commit","ref"]' ]; then
    fail build-trigger 'on.workflow_call.inputs must be exactly build-id, commit and ref'
  fi
  bad=$(q '[.on.workflow_call.inputs // {} | to_entries[] | select(.value.required != true or .value.type != "string") | .key] | join(" ")')
  if [ -n "$bad" ]; then
    fail build-trigger "inputs not required: true and type: string: $bad"
  fi

  # ---- build-job
  # One job, on a leg of ci.yml's matrix, stamped from the inputs, building
  # the commit it is handed.
  if [ "$(q '.jobs | keys')" != '["build"]' ]; then
    fail build-job 'jobs must be exactly build'
  fi
  runs_on=$(q '.jobs.build["runs-on"]')
  if [ "$runs_on" != macos-26 ]; then
    fail build-job "jobs.build.runs-on must be macos-26, not $runs_on"
  elif [ "$(R=$runs_on yq '.jobs.ci.strategy.matrix.os | contains([strenv(R)])' "$ci_wf")" != true ]; then
    fail build-job "jobs.build.runs-on $runs_on is not a leg of ci.yml's matrix"
  fi
  if [ "$(q '.jobs.build.env.LEANMACS_BUILD_ID')" != "\${{ inputs.build-id }}" ]; then
    fail build-job 'jobs.build.env.LEANMACS_BUILD_ID must be ${{ inputs.build-id }}'
  fi
  if [ "$(q '.jobs.build.env.LEANMACS_COMMIT')" != "\${{ inputs.commit }}" ]; then
    fail build-job 'jobs.build.env.LEANMACS_COMMIT must be ${{ inputs.commit }}'
  fi
  if [ "$(q '.jobs.build.env // {} | has("MISE_ENV")')" != false ]; then
    fail build-job 'jobs.build.env must not set MISE_ENV'
  fi
  if [ "$(q '[.jobs.build.steps[]? | select((.uses // "" | test("^actions/checkout@")) and .with.ref == "${{ inputs.ref }}")] | length')" != 1 ]; then
    fail build-job 'jobs.build must check out with ref: ${{ inputs.ref }}'
  fi

  # ---- build-steps
  # app-check, then the dmg, then its check, each once and unconditional,
  # and last the upload, which fails when there is no .dmg.
  last=-1
  for task in app-check dmg dmg-check; do
    export run="mise run $task"
    if [ "$(q '[.jobs.build.steps[]? | select(.run == strenv(run))] | length')" != 1 ]; then
      fail build-steps "jobs.build must have exactly one step whose run is \`$run\`"
      continue
    fi
    if [ "$(q '[.jobs.build.steps[]? | select(.run == strenv(run) and has("if"))] | length')" != 0 ]; then
      fail build-steps "the \`$run\` step must have no if:"
    fi
    at=$(q '.jobs.build.steps | to_entries | .[] | select(.value.run == strenv(run)) | .key')
    if [ "$at" -le "$last" ]; then
      fail build-steps "the \`$run\` step must come after the one before it (app-check, dmg, dmg-check)"
    fi
    last=$at
  done
  if [ "$(q '.jobs.build.steps[-1] | [(.uses // "" | test("^actions/upload-artifact@")), .with.path == "dist/*.dmg", .with["if-no-files-found"] == "error", (has("if") | not)] | all')" != true ]; then
    fail build-steps 'the last step of jobs.build must be actions/upload-artifact of dist/*.dmg, with if-no-files-found: error and no if:'
  fi

  # ---- build-cache
  # Restores ci.yml's elan and Lake entries, with ci.yml's keys, and saves
  # nothing: lean/.lake holds the bundle here, which must not enter the
  # cache.
  if [ "$(q '[.jobs[].steps[]? | select(.uses // "" | test("^actions/cache/save@"))] | length')" != 0 ]; then
    fail build-cache 'build.yml must have no actions/cache/save step'
  fi
  # restore_of <file> <path> <field>: the field of the job's one restore of
  # <path> in <file>, the `ci` job's in ci.yml.
  restore_of() {
    P=$2 F=$3 yq '[.jobs[].steps[]? | select((.uses // "" | test("^actions/cache/restore@")) and .with.path == strenv(P))] | select(length == 1) | .[0].with[strenv(F)]' "$1"
  }
  for pair in 'lean/.lake key' 'lean/.lake restore-keys' '~/.elan key'; do
    path=${pair% *} field=${pair#* }
    mine=$(restore_of "$wf" "$path" "$field")
    theirs=$(restore_of "$ci_wf" "$path" "$field")
    if [ -z "$mine" ] || [ "$mine" = null ] || [ "$mine" != "$theirs" ]; then
      fail build-cache "the one restore of $path must have ci.yml's $field"
    fi
  done
}

# ==== release.yml's rules.
release_rules() {
  # ---- release-trigger
  # Called by ci.yml alone, with exactly its three string inputs, each
  # required.
  if [ "$(q '.on | keys')" != '["workflow_call"]' ]; then
    fail release-trigger 'on: must be workflow_call alone'
  fi
  if [ "$(q '.on.workflow_call.inputs | keys | sort')" != '["build-id","commit","ref"]' ]; then
    fail release-trigger 'on.workflow_call.inputs must be exactly build-id, commit and ref'
  fi
  bad=$(q '[.on.workflow_call.inputs // {} | to_entries[] | select(.value.required != true or .value.type != "string") | .key] | join(" ")')
  if [ -n "$bad" ]; then
    fail release-trigger "inputs not required: true and type: string: $bad"
  fi

  # ---- release-job
  # The publish and the page's deploy. `publish` runs on a leg of ci.yml's
  # matrix, writing contents alone, stamped from the inputs, with no
  # credentials left on disk; `pages` is pages-job's.
  if [ "$(q '.jobs | keys | sort')" != '["pages","publish"]' ]; then
    fail release-job 'jobs must be exactly pages and publish'
  fi
  runs_on=$(q '.jobs.publish["runs-on"]')
  if [ "$runs_on" != macos-26 ]; then
    fail release-job "jobs.publish.runs-on must be macos-26, not $runs_on"
  elif [ "$(R=$runs_on yq '.jobs.ci.strategy.matrix.os | contains([strenv(R)])' "$ci_wf")" != true ]; then
    fail release-job "jobs.publish.runs-on $runs_on is not a leg of ci.yml's matrix"
  fi
  if [ "$(q '.permissions')" != '{}' ]; then
    fail release-job 'the top-level permissions must be {}'
  fi
  if [ "$(q '.jobs.publish.permissions')" != '{"contents":"write"}' ]; then
    fail release-job 'jobs.publish.permissions must be exactly contents: write'
  fi
  if [ "$(q '.jobs.publish.env.LEANMACS_BUILD_ID')" != "\${{ inputs.build-id }}" ]; then
    fail release-job 'jobs.publish.env.LEANMACS_BUILD_ID must be ${{ inputs.build-id }}'
  fi
  if [ "$(q '.jobs.publish.env.LEANMACS_COMMIT')" != "\${{ inputs.commit }}" ]; then
    fail release-job 'jobs.publish.env.LEANMACS_COMMIT must be ${{ inputs.commit }}'
  fi
  if [ "$(q '.jobs.publish.env // {} | has("MISE_ENV")')" != false ]; then
    fail release-job 'jobs.publish.env must not set MISE_ENV'
  fi
  if [ "$(q '[.jobs.publish.steps[]? | select(.uses // "" | test("^actions/checkout@"))] | length')" != 1 ] ||
    [ "$(q '[.jobs.publish.steps[]? | select((.uses // "" | test("^actions/checkout@")) and .with.ref == "${{ inputs.ref }}")] | length')" != 1 ]; then
    fail release-job 'jobs.publish must check out once, with ref: ${{ inputs.ref }}'
  fi
  if [ "$(q '[.jobs[].steps[]? | select(.uses // "" | test("^actions/checkout@")) | select(.with["persist-credentials"] != false)] | length')" != 0 ]; then
    fail release-job 'every checkout must have persist-credentials: false'
  fi

  # ---- release-steps
  # The .dmg, then every check with no token, and last the one publish; any
  # failure stops the job before it.
  publish_run='target/debug/leanmacs-release publish target/nightly'
  export publish_run
  download=$(q '[.jobs.publish.steps | to_entries | .[] | select((.value.uses // "" | test("^actions/download-artifact@")) and .value.with.name == "Leanmacs-dmg" and .value.with.path == "dist") | .key] | join(" ")')
  prepare=$(q '[.jobs.publish.steps | to_entries | .[] | select(.value.run == "mise run nightly") | .key] | join(" ")')
  case $download in
  '' | *' '*) fail release-steps 'jobs.publish must have exactly one actions/download-artifact of Leanmacs-dmg into dist' ;;
  esac
  case $prepare in
  '' | *' '*) fail release-steps 'jobs.publish must have exactly one step whose run is `mise run nightly`' ;;
  *)
    case $download in
    '' | *' '*) ;;
    *)
      if [ "$download" -ge "$prepare" ]; then
        fail release-steps 'the download of Leanmacs-dmg must come before `mise run nightly`'
      fi
      ;;
    esac
    ;;
  esac
  if [ "$(q '[.jobs.publish.steps[]? | select(.run == strenv(publish_run))] | length')" != 1 ] ||
    [ "$(q '.jobs.publish.steps[-1].run == strenv(publish_run)')" != true ]; then
    fail release-steps "the last step of jobs.publish, and only it, must run \`$publish_run\`"
  fi
  if [ "$(q '[.jobs.publish.steps[]? | select(has("if"))] | length')" != 0 ]; then
    fail release-steps 'no step of jobs.publish may have an if:'
  fi
  if [ "$(q '[.jobs.publish.steps[]? | select(.run // "" | test("gh +release|gh +api|git +push|git +tag"))] | length')" != 0 ]; then
    fail release-steps 'no step may run gh release, gh api, git push or git tag: the publish command does'
  fi

  # ---- release-token
  # The token is in one step's env alone, and that step runs the publish.
  # Where it falls among the steps is release-steps'.
  token_steps='[.jobs.publish.steps[]? | select(.env // {} | (has("GH_TOKEN") or has("GITHUB_TOKEN")))]'
  if [ "$(q "$token_steps | length")" != 1 ] ||
    [ "$(q "$token_steps | .[0].run == strenv(publish_run)")" != true ]; then
    fail release-token "exactly one step may name GH_TOKEN or GITHUB_TOKEN in its env, the one that runs \`$publish_run\`"
  fi
  if [ "$(q '[.env // {}, .jobs[].env // {}] | map(has("GH_TOKEN") or has("GITHUB_TOKEN")) | any')" != false ]; then
    fail release-token 'no token in the workflow'"'"'s or the job'"'"'s env'
  fi
  if [ "$(q '[.. | select(tag == "!!str") | select(test("github[.]token|secrets[.]"))] | length')" != 1 ]; then
    fail release-token 'exactly one value may name github.token or secrets.: the publish step'"'"'s GH_TOKEN'
  fi

  # ---- release-cache
  # The token-holding job restores no build cache. mise-action's tool cache
  # stays, saved from main only (the common mise-action rule).
  if [ "$(q '[.jobs[].steps[]? | select(.uses // "" | test("^(Swatinem/rust-cache|actions/cache)(/[a-z]+)?@"))] | length')" != 0 ]; then
    fail release-cache 'release.yml must have no rust-cache and no actions/cache step'
  fi

  # ---- release-page
  # The page is rendered from the build.json `nightly` prepared in this job,
  # the one the publish uploads, and uploaded for `pages`, both before the
  # publish (release-steps keeps that last).
  render_run='mise run site -- target/nightly/build.json target/site'
  export render_run
  render=$(q '[.jobs.publish.steps | to_entries | .[] | select(.value.run == strenv(render_run)) | .key] | join(" ")')
  upload=$(q '[.jobs.publish.steps | to_entries | .[] | select(.value.uses // "" | test("^actions/upload-pages-artifact@")) | .key] | join(" ")')
  upload_path=$(q '[.jobs.publish.steps[]? | select(.uses // "" | test("^actions/upload-pages-artifact@")) | .with.path] | join(" ")')
  case $render in
  '' | *' '*) fail release-page "jobs.publish must have exactly one step whose run is \`$render_run\`" ;;
  *)
    case $prepare in
    '' | *' '*) ;;
    *)
      if [ "$render" -le "$prepare" ]; then
        fail release-page "the \`$render_run\` step must come after \`mise run nightly\`"
      fi
      ;;
    esac
    ;;
  esac
  case $upload in
  '' | *' '*) fail release-page 'jobs.publish must have exactly one actions/upload-pages-artifact' ;;
  *)
    if [ "$upload_path" != target/site ]; then
      fail release-page "the actions/upload-pages-artifact step's path must be target/site, not $upload_path"
    fi
    case $render in
    '' | *' '*) ;;
    *)
      if [ "$upload" -le "$render" ]; then
        fail release-page "the actions/upload-pages-artifact step must come after \`$render_run\`"
      fi
      ;;
    esac
    ;;
  esac

  # ---- pages-job
  # Deploys only what a successful publish uploaded, with the two scopes
  # deploy-pages needs and nothing else, into the main-only environment,
  # running one GitHub-owned action and no code of this repository.
  if [ "$(q '.jobs | has("pages")')" != true ]; then
    fail pages-job 'jobs must have pages'
  else
    if [ "$(q '[.jobs.pages.needs] | flatten')" != '["publish"]' ]; then
      fail pages-job 'jobs.pages.needs must be exactly publish'
    fi
    if [ "$(q '.jobs.pages | has("if")')" != false ]; then
      fail pages-job 'jobs.pages must have no if:, so it never deploys after a failed publish'
    fi
    pages_on=$(q '.jobs.pages["runs-on"]')
    if [ "$(R=$pages_on yq '.jobs.ci.strategy.matrix.os | contains([strenv(R)])' "$ci_wf")" != true ]; then
      fail pages-job "jobs.pages.runs-on $pages_on is not a leg of ci.yml's matrix"
    fi
    if [ "$(q '.jobs.pages.permissions // {} | to_entries | sort_by(.key) | from_entries')" != '{"id-token":"write","pages":"write"}' ]; then
      fail pages-job 'jobs.pages.permissions must be exactly pages: write and id-token: write'
    fi
    if [ "$(q '.jobs.pages.environment.name')" != github-pages ]; then
      fail pages-job 'jobs.pages.environment.name must be github-pages'
    fi
    if [ "$(q '[.jobs.pages.steps[]?] | length')" != 1 ] ||
      [ "$(q '.jobs.pages.steps[0] | ((.uses // "" | test("^actions/deploy-pages@")) and .id == "deployment")')" != true ]; then
      fail pages-job 'jobs.pages must have exactly one step, an actions/deploy-pages with id: deployment, and no checkout'
    fi
  fi

  # ---- pages-concurrency
  # One deploy at a time, never cut off halfway.
  if [ "$(q '.jobs.pages.concurrency')" != '{"group":"pages","cancel-in-progress":false}' ]; then
    fail pages-concurrency 'jobs.pages.concurrency must be exactly group: pages, cancel-in-progress: false'
  fi
}

# ==== stress.yml's rules.
stress_rules() {
  # ---- stress-trigger
  if [ "$(q '.on | keys')" != '["workflow_dispatch"]' ]; then
    fail stress-trigger 'on: must be workflow_dispatch alone'
  elif [ "$(q '.on.workflow_dispatch.inputs // {} | keys')" != '["rounds"]' ]; then
    fail stress-trigger 'workflow_dispatch must have exactly the input rounds'
  fi

  # ---- stress-runner
  # The shards on each of the gate's legs, ci.yml's, and the summary on one.
  legs=$(yq -o=json -I=0 '.jobs.ci.strategy.matrix.os' "$ci_wf")
  if [ "$(q '.jobs.stress["runs-on"]')" != "\${{ matrix.os }}" ]; then
    fail stress-runner 'jobs.stress.runs-on must be ${{ matrix.os }}'
  fi
  if [ "$(q '.jobs.stress.strategy.matrix.os')" != "$legs" ]; then
    fail stress-runner "jobs.stress.strategy.matrix.os must be exactly ci.yml's legs, $legs"
  fi
  for job in $(q '.jobs | keys | .[]'); do
    [ "$job" != stress ] || continue
    on=$(J=$job q '.jobs[strenv(J)]["runs-on"]')
    if [ "$(R=$on yq '.jobs.ci.strategy.matrix.os | contains([strenv(R)])' "$ci_wf")" != true ]; then
      fail stress-runner "jobs.$job.runs-on $on is not a leg of ci.yml's matrix"
    fi
  done

  # ---- stress-matrix
  if [ "$(q '.jobs.stress.strategy.matrix | keys')" != '["os","shard"]' ] ||
    [ "$(q '.jobs.stress.strategy.matrix.shard')" != '[1,2,3,4,5]' ]; then
    fail stress-matrix 'jobs.stress.strategy.matrix must be exactly os and shard: [1, 2, 3, 4, 5]'
  fi
  if [ "$(q '.jobs.stress.strategy["fail-fast"]')" != false ]; then
    fail stress-matrix 'jobs.stress.strategy["fail-fast"] must be false'
  fi

  # ---- stress-steps
  # The loop on its rounds alone, a fifth of them a shard: what follows the
  # rounds is the pipe to tee or the end of the line, never a suite.
  gate_at=$(q '[.jobs.stress.steps | to_entries[] | select(.value.run == "mise run ci") | .key] | join(" ")')
  loop_at=$(q '[.jobs.stress.steps | to_entries[] | select(.value.run // "" | test("sh tools/stress.sh ")) | .key] | join(" ")')
  case "$gate_at $loop_at" in
  ' '* | *' ' | *' '*' '*)
    fail stress-steps 'jobs.stress must have exactly one `mise run ci` step and exactly one tools/stress.sh step'
    ;;
  *)
    if [ "$loop_at" -le "$gate_at" ]; then
      fail stress-steps 'the tools/stress.sh step must come after `mise run ci`'
    fi
    if [ "$(q '[.jobs.stress.steps[]? | select(.run == "mise run ci" and has("if"))] | length')" != 0 ]; then
      fail stress-steps 'the `mise run ci` step must have no if:'
    fi
    if [ "$(q '[.jobs.stress.steps[]? | select(.run // "" | test("(?m)sh tools/stress.sh \\$\\(\\(ROUNDS / 5\\)\\) *(\\||$)"))] | length')" != 1 ]; then
      fail stress-steps 'the tools/stress.sh step must name its rounds alone and no suite, so the loop runs the wiring set'
    fi
    ;;
  esac

  # ---- stress-summary
  if [ "$(q '[.jobs.summary.needs] | flatten')" != '["stress"]' ]; then
    fail stress-summary 'jobs.summary.needs must be exactly stress'
  fi
  if [ "$(q '.jobs.summary.env.LEGS')" != "$(yq '.jobs.ci.strategy.matrix.os | join(" ")' "$ci_wf")" ]; then
    fail stress-summary "jobs.summary.env.LEGS must be ci.yml's legs, $(yq '.jobs.ci.strategy.matrix.os | join(" ")' "$ci_wf")"
  fi
}

# ---- workflows
# Every workflow file has its rules here, so a new one cannot go unchecked.
case $name in
ci.yml) ci_rules ;;
build.yml) build_rules ;;
release.yml) release_rules ;;
stress.yml) stress_rules ;;
*) fail workflows "no rules for $name: add them to tools/workflow-check.sh" ;;
esac

if [ -n "$failed" ]; then
  exit 1
fi
printf 'workflow-check: %s holds every rule\n' "$wf" >&2
