#!/bin/sh
# The app bundle with the toolchain, measured: `mise run bundle-bench`
# (docs/design/lean-runtime.md, "The bundle with the toolchain, measured";
# docs/dev-practices/on-demand-checks.md, "The bundle, measured on demand").
#
#   tools/bundle-bench.sh <app> <dmg>
#
# Opt-in, macOS on arm64 only, after `mise run app` and `mise run dmg`. It
# asserts nothing but that each run it times did what it times. It prints:
#
# 1. the bundle's bytes and files, by part: the toolchain
#    (`Contents/Resources/lean/toolchain`), the core and the default
#    packages (`lean/lean`, `lean/set`), the editor and the launcher
#    (`Contents/MacOS`), the Rust archive (`lean/target`), the link stubs
#    (`lean/link-stubs`), and the whole;
# 2. the disk image's bytes and its share of GitHub's 2 GiB release-asset
#    limit;
# 3. for headless runs of the bundle's launcher, with `env -i`, from a
#    temporary directory, on `tests/headless/generate` (a config of
#    `Editor` alone) and on `tests/headless/bundle` (a config that imports
#    `Lean`): the median real time of 5 and the largest maximum resident
#    set (`/usr/bin/time -l`); each run must install its config;
# 4. the time of the unchanged default set's user build from the bundle
#    (`lake -d <config> build :editorInstall` on the generated lakefile):
#    the first, which elaborates the core's lakefile, and a second, into
#    another directory;
# 5. the time of the build that installs `hello-init`, its require pointed
#    at the bundle's core, after `lake update`.
#
# Bytes are apparent sizes, summed from `stat -f %z`; MB are 10^6 bytes.
# Everything it writes is in a temporary directory, removed by a trap.
set -eu

[ "$(uname -s)" = Darwin ] || {
  echo "bundle-bench: macOS only" >&2
  exit 2
}
app=$(cd "$1" && pwd -P)
dmg=$2
repo=$(cd "$(dirname "$0")/.." && pwd -P)
resources=$app/Contents/Resources
lean=$resources/lean
launcher=$app/Contents/MacOS/leanmacs
lake=$lean/toolchain/bin/lake

work=$(mktemp -d)
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home"

mb() {
  awk -v b="$1" 'BEGIN { printf "%.1f", b / 1e6 }'
}
# The bytes and the files under each path given.
measure() {
  find "$@" -type f -print0 | xargs -0 stat -f %z | awk '{ s += $1; n += 1 } END { printf "%d %d\n", s, n }'
}
median() {
  sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }'
}
largest() {
  sort -n | tail -1
}
seconds() {
  awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'
}
now() {
  perl -MTime::HiRes=time -e 'printf "%.3f\n", time'
}

# 1. The bundle, by part.
part() {
  label=$1
  shift
  set -- $(measure "$@")
  echo "bundle-bench: $label: $(mb "$1") MB, $2 files"
}
part "the toolchain" "$lean/toolchain"
part "the core and the default packages" "$lean/lean" "$lean/set"
part "the editor and the launcher" "$app/Contents/MacOS"
part "the Rust archive" "$lean/target"
part "the link stubs" "$lean/link-stubs"
part "the whole bundle" "$app"

# 2. The disk image.
size=$(stat -f %z "$dmg")
echo "bundle-bench: the disk image: $size bytes ($(mb "$size") MB), $(awk -v s="$size" 'BEGIN { printf "%.1f", 100 * s / 2147483648 }')% of GitHub's 2 GiB release-asset limit"

# 3. Start-up and resident memory.
mkdir "$work/elsewhere"
for fixture in generate bundle; do
  : >"$work/real"
  : >"$work/rss"
  for _ in 1 2 3 4 5; do
    rm -rf "$work/config"
    cp -R "$repo/tests/headless/$fixture/config" "$work/config"
    (cd "$work/elsewhere" && /usr/bin/time -l env -i "$launcher" headless "$work/config" "$repo/tests/headless/$fixture/script") \
      >"$work/out" 2>"$work/time"
    grep -q '^reload 1: installed' "$work/out" || {
      echo "bundle-bench: the headless run on tests/headless/$fixture did not install its config" >&2
      exit 1
    }
    awk '/ real / { print $1 }' "$work/time" >>"$work/real"
    awk '/maximum resident set size/ { print $1 }' "$work/time" >>"$work/rss"
  done
  echo "bundle-bench: headless, env -i, tests/headless/$fixture, 5 runs: median real $(median <"$work/real") s; largest maximum resident set $(mb "$(largest <"$work/rss")") MB"
done

# 4. The unchanged default set, built from the bundle.
config=$work/set-config
mkdir "$config"
cp "$repo/tests/headless/generate/config/init.lean" "$config/init.lean"
(cd / && env -i HOME="$work/home" "$launcher" headless --generate "$config" "$repo/tests/headless/generate/script") >/dev/null
record=$(cat "$resources/editor.build")
build() {
  # shellcheck disable=SC2086 # the record's lines are NAME=value words
  env -i PATH=/usr/bin:/bin HOME="$work/home" EDITOR_INSTALL_DIR="$2" $record "$lake" -d "$1" build :editorInstall \
    >"$work/build.log" 2>&1 || {
    cat "$work/build.log" >&2
    echo "bundle-bench: the build of $1 failed" >&2
    exit 1
  }
}
started=$(now)
build "$config" "$work/install-1"
first=$(now)
build "$config" "$work/install-2"
second=$(now)
echo "bundle-bench: the unchanged default set's build from the bundle: first $(seconds "$started" "$first") s (with the core's lakefile elaborated), second $(seconds "$first" "$second") s"

# 5. hello-init's install build.
hello=$work/hello-init
cp -RL "$repo/tests/user-sets/hello-init" "$hello"
rm -rf "$hello/.lake"
sed "s|^path = \"../../../lean\"|path = \"$lean/lean\"|" "$repo/tests/user-sets/hello-init/lakefile.toml" >"$hello/lakefile.toml"
sed "s|\"dir\": \"../../../lean\"|\"dir\": \"$lean/lean\"|" "$repo/tests/user-sets/hello-init/lake-manifest.json" >"$hello/lake-manifest.json"
printf '\n[[require]]\nname = "hello-init"\npath = "%s"\n' "$hello" >>"$config/lakefile.toml"
# shellcheck disable=SC2086
env -i PATH=/usr/bin:/bin HOME="$work/home" $record "$lake" -d "$config" update --keep-toolchain hello-init >"$work/update.log" 2>&1 || {
  cat "$work/update.log" >&2
  echo "bundle-bench: lake update failed" >&2
  exit 1
}
started=$(now)
build "$config" "$work/install-3"
ended=$(now)
echo "bundle-bench: the build that installs hello-init from the bundle: $(seconds "$started" "$ended") s"
