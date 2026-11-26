#!/usr/bin/env bash
# What config may import, measured: `mise run module-bench`
# (docs/design/lean-runtime.md, "What config may import, measured").
#
# For each import set, `Editor` and `Editor Lean`, it prints:
#
# 1. the modules the import reads (`config-test bench-modules`), and the
#    bytes of each file kind, of whole top-level directories (the
#    toolchain's `Init` and `Std`, and `Lean` for the second set, and the
#    package's `Editor`) and of those modules alone, the closure;
# 2. which file kinds the import reads: it stages the whole directories in
#    a temporary directory with the `stage-bundle` binary
#    (crates/editor-release-std), with each kind set in
#    turn (`olean`; `olean olean.server`; `olean olean.server
#    olean.private`; and that with `ir ir.sig`), and runs
#    `config-test bench-start` on the staged directories. The smallest set
#    with which the base imports and its config loads is the set the import
#    needs; each failure's first line on stderr is printed;
# 3. with that kind set, the closure staged, five runs of `bench-start`
#    under `/usr/bin/time -l`: the median real time, import time and first
#    load, and the largest maximum resident set size.
#
# And once, after the set `Editor`, the bundle as it is shipped: five runs
# of a staged bundle's headless mode, with `env -i`, as the app runs
# it, on each of two configs: `tests/bench/generate`, whose root imports
# `Editor` alone, so the editor elaborates it on the base it starts with;
# and `tests/headless/bundle`, whose root imports `Lean`, so the base grows
# to hold it. For each, the median real time and the largest maximum
# resident set size. The editor it runs is the default package set's, whose
# config base is the set's and not `Editor` alone: `Editor`, then the entry
# module of each default package (docs/design/packages.md, "The config base
# of a set"). So that bundle is staged as the app's was before it shipped
# the whole toolchain (docs/design/lean-runtime.md, "What config may
# import, measured"): the closure of the set's base with `Std` and `Lean`,
# which a config file may import (`lake -d ../packages query :editorBase`),
# each module copied from the first of the directories the build recorded
# beside the editor that holds it (`editor.oleans`), with the kinds the set
# `Editor` was found to need, into the bundle's one directory
# `Contents/Resources/lean/editor`, which the `stage-bundle` binary's
# `--closure` mode names in the bundle's record, `editor.oleans`, so the
# staged editor finds its modules with no directory argument. Its modules
# and bytes are printed too. The app's own figures are
# `mise run bundle-bench`'s.
#
# Bytes are apparent sizes, summed from `stat -f %z`; MB are 10^6 bytes.
# Each headless run it times runs a script whose `installed` fails the run
# when its config did not install, so a rejected reload, which would be
# timed as if it were a start-up, stops the bench by its exit status
# (`timed` passes it on). Every temporary directory is removed by a trap. It is macOS only, as the
# app bundle is.
#
# `$1` is the Lean package's directory, where the built executables are.
set -euo pipefail

if [ "$(uname -s)" != Darwin ]; then
  echo "module-bench: macOS only" >&2
  exit 2
fi

lean_dir=$(cd "$1" && pwd)
fixtures=$(cd "$lean_dir/../tests/headless/bundle" && pwd)
repo=$(cd "$lean_dir/.." && pwd)
cargo build --quiet --locked --release --manifest-path "$repo/Cargo.toml" -p editor-release-std --bin stage-bundle
stage_bundle="$repo/target/release/stage-bundle"
editor="$lean_dir/../packages/.lake/build/bin/editor"
config_test="$lean_dir/.lake/build/bin/config-test"
sysroot=$(cd "$lean_dir" && lean --print-prefix)
toolchain_lib="$sysroot/lib/lean"
package="$lean_dir/.lake/build/lib/lean"
all_kinds=(olean olean.server olean.private ir ir.sig)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "machine: $(sysctl -n machdep.cpu.brand_string), $(sw_vers -productName) $(sw_vers -productVersion)"
echo "lean: $(cd "$lean_dir" && lean --version)"

# Sums the apparent sizes of the files listed on stdin, relative to `$1`.
sum_listed() {
  (cd "$1" && tr '\n' '\0' | xargs -0 stat -f %z 2>/dev/null) | awk '{ s += $1 } END { printf "%d", s }'
}

# Bytes as MB with one decimal.
mb() {
  awk -v b="$1" 'BEGIN { printf "%.1f", b / 1000000 }'
}

# Lists, relative to `$1`, the files of kind `$3` of the top-level module
# `$2`: its root file and everything under its directory.
list_root() {
  (
    cd "$1"
    if [ -e "$2.$3" ]; then echo "$2.$3"; fi
    if [ -d "$2" ]; then find "$2" -type f -name "*.$3"; fi
  )
}

# Lists, relative to `$1`, the files of kind `$3` of the modules named in
# the file `$2` that `$1` holds.
list_closure() {
  while IFS= read -r module; do
    path=$(printf '%s' "$module" | tr . /)
    if [ -e "$1/$path.$3" ]; then echo "$path.$3"; fi
  done <"$2"
}

# The median of the numbers on stdin, one a line, of an odd count.
median() {
  sort -n | awk '{ v[NR] = $1 } END { print v[(NR + 1) / 2] }'
}

# The largest of the numbers on stdin.
largest() {
  sort -n | tail -n 1
}

# Runs `$@` under `/usr/bin/time -l` and prints its stdout, then a line
# `time <real seconds> <maximum resident set size in bytes>`; or, when it
# fails, its stderr on stderr, and returns its status.
timed() {
  local err=$work/time.err
  local out
  local status=0
  out=$(/usr/bin/time -l "$@" 2>"$err") || status=$?
  printf '%s\n' "$out"
  if [ "$status" -ne 0 ]; then
    cat "$err" >&2
    return "$status"
  fi
  awk '/ real / { real = $1 } /maximum resident set size/ { rss = $1 } END { print "time", real, rss }' "$err"
}

for set in "Editor" "Editor Lean"; do
  read -r -a modules <<<"$set"
  label="set $set"
  if [ "$set" = Editor ]; then roots=Init,Std; else roots=Init,Std,Lean; fi
  closure=$work/closure
  "$config_test" bench-modules "$sysroot" "$package" "${modules[@]}" >"$closure"
  counts=$(cut -d. -f1 "$closure" | sort | uniq -c | awk '{ printf "%s%s %s", sep, $2, $1; sep = ", " }')
  echo "$label: closure: $(wc -l <"$closure" | tr -d ' ') modules ($counts)"

  # 1. Bytes, by kind: whole directories and the closure.
  whole_line=""
  closure_line=""
  whole_total=0
  closure_total=0
  IFS=, read -r -a toolchain_roots <<<"$roots"
  for kind in "${all_kinds[@]}"; do
    whole=0
    for root in "${toolchain_roots[@]}"; do
      whole=$((whole + $(list_root "$toolchain_lib" "$root" "$kind" | sum_listed "$toolchain_lib")))
    done
    whole=$((whole + $(list_root "$package" Editor "$kind" | sum_listed "$package")))
    closed=$(($(list_closure "$toolchain_lib" "$closure" "$kind" | sum_listed "$toolchain_lib") + $(list_closure "$package" "$closure" "$kind" | sum_listed "$package")))
    whole_line="$whole_line $kind $(mb "$whole") MB;"
    closure_line="$closure_line $kind $(mb "$closed") MB;"
    eval "whole_$(printf '%s' "$kind" | tr . _)=$whole"
    eval "closed_$(printf '%s' "$kind" | tr . _)=$closed"
  done
  echo "$label: bytes, whole directories (${roots//,/ } Editor):$whole_line"
  echo "$label: bytes, closure:$closure_line"

  # 2. Which kinds the import reads, on whole directories staged.
  needed=""
  for kinds in "olean" "olean olean.server" "olean olean.server olean.private" "olean olean.server olean.private ir ir.sig"; do
    read -r -a kind_list <<<"$kinds"
    stage=$work/stage
    rm -rf "$stage"
    "$stage_bundle" --roots "$roots" "$stage/Leanmacs.app" "$editor" "$sysroot" "$package" "${kind_list[@]}"
    resources=$stage/Leanmacs.app/Contents/Resources/lean
    if out=$(env -u LEAN_STACK_SIZE_KB "$config_test" bench-start "$resources/toolchain" "$resources/editor" "${modules[@]}" 2>"$work/start.err"); then
      echo "$label: kinds $kinds, whole directories: imports and loads: $out"
      needed=$kinds
      rm -rf "$stage"
      break
    else
      echo "$label: kinds $kinds, whole directories: fails: $(head -n 1 "$work/start.err")"
    fi
    rm -rf "$stage"
  done
  if [ -z "$needed" ]; then
    echo "$label: no kind set imports"
    continue
  fi
  read -r -a kind_list <<<"$needed"
  whole_needed=0
  closed_needed=0
  for kind in "${kind_list[@]}"; do
    name=$(printf '%s' "$kind" | tr . _)
    whole_needed=$((whole_needed + $(eval "echo \$whole_$name")))
    closed_needed=$((closed_needed + $(eval "echo \$closed_$name")))
  done
  echo "$label: shipped with kinds $needed: whole directories $(mb "$whole_needed") MB, closure $(mb "$closed_needed") MB"

  # 3. Start-up and memory, on the closure staged with those kinds.
  stage=$work/stage
  rm -rf "$stage"
  "$stage_bundle" --closure "$closure" "$stage/Leanmacs.app" "$editor" "$sysroot" "$package" "${kind_list[@]}"
  resources=$stage/Leanmacs.app/Contents/Resources/lean
  : >"$work/real"
  : >"$work/rss"
  : >"$work/import"
  : >"$work/first"
  for _ in 1 2 3 4 5; do
    lines=$(timed env -u LEAN_STACK_SIZE_KB "$config_test" bench-start "$resources/toolchain" "$resources/editor" "${modules[@]}")
    printf '%s\n' "$lines" | sed -n 's/.*: import \([0-9.]*\) ms, first load \([0-9.]*\) ms/\1/p' >>"$work/import"
    printf '%s\n' "$lines" | sed -n 's/.*: import \([0-9.]*\) ms, first load \([0-9.]*\) ms/\2/p' >>"$work/first"
    printf '%s\n' "$lines" | awk '/^time / { print $2 }' >>"$work/real"
    printf '%s\n' "$lines" | awk '/^time / { print $3 }' >>"$work/rss"
  done
  rss=$(largest <"$work/rss")
  echo "$label: bench-start, closure, kinds $needed, 5 runs: median real $(median <"$work/real") s, import $(median <"$work/import") ms, first load $(median <"$work/first") ms; largest maximum resident set $(mb "$rss") MB"

  if [ "$set" = Editor ]; then
    # The bundle as shipped: the default set's editor elaborates config on
    # the set's base, so its bundle holds that base's closure, taken from
    # every directory the build recorded for the editor.
    record=$editor.oleans
    searched=$(paste -s -d : "$record")
    read -r -a base <<<"$(cd "$lean_dir" && lake -d ../packages query :editorBase | tr '\n' ' ')"
    base_closure=$work/base-closure
    "$config_test" bench-modules "$sysroot" "$searched" "${base[@]}" Std Lean >"$base_closure"
    counts=$(cut -d. -f1 "$base_closure" | sort | uniq -c | awk '{ printf "%s%s %s", sep, $2, $1; sep = ", " }')
    rm -rf "$stage"
    "$stage_bundle" --closure "$base_closure" "$stage/Leanmacs.app" "$editor" "$sysroot" "$searched" "${kind_list[@]}"
    staged_bytes=$(cd "$stage/Leanmacs.app/Contents/Resources/lean" && find . -type f | sum_listed .)
    echo "the default set's base with Std and Lean (${base[*]} Std Lean): closure: $(wc -l <"$base_closure" | tr -d ' ') modules ($counts); shipped with kinds $needed: $(mb "$staged_bytes") MB"
    mkdir -p "$work/elsewhere"
    # Two configs: one whose root imports `Editor` alone, and one whose root
    # imports `Lean`, on which the base grows.
    for fixture in bench/generate headless/bundle; do
      rm -rf "$work/config"
      cp -R "$lean_dir/../tests/$fixture/config" "$work/config"
      cp "$lean_dir/../tests/$fixture/script" "$work/script"
      : >"$work/real"
      : >"$work/rss"
      for _ in 1 2 3 4 5; do
        lines=$(cd "$work/elsewhere" && timed env -i "$stage/Leanmacs.app/Contents/MacOS/editor" headless "$work/config" "$work/script")
        printf '%s\n' "$lines" | awk '/^time / { print $2 }' >>"$work/real"
        printf '%s\n' "$lines" | awk '/^time / { print $3 }' >>"$work/rss"
      done
      rss=$(largest <"$work/rss")
      echo "the default set's bundle: its headless mode on tests/$fixture, closure, kinds $needed, env -i, 5 runs: median real $(median <"$work/real") s; largest maximum resident set $(mb "$rss") MB"
    done
  fi
  rm -rf "$stage"
done
