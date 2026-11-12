#!/usr/bin/env bash
# Runs the gate on Linux, in a container (`mise run linux-ci`; README.md,
# "The gate on Linux"). Opt-in, never part of `ci`: it needs Docker and, the
# first time, the network.
#
#   tools/linux/run.sh ci [--clean]
#
# It builds the image from the Dockerfile beside it, copies the checkout into
# a work directory and runs `mise run ci` there. Its exit status is the
# gate's.
#
# The source is copied, never mounted in place: the tracked files and the
# untracked files git does not ignore, so uncommitted work is tested and the
# host's own build output (`target/`, `lean/.lake/`) is never touched.
#
# Where state lives:
#
# - `${EDITOR_LINUX_CACHE:-.linux-ci}`, a directory of the host at the root of
#   the checkout (ignored by git): `home/` holds the toolchains (rustup's,
#   elan's, mise's installs) and `work/` the copy of the source with Lake's
#   build output. It is not under `target/`, so `cargo clean` leaves it alone.
# - The Docker volume `${EDITOR_LINUX_VOLUME:-editor-linux-ci-cargo}`: Cargo's
#   home and Cargo's `target/`. These two must not be on a directory mounted
#   from macOS. With them there, clean runs of the gate failed within seconds
#   once the dependency graph was large (`failed to map object file`, `failed
#   to create encoded metadata from file`); `ci` runs `lint`, `doc` and `test`
#   at once, and file locks do not seem to hold on that mount.
#
# `--clean` empties the copy's `lean/.lake/build/` and Cargo's `target/` before
# the gate runs, and keeps the toolchains and Cargo's registry: everything is
# compiled again and nothing is downloaded again.
#
# The same file is the script that runs inside the container (`inside …`),
# where it is read from the copy.

set -euo pipefail

die() {
  echo "linux: $*" >&2
  exit 1
}

usage() {
  die "usage: tools/linux/run.sh ci [--clean]"
}

# ---- Inside the container ----

# Points the copy's `target/` at the volume, makes the copy a git repository
# of its own (the `c-fmt` task lists files with `git ls-files`) and installs
# the tools `mise.toml` pins.
inside_prepare() {
  mkdir -p /cargo/home /cargo/target
  if [ ! -L /work/target ]; then
    rm -rf /work/target
    ln -s /cargo/target /work/target
  fi
  cd /work
  git config --global --add safe.directory /work
  [ -d .git ] || git init -q
  git add -A
  mise install
}

# One line that says what the gate ran on.
inside_versions() {
  echo "linux: $(uname -m); $(gcc --version | head -n 1); $(ld --version | head -n 1); $(ldd --version | head -n 1)"
  echo "linux: $(cd /work/lean && lean --version)"
  echo "linux: $(mise exec -- rustc --version); mise $(mise --version 2>/dev/null | head -n 1); $(elan --version)"
}

inside_ci() {
  local clean=no
  for arg in "$@"; do
    case "$arg" in
    --clean) clean=yes ;;
    *) usage ;;
    esac
  done

  inside_prepare
  if [ "$clean" = yes ]; then
    rm -rf /work/lean/.lake/build
    find /cargo/target -mindepth 1 -delete
  fi
  inside_versions

  local start status=0
  start=$(date +%s)
  mise run ci || status=$?
  echo "linux: \`mise run ci\` exited $status after $(($(date +%s) - start)) s (clean build: $clean)"
  if [ "$status" -eq 0 ]; then
    (cd /work/lean/.lake/build/bin && ls -l editor ffi-test config-test contract-test model-test)
    ldd /work/lean/.lake/build/bin/editor
  fi
  return "$status"
}

# ---- On the host ----

# Makes `$cache/work` a copy of the checkout: the tracked files and the
# untracked files git does not ignore, with their modification times, so a
# file that did not change is not rebuilt. What an earlier run left that is
# no longer in the checkout is removed; the build output is kept.
copy_source() {
  local root=$1 work=$2 list
  mkdir -p "$work/lean"
  find "$work" -mindepth 1 -maxdepth 1 \
    ! -name .git ! -name lean ! -name target -exec rm -rf {} +
  find "$work/lean" -mindepth 1 -maxdepth 1 ! -name .lake -exec rm -rf {} +

  list=$(mktemp)
  # A file deleted from the working tree but not yet from the index is still
  # listed, so each name is checked.
  git -C "$root" ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' file; do
      if [ -e "$root/$file" ]; then printf '%s\0' "$file"; fi
    done >"$list"
  tar -C "$root" --null -T "$list" -cf - | tar -C "$work" -xpf -
  rm -f "$list"
}

on_host() {
  local mode=$1
  shift
  local here root cache image volume
  here=$(cd "$(dirname "$0")" && pwd)
  root=$(cd "$here/../.." && pwd)
  cache=${EDITOR_LINUX_CACHE:-$root/.linux-ci}
  image=${EDITOR_LINUX_IMAGE:-editor-linux-ci}
  volume=${EDITOR_LINUX_VOLUME:-editor-linux-ci-cargo}

  command -v docker >/dev/null || die "docker is not installed; this task runs the gate in a container"
  docker info >/dev/null 2>&1 || die "Docker is not running; start it and run this again"
  docker build --tag "$image" "$here" ||
    die "the image could not be built from $here/Dockerfile"

  mkdir -p "$cache/home" "$cache/work"
  cache=$(cd "$cache" && pwd)
  copy_source "$root" "$cache/work"

  docker run --rm --init \
    --volume "$cache/work:/work" \
    --volume "$cache/home:/cache" \
    --volume "$volume:/cargo" \
    "$image" /work/tools/linux/run.sh inside "$mode" "$@"
}

[ $# -ge 1 ] || usage
case "$1" in
ci)
  on_host "$@"
  ;;
inside)
  shift
  [ $# -ge 1 ] || usage
  mode=$1
  shift
  case "$mode" in
  ci) inside_ci "$@" ;;
  *) usage ;;
  esac
  ;;
*)
  usage
  ;;
esac
