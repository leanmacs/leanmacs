#!/bin/sh
# The wait inventory, run by `mise run wait-inventory`: every wait with a
# bound left in the Lean and Rust tests and test support, and whether it
# says which kind of bound it is. A review aid, opt-in, and never part of
# `ci` or hk.pkl: AGENTS.md forbids a test that scans source text, and this
# is not one (docs/dev-practices/on-demand-checks.md, "The wait inventory").
#
#   sh tools/wait-inventory.sh [--list]
#
# A bound left in a test says which it is (AGENTS.md, "Deterministic
# concurrency in tests"), in a comment on its line or among the three lines
# above it, or at the head of the doc of the constant or function it names:
#
#   hang guard: <the event the wait ends on>; ...
#   hang guard, run out on purpose: <what is held for good>; ...
#   real time under test: <the timing that is the subject>.
#
# What it scans:
#
#   Lean  the four test roots and their trees, `lean/Editor/Test/`, the
#         contract checks `lean/Editor/**/*Contract.lean`, the packages'
#         and fixture packages' `*Test` trees, and the headless driver's
#         own waits (`lean/Editor/Headless.lean`, `Window/Real.lean`,
#         `Job/Pool.lean`)
#   Rust  `tests/`, `examples/` and `benches/` of every crate and fixture
#         crate; the published test support (`contract`, `fake`,
#         `scripted`, `tests.rs`, `tests/`, `*_tests.rs`, the launcher's
#         probe); and each other `src` file from its first `#[cfg(test)]`
#
# Comments and string literals are dropped before matching, so prose and
# messages never match. A site is a line whose code holds a wait:
#
#   Lean  `IO.sleep`, `eventually`, `within`, `monoMsNow`, or a name that
#         holds `patience`/`Patience` or ends in `Guard`
#   Rust  a `sleep(`/`sleep_ms(` call, `recv_timeout`, `wait_timeout*`,
#         `park_timeout`, `yield_now`, `is_finished()`, `try_wait()`,
#         `Instant::now() +`, `.elapsed()`
#
# It prints `explained: N (hang guard A, run out on purpose B, real time
# under test C)` and `unexplained: M` with each unexplained `file:line`, and
# exits 1 when M > 0. `--list` prints every site with its kind as well.
# A name is matched by its last dotted segment, so a marked `patience` in
# one namespace explains a `patience` in another: the tool points a reviewer
# at sites, it does not prove them.
set -eu
export LC_ALL=C

list=false
[ "${1:-}" = --list ] && list=true

root=$(git rev-parse --show-toplevel)
cd "$root"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Each scanned file, as `<language> <first line> <path>`.
git ls-files '*.lean' |
  grep -E '^(lean/(ModelTest|FfiTest|ConfigTest|ContractTest)(/|\.lean$)|lean/Editor/Test/|lean/Editor/.*Contract\.lean$|packages/[^/]+/[A-Za-z]+Test(/|\.lean$)|docs/packages/[^/]+/[A-Za-z]+Test(/|\.lean$)|tests/.*/[A-Za-z]+Test(/|\.lean$)|lean/Editor/Headless\.lean$|lean/Editor/Window/Real\.lean$|lean/Editor/Job/Pool\.lean$)' |
  sed 's/^/lean 1 /' > "$work/files"

git ls-files 'crates/*/tests/**.rs' 'crates/*/examples/**.rs' 'crates/*/benches/*.rs' 'tests/packages/*/rust/tests/**.rs' |
  sed 's/^/rust 1 /' >> "$work/files"
for f in $(git ls-files 'crates/*/src/**.rs' 'tests/packages/*/rust/src/**.rs'); do
  case "$f" in
    */contract.rs | */contract/* | */fake.rs | */fake/* | */scripted.rs | */tests.rs | */tests/* | *_tests.rs | */bin/launch-probe.rs)
      echo "rust 1 $f" ;;
    *)
      from=$(grep -nE '^[[:space:]]*#\[cfg\((test|any\(test)' "$f" | head -1 | cut -d: -f1)
      if [ -n "$from" ]; then echo "rust $from $f"; fi ;;
  esac
done >> "$work/files"

# Strips one file's comments and string literals, keeping its line numbers,
# and writes `<path>\t<line>\t<code>\t<marker>\t<doc marker>` for each line:
# <marker> is the kind of marker in the line's comments (0 none, 1 hang
# guard, 2 run out on purpose, 3 real time under test), <doc marker> the
# kind a doc comment starts with when the line starts one.
strip='
function kind(text) {
  if (index(text, "hang guard, run out on purpose:")) return 2
  if (index(text, "hang guard:")) return 1
  if (index(text, "real time under test:")) return 3
  return 0
}
function startkind(text) {
  sub(/^[ \t*!]*/, "", text)
  if (substr(text, 1, 31) == "hang guard, run out on purpose:") return 2
  if (substr(text, 1, 11) == "hang guard:") return 1
  if (substr(text, 1, 21) == "real time under test:") return 3
  return 0
}
FNR == 1 { depth = 0; instr = 0; raw = 0; prevdoc = 0; docnext = 0 }
{
  line = $0; code = ""; comment = ""; doc = 0; n = length(line); i = 1
  if (docnext) { doc = startkind(line); docnext = 0 }
  isdoc = lang == "rust" && depth == 0 && !instr && line ~ /^[ \t]*\/\/\/([^\/]|$)/
  if (isdoc && !prevdoc) { t = line; sub(/^[ \t]*\/\/\//, "", t); doc = startkind(t) }
  prevdoc = isdoc
  while (i <= n) {
    c = substr(line, i, 1); c2 = substr(line, i, 2)
    if (depth > 0) {
      if (lang == "lean" && c2 == "/-") { depth++; i += 2; continue }
      if (lang == "lean" && c2 == "-/") { depth--; i += 2; continue }
      if (lang == "rust" && c2 == "/*") { depth++; i += 2; continue }
      if (lang == "rust" && c2 == "*/") { depth--; i += 2; continue }
      comment = comment c; i++; continue
    }
    if (instr) {
      if (raw > 0) {
        endq = "\"" sprintf("%*s", raw - 1, ""); gsub(/ /, "#", endq)
        if (substr(line, i, raw) == endq) { instr = 0; raw = 0; i += length(endq); code = code "\"\""; continue }
        i++; continue
      }
      if (c == "\\") { i += 2; continue }
      if (c == "\"") { instr = 0; code = code "\"\""; i++; continue }
      i++; continue
    }
    if (lang == "lean" && c2 == "--") { comment = comment substr(line, i + 2); break }
    if (lang == "rust" && c2 == "//") { comment = comment substr(line, i + 2); break }
    if (lang == "lean" && c2 == "/-") {
      if (substr(line, i, 3) == "/--") {
        rest = substr(line, i + 3); doc = startkind(rest)
        if (rest ~ /^[ \t]*$/) docnext = 1
      }
      depth = 1; i += 2; continue
    }
    if (lang == "rust" && c2 == "/*") { depth = 1; i += 2; continue }
    if (lang == "rust" && match(substr(line, i), /^br?#*"|^r#*"/) && (i == 1 || substr(line, i - 1, 1) !~ /[A-Za-z0-9_]/)) {
      lit = substr(line, i, RLENGTH); hashes = gsub(/#/, "#", lit)
      raw = hashes + 1; instr = 1; i += RLENGTH; continue
    }
    if (c == "\"") { instr = 1; i++; continue }
    if (c == "'\''" && (i == 1 || substr(line, i - 1, 1) !~ /[A-Za-z0-9_]/)) {
      if (substr(line, i + 2, 1) == "'\''") { code = code "'\'''\''"; i += 3; continue }
      if (substr(line, i + 1, 1) == "\\" && match(substr(line, i + 2), /^[^'\'']*'\''/)) { code = code "'\'''\''"; i += 2 + RLENGTH; continue }
    }
    code = code c; i++
  }
  gsub(/\t/, " ", code); gsub(/\t/, " ", comment)
  print FILENAME "\t" FNR "\t" code "\t" kind(comment) "\t" doc
}'

while read -r lang from path; do
  awk -v lang="$lang" "$strip" "$path" |
    awk -F '\t' -v lang="$lang" -v from="$from" 'BEGIN { OFS = "\t" } { print lang, from, $0 }'
done < "$work/files" > "$work/lines"

# The names whose doc starts with a marker: `<kind>\t<last segment>`.
awk -F '\t' '
  $3 != prevfile { pending = 0; prevfile = $3 }
  {
    code = $5
    if ($7 > 0) { pending = $7; next }
    if (pending == 0) next
    if (code ~ /^[ \t]*$/ || code ~ /^[ \t]*(@\[|#\[)/) next
    name = ""
    if ($1 == "lean" && match(code, /(def|abbrev|theorem|opaque|instance)[ \t]+[^ \t:(]+/)) {
      name = substr(code, RSTART, RLENGTH); sub(/^[a-z]+[ \t]+/, "", name)
    } else if ($1 == "lean" && match(code, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*:/)) {
      name = substr(code, RSTART, RLENGTH); gsub(/[ \t:]/, "", name)
    } else if ($1 == "rust" && match(code, /(const|static|fn)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
      name = substr(code, RSTART, RLENGTH); sub(/^[a-z]+[ \t]+/, "", name)
    }
    if (name != "") { n = split(name, seg, "."); print pending "\t" seg[n] }
    if ($1 == "lean" || code !~ /^[ \t]*\/\/\//) pending = 0
  }' "$work/lines" | sort -u > "$work/marked"

# The sites, each with the kind that explains it (0 for none).
awk -F '\t' -v list="$list" '
  FILENAME == ARGV[1] { marked[$2] = $1; next }
  $3 != prevfile { prevfile = $3; m1 = m2 = m3 = 0 }
  {
    lang = $1; from = $2 + 0; line = $4 + 0; code = $5; here = $6 + 0
    site = 0
    if (line >= from) {
      if (lang == "lean") {
        t = code; gsub(/[^A-Za-z0-9_.'\''!?]+/, " ", t); nt = split(t, tok, " ")
        for (k = 1; k <= nt; k++) {
          ns = split(tok[k], seg, "."); last = seg[ns]
          if (tok[k] == "IO.sleep" || last == "eventually" || last == "within" || last == "monoMsNow" || last ~ /[Pp]atience/ || last ~ /Guard$/) site = 1
        }
      } else {
        if (code ~ /(^|[^A-Za-z0-9_])sleep(_ms)?\(/ && code !~ /fn[ \t]+sleep/) site = 1
        if (code ~ /recv_timeout|wait_timeout|park_timeout|yield_now|is_finished\(\)|try_wait\(\)|Instant::now\(\)[ \t]*\+|\.elapsed\(\)/) site = 1
      }
    }
    if (site) {
      why = here
      if (!why) why = m1; if (!why) why = m2; if (!why) why = m3
      if (!why) {
        t = code; gsub(/[^A-Za-z0-9_.]+/, " ", t); nt = split(t, tok, " ")
        for (k = 1; k <= nt && !why; k++) { ns = split(tok[k], seg, "."); if (seg[ns] in marked) why = marked[seg[ns]] }
      }
      count[why]++
      if (why == 0) bad[++nbad] = $3 ":" line
      if (list == "true") all[++nall] = why "\t" $3 ":" line
    }
    m3 = m2; m2 = m1; m1 = here
  }
  END {
    printf "explained: %d (hang guard %d, run out on purpose %d, real time under test %d)\n", count[1] + count[2] + count[3], count[1], count[2], count[3]
    printf "unexplained: %d\n", count[0]
    for (k = 1; k <= nbad; k++) print "  " bad[k]
    if (list == "true") { print "sites:"; for (k = 1; k <= nall; k++) print "  " all[k] }
    exit count[0] > 0
  }' "$work/marked" "$work/lines"
