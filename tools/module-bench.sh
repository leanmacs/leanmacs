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
#    a temporary directory with tools/stage-bundle.sh, with each kind set in
#    turn (`olean`; `olean olean.server`; `olean olean.server
#    olean.private`; and that with `ir ir.sig`), and runs
#    `config-test bench-start` on the staged directories. The smallest set
#    with which the base imports and its config loads is the set the import
#    needs; each failure's first line on stderr is printed;
# 3. with that kind set, the closure staged, five runs of `bench-start`
#    under `/usr/bin/time -l`: the median real time, import time and first
#    load, and the largest maximum resident set size; and, for `Editor`
#    alone, five runs of the staged bundle's headless mode on
#    `tests/headless/bundle`, as `bundle-test` runs it, with `env -i`: the
#    median real time and the largest maximum resident set size.
#
# Bytes are apparent sizes, summed from `stat -f %z`; MB are 10^6 bytes. It
# asserts nothing. Every temporary directory is removed by a trap. It is
# macOS only, as the app bundle is.
#
# `$1` is the Lean package's directory, where the built executables are.
set -euo pipefail

if [ "$(uname -s)" != Darwin ]; then
  echo "module-bench: macOS only" >&2
  exit 2
fi

lean_dir=$(cd "$1" && pwd)
tools=$(cd "$lean_dir/../tools" && pwd)
fixtures=$(cd "$lean_dir/../tests/headless/bundle" && pwd)
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
# `time <real seconds> <maximum resident set size in bytes>`.
timed() {
  local err=$work/time.err
  local out
  out=$(/usr/bin/time -l "$@" 2>"$err")
  printf '%s\n' "$out"
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
    "$tools/stage-bundle.sh" --roots "$roots" "$stage/Leanmacs.app" "$editor" "$sysroot" "$package" "${kind_list[@]}"
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
  "$tools/stage-bundle.sh" --closure "$closure" "$stage/Leanmacs.app" "$editor" "$sysroot" "$package" "${kind_list[@]}"
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
    cp -R "$fixtures/config" "$work/config"
    cp "$fixtures/script" "$work/script"
    mkdir -p "$work/elsewhere"
    : >"$work/real"
    : >"$work/rss"
    for _ in 1 2 3 4 5; do
      lines=$(cd "$work/elsewhere" && timed env -i "$stage/Leanmacs.app/Contents/MacOS/editor" headless "$work/config" "$work/script")
      printf '%s\n' "$lines" | awk '/^time / { print $2 }' >>"$work/real"
      printf '%s\n' "$lines" | awk '/^time / { print $3 }' >>"$work/rss"
    done
    rss=$(largest <"$work/rss")
    echo "$label: the bundle's headless mode on tests/headless/bundle, closure, kinds $needed, env -i, 5 runs: median real $(median <"$work/real") s; largest maximum resident set $(mb "$rss") MB"
  fi
  rm -rf "$stage"
done
