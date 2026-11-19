#!/usr/bin/env bash
# The user-side link, checked: `mise run user-link-check`
# (docs/design/lean-runtime.md, "A link on the user's machine, measured";
# docs/dev-practices/on-demand-checks.md, "The user-side link, on demand").
#
#   tools/user-link-check.sh <lean package dir> [--linker bundled|system] [--keep]
#
# Can an `editor` be linked on a user's Mac from pieces the app ships, with
# the `clang` and `ld64.lld` the Lean toolchain bundles and no Xcode command
# line tools? This links one, from the trivial package `tests/user-link/package`
# (one module, one command) and the editor's pieces as `mise run lean` built
# them, with the tools made unreachable, and runs it. Its steps, in order;
# it exits non-zero at the first that fails, naming it:
#
# 1. Stage, by copy and never by link, into `<tmp>/stage`:
#    - `toolchain/`: the whole Lean toolchain (`lean --print-prefix`);
#    - `core/lib/`: the `.olean` file of each of the editor's modules the
#      link of the built `editor` names (`lean/.lake/build/bin/editor.rsp`),
#      less its root `Main`;
#    - `core/obj/`: the object of each of those modules (`.c.o.export`).
#      `Main`'s is left out because the package brings the root, and two
#      `main` symbols cannot link;
#    - `core/glue.o` and `core/libeditor_ffi.a`: the glue object and the
#      Rust archive, prebuilt;
#    - `core/lakefile.toml` and `core/lake-manifest.json`
#      (`tools/user-link/core`): they make `core/` a Lake package with no
#      target, which the fixture requires by path, so its modules can
#      import the editor's. Lake hands `lean` the library directories of
#      the workspace's packages and no inherited `LEAN_PATH`;
#    - `stubs/`: link stubs for the system's frameworks and libraries, made
#      from the built `editor`'s import table, and the minimum macOS and
#      SDK version it records (`tools/link-stubs.sh`);
#    - `package/`: a copy of `tests/user-link/package`, so its `.lake/` is
#      made in the copy;
#    - `decoys/`: programs named `xcrun`, `xcodebuild`, `xcode-select`,
#      `cc`, `gcc`, `clang++`, `ld`, `ar` and `git`, first on the `PATH`,
#      each of which appends its name and arguments to `<tmp>/decoy.log`
#      and exits 1 (`tools/user-link/decoy.c`);
#    - `probe/probe`: a program that reads a file or lists a directory and
#      says why it could not (`tools/user-link/probe.c`), for step 2.
#    The decoys and the probe are the check's own, not pieces a relink
#    uses. The sandbox runs no program outside the stage, so they are
#    compiled into it, with the staged clang and no SDK.
# 2. Probe the sandbox (`tools/user-link/sandbox.sb`), under the profile and
#    the environment of steps 3 and 4. Each of these must be refused with
#    `Operation not permitted`: running `/usr/bin/xcrun --show-sdk-path`,
#    `/usr/bin/clang --version`, `/usr/bin/ld -v`, `/usr/bin/cc --version`
#    and `/usr/bin/git --version`; reading the SDK's `usr/lib/libSystem.tbd`
#    (its path found outside the sandbox); and listing the real toolchain's
#    directory and the repository's. The staged `clang --version` must run,
#    the probe must read a staged file and list a staged directory, and a
#    decoy run by its name must be recorded in the decoy log. A profile
#    that denied nothing, or everything, fails here.
# 3. Build the package inside the sandbox, with the staged `lake`:
#    `lake build UserLinkFixture -K stage=<stage>`, with an empty
#    environment but `PATH` (the decoys, the staged toolchain's `bin`,
#    `/usr/bin`, `/bin`), `HOME` and `TMPDIR` inside `<tmp>`, and
#    `MACOSX_DEPLOYMENT_TARGET` (the built editor's `minos`); no `LEAN_CC`,
#    `LEAN_PATH`, `SDKROOT` or `DEVELOPER_DIR`.
# 4. Link inside the sandbox: `lake build editor -K stage=<stage>`, the same
#    way, so Lake runs the bundled `clang`, which runs `ld64.lld`. The
#    linker writes every file it opened to a dependency report
#    (`-dependency_info`, set in the package's lakefile).
# 5. Sign ad hoc with `/usr/bin/codesign --force -s -`, and verify with
#    `codesign --verify --strict`. `codesign` must not be a shim of the
#    command line tools (it loads no `libxcselect`).
# 6. Run the relinked editor with an empty environment, from a working
#    directory outside the stage, on the staged toolchain and `.olean`
#    files:
#    - `editor headless … tests/headless/config tests/headless/script` must
#      print exactly `tests/headless/expected`, the standing fixture;
#    - `editor headless-with-package … tests/user-link/config
#      tests/user-link/script` must print exactly `tests/user-link/expected`,
#      once its `scene` lines are cut down to the echo area's text (`echo
#      "<text>"`; `echo_only` below): the package's command ran and its
#      message is in the echo area.
# 7. Show nothing outside the stage was used: the decoy log is empty; every
#    file in the linker's dependency report is under `<stage>`; the staged
#    pieces are as they were staged, so the build wrote into the package's
#    copy alone; and the relinked editor's minimum macOS and SDK version
#    (`vtool -show-build`, `minos` and `sdk`) are the built editor's. It
#    prints the `libSystem` and `libc++` files the link read, both editors'
#    build versions, and how their libraries (`otool -L`) differ.
# 8. Report: the machine, `lean --version`, the staged pieces with their
#    files and bytes (apparent size; MB are 10^6 bytes), what of the
#    toolchain the link opened, the link line, the relinked editor's size,
#    and the medians of five runs each of the package build from a clean
#    package build directory, the whole `lake build editor` from a clean
#    one, the link alone (the command Lake ran, run again), and the
#    signing.
#
# `--linker system` is the baseline, and the route that requires the
# command line tools: the same steps outside the sandbox with
# `LEAN_CC=/usr/bin/cc` and the SDK's frameworks in place of the stubs. It
# stages no stubs and no decoys, skips step 2, and in step 7 lists where the
# linker's files came from instead of requiring them under the stage.
#
# Everything it writes is under one temporary directory, removed by a trap;
# `--keep` leaves it and prints its path. The repository, `$HOME` and the
# toolchain are not written to. If `sandbox-exec` cannot apply the profile
# (a shell that is itself sandboxed), the check fails at step 2; it never
# goes on unsandboxed. It is macOS on arm64 only, as the app bundle is.
#
# `$1` is the Lean package's directory, where `mise run lean` built.
set -euo pipefail
set -E

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo "user-link-check: the user-side link is checked on macOS on arm64 only (this is $(uname -s) $(uname -m))" >&2
  exit 2
fi

usage() {
  echo "usage: tools/user-link-check.sh <lean package dir> [--linker bundled|system] [--keep]" >&2
  exit 2
}

linker=bundled
keep=no
lean_arg=
while [ $# -gt 0 ]; do
  case "$1" in
    --linker)
      [ $# -ge 2 ] || usage
      linker=$2
      shift 2
      ;;
    --keep)
      keep=yes
      shift
      ;;
    -*) usage ;;
    *)
      [ -z "$lean_arg" ] || usage
      lean_arg=$1
      shift
      ;;
  esac
done
[ -n "$lean_arg" ] || usage
case "$linker" in
  bundled | system) ;;
  *) usage ;;
esac

step="0 (find the built editor)"
fail() {
  echo "user-link-check: step $step: $*" >&2
  exit 1
}
trap 'echo "user-link-check: failed at step $step" >&2' ERR

lean_dir=$(cd "$lean_arg" && pwd)
repo=$(cd "$lean_dir/.." && pwd)
tools=$repo/tools
fixture=$repo/tests/user-link
headless=$repo/tests/headless
profile=$tools/user-link/sandbox.sb
built=$lean_dir/.lake/build
dev_editor=$built/bin/editor
dev_link=$built/bin/editor.rsp
sysroot=$(cd "$lean_dir" && lean --print-prefix)

[ -x "$dev_editor" ] || fail "no built editor at $dev_editor; run \`mise run lean\` first"
[ -f "$dev_link" ] || fail "no link line at $dev_link; run \`mise run lean\` first"

# The built editor's minimum macOS and SDK (its LC_BUILD_VERSION).
build_version() {
  vtool -show-build "$1" | awk -v key="$2" '$1 == key { print $2; exit }'
}
minos=$(build_version "$dev_editor" minos)
[ -n "$minos" ] || fail "the built editor records no minimum macOS"

work=$(cd "$(mktemp -d)" && pwd -P)
cleanup() {
  if [ "$keep" = yes ]; then
    echo "user-link-check: kept $work"
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT
stage=$work/stage
package=$stage/package
lake=$stage/toolchain/bin/lake
relinked=$package/.lake/build/bin/editor
report=$package/.lake/build/link.dependency-info
mkdir -p "$work/home" "$work/tmp" "$work/elsewhere" "$work/log" "$work/times"

# The environment the package is built and linked in, as a command prefix:
# empty but for these, and, with the bundled linker, inside the sandbox.
# `env -i` is outside `sandbox-exec`, which then runs the staged program
# directly: the profile lets `/usr/bin/env` run no more than anything else
# outside the stage.
if [ "$linker" = bundled ]; then
  build_env=(/usr/bin/env -i "PATH=$stage/decoys:$stage/toolchain/bin:/usr/bin:/bin" "HOME=$work/home"
    "TMPDIR=$work/tmp" "MACOSX_DEPLOYMENT_TARGET=$minos"
    /usr/bin/sandbox-exec -f "$profile" -D "STAGE=$stage" -D "WORK=$work")
else
  build_env=(/usr/bin/env -i "PATH=$stage/toolchain/bin:/usr/bin:/bin" "HOME=$work/home"
    "TMPDIR=$work/tmp" "MACOSX_DEPLOYMENT_TARGET=$minos"
    LEAN_CC=/usr/bin/cc)
fi

# Sums the apparent sizes of the files under `$@`.
bytes() {
  find "$@" -type f -print0 | xargs -0 stat -f %z | awk '{ s += $1 } END { printf "%d", s }'
}

# Counts the files under `$@`.
files() {
  find "$@" -type f | wc -l | tr -d ' '
}

# Bytes as MB with one decimal.
mb() {
  awk -v b="$1" 'BEGIN { printf "%.1f", b / 1000000 }'
}

# The median of the numbers on stdin, one a line, of an odd count.
median() {
  sort -n | awk '{ v[NR] = $1 } END { print v[(NR + 1) / 2] }'
}

# Runs `$3…` in the directory `$2`, keeping what it prints in the log `$1`;
# when it fails, prints the log.
logged() {
  local log=$work/log/$1
  local dir=$2
  shift 2
  if ! (cd "$dir" && "$@") >"$log" 2>&1; then
    cat "$log" >&2
    return 1
  fi
}

# Runs `$2…` and appends its wall-clock time in seconds to the file `$1`.
timed() {
  local into=$1
  shift
  /usr/bin/time -p -o "$work/time.out" "$@" || return
  awk '$1 == "real" { print $2 }' "$work/time.out" >>"$into"
}

# What the linker opened, from its dependency report `$1`: records of one
# byte and a name, each ended by a zero byte; the byte 0x10 marks an input.
# An input is a file, by its absolute path, or, from `ld64.lld`, a member
# of an archive, by its bare name.
link_inputs() {
  LC_ALL=C tr '\000' '\n' <"$1" | LC_ALL=C sed -n $'s/^\x10//p' | sort -u
}

# The files the linker looked for and did not find (the byte 0x11).
link_missing() {
  LC_ALL=C tr '\000' '\n' <"$1" | LC_ALL=C sed -n $'s/^\x11//p' | sort -u
}

# What the headless mode printed, with each `scene` line cut down to the
# echo area's text and the lines of its views and their status lines
# dropped: those say the frame's size, the theme and the mode line, which
# are the editor's to pin, in its own fixtures.
echo_only() {
  sed -e 's/^scene .*, \(echo "[^"]*"\), echo padding .*$/\1/' -e '/^view /d' -e '/^status /d'
}

# 1. Stage.
step="1 (stage)"
echo "1. stage, in $work"
mkdir -p "$stage/core/obj" "$stage/core/lib" "$stage/toolchain"
# The whole toolchain but `exposed`, which is not Lean's: mise adds it to an
# install, a directory of links to the toolchain's own programs by their
# absolute paths.
for entry in "$sysroot"/*; do
  [ "$(basename "$entry")" != exposed ] || continue
  cp -cR "$entry" "$stage/toolchain/"
done

# The arguments of the built editor's link whose paths end as the pattern
# `$1` says, one a line, unquoted. That none does is no failure here, so
# each caller can say what the link line lacks; `grep` failing for any other
# reason still is.
dev_link_names() {
  { grep -o "\"[^\"]*$1\"" "$dev_link" || [ $? -eq 1 ]; } | tr -d '"'
}

# The objects the built editor's link names, less its root's, each with its
# module's `.olean`.
ir=$built/ir
dev_link_names '\.c\.o\.export' >"$work/dev-objects"
while IFS= read -r object; do
  case "$object" in
    "$ir/"*) relative=${object#"$ir/"} ;;
    *) fail "the built editor's link names an object outside $ir: $object" ;;
  esac
  module=${relative%.c.o.export}
  [ "$module" != Main ] || continue
  mkdir -p "$stage/core/obj/$(dirname "$relative")" "$stage/core/lib/$(dirname "$relative")"
  cp -c "$object" "$stage/core/obj/$relative"
  cp -c "$built/lib/lean/$module.olean" "$stage/core/lib/$module.olean"
done <"$work/dev-objects"
[ "$(files "$stage/core/obj")" -gt 0 ] || fail "the built editor's link names no object under $ir"

# The glue object and the Rust archive, as that link names them.
dev_glue=$(dev_link_names '/glue\.o')
dev_archive=$(dev_link_names '/libeditor_ffi\.a')
[ -f "$dev_glue" ] || fail "the built editor's link names no glue object"
[ -f "$dev_archive" ] || fail "the built editor's link names no Rust archive"
cp -c "$dev_glue" "$stage/core/glue.o"
cp -c "$dev_archive" "$stage/core/libeditor_ffi.a"

# What makes `core/` a package the fixture can require: its config, which
# names no target, and an empty manifest.
cp "$tools/user-link/core/lakefile.toml" "$tools/user-link/core/lake-manifest.json" "$stage/core/"

cp -R "$fixture/package" "$package"
rm -rf "$package/.lake" "$package/lake-manifest.json"

if [ "$linker" = bundled ]; then
  "$tools/link-stubs.sh" "$dev_editor" "$stage/stubs"

  # The check's own two programs, compiled into the stage with the staged
  # clang and its linker, against the toolchain's own `libSystem` stub and
  # no SDK: the sandbox runs no program outside the stage, a shell script
  # needs `/bin/sh`, and a copy of a system program is killed when it starts.
  stage_cc() {
    local source=$1
    local program=$2
    shift 2
    /usr/bin/env -i "MACOSX_DEPLOYMENT_TARGET=$minos" "$stage/toolchain/bin/clang" \
      --sysroot "$stage/toolchain" -L "$stage/toolchain/lib/libc" -fuse-ld=lld \
      -Wall -Wextra -Werror "$@" -o "$program" "$source"
  }
  mkdir "$stage/probe" "$stage/decoys"
  stage_cc "$tools/user-link/probe.c" "$stage/probe/probe"
  : >"$work/decoy.log"
  stage_cc "$tools/user-link/decoy.c" "$work/decoy" "-DDECOY_LOG=\"$work/decoy.log\""
  for name in xcrun xcodebuild xcode-select cc gcc clang++ ld ar git; do
    cp "$work/decoy" "$stage/decoys/$name"
  done
fi

# By copy, never by link: a link in the stage that led outside it would let
# the build read what the stage does not hold.
find "$stage" -type l -print | while IFS= read -r link; do
  resolved=$(realpath "$link") || fail "the staged link $link leads nowhere"
  case "$resolved" in
    "$stage"/*) ;;
    *) fail "the staged link $link leads outside the stage, to $resolved" ;;
  esac
done

# What is staged is listed now, before anything is built, and step 7 lists
# it again: the build writes into the package's copy alone.
staged_listing() {
  (cd "$stage" && find . -path ./package -prune -o -type f -exec stat -f '%N %z %m' {} + | sort)
}
staged_listing >"$work/staged-before"

# 2. Probe the sandbox.
if [ "$linker" = bundled ]; then
  step="2 (probe the sandbox)"
  echo "2. probe the sandbox"
  sdk=$(xcrun --show-sdk-path)
  [ -r "$sdk/usr/lib/libSystem.tbd" ] || fail "no SDK stub to probe with at $sdk/usr/lib/libSystem.tbd"

  # The staged compiler runs. This is first: when the profile cannot be
  # applied at all, everything below would be refused for that reason.
  status=0
  out=$(cd "$package" && "${build_env[@]}" "$stage/toolchain/bin/clang" --version 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then
    case "$out" in
      *sandbox_apply*)
        fail "sandbox-exec cannot apply the profile ($out); run the check from a shell that is not itself sandboxed" ;;
      *) fail "the staged clang does not run in the sandbox: $out" ;;
    esac
  fi
  echo "   runs: <stage>/toolchain/bin/clang --version: $(printf '%s\n' "$out" | head -n 1)"

  # `$@` must be refused by the sandbox.
  refused() {
    local out
    local status=0
    out=$(cd "$package" && "${build_env[@]}" "$@" 2>&1) || status=$?
    [ "$status" -ne 0 ] || fail "the sandbox let \`$*\` through: $out"
    case "$out" in
      *"Operation not permitted"*) ;;
      *) fail "\`$*\` failed in the sandbox, but not as refused: $out" ;;
    esac
    echo "   refused: $(printf '%s' "$*" | sed "s|$stage/|<stage>/|g")"
  }
  refused /usr/bin/xcrun --show-sdk-path
  refused /usr/bin/clang --version
  refused /usr/bin/ld -v
  refused /usr/bin/cc --version
  refused /usr/bin/git --version
  refused "$stage/probe/probe" read "$sdk/usr/lib/libSystem.tbd"
  refused "$stage/probe/probe" list "$sysroot"
  refused "$stage/probe/probe" list "$repo"

  # The probe's program does read and list what the sandbox leaves it.
  (cd "$package" && "${build_env[@]}" "$stage/probe/probe" read "$stage/toolchain/lib/libc/libSystem.tbd") ||
    fail "the probe cannot read a staged file in the sandbox"
  (cd "$package" && "${build_env[@]}" "$stage/probe/probe" list "$stage/toolchain") ||
    fail "the probe cannot list a staged directory in the sandbox"
  echo "   reads: <stage>/toolchain/lib/libc/libSystem.tbd; lists: <stage>/toolchain"

  # A decoy run by its name is recorded, and fails.
  status=0
  (cd "$package" && "${build_env[@]}" xcrun --show-sdk-path) >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "the decoy xcrun did not fail"
  [ "$(cat "$work/decoy.log")" = "xcrun --show-sdk-path" ] ||
    fail "the decoy xcrun was not recorded; the decoy log holds: $(cat "$work/decoy.log")"
  echo "   recorded: xcrun, run by its name"
  : >"$work/decoy.log"
fi

# The link command Lake ran, from the log `$1` of a verbose build: the line
# Lake traces for the executable, less the variables Lake set for it
# (`MACOSX_DEPLOYMENT_TARGET`, which the build environment sets too).
link_command() {
  sed -n 's/^trace: \.> //p' "$1" | grep -- "-o $relinked @$relinked.rsp\$" | tail -n 1 |
    sed -E 's/^([A-Z_]+=[^ ]* )*//'
}

# 3. Build the package.
step="3 (build the package)"
echo "3. build the package: lake build UserLinkFixture"
logged build-package.log "$package" "${build_env[@]}" "$lake" build UserLinkFixture -K "stage=$stage"

# 4. Link.
step="4 (link)"
echo "4. link: lake build editor"
logged link.log "$package" "${build_env[@]}" "$lake" build editor -v -K "stage=$stage"
[ -x "$relinked" ] || fail "Lake built no editor at $relinked"
[ -s "$report" ] || fail "the linker wrote no dependency report at $report"
read -r -a link_words <<<"$(link_command "$work/log/link.log")"
[ "${#link_words[@]}" -gt 0 ] || fail "Lake's log names no link command for $relinked"
if [ "$linker" = bundled ]; then
  [ "${link_words[0]}" = "$stage/toolchain/bin/clang" ] ||
    fail "Lake linked with ${link_words[0]}, not the staged clang"
else
  [ "${link_words[0]}" = /usr/bin/cc ] || fail "Lake linked with ${link_words[0]}, not /usr/bin/cc"
fi

# 5. Sign.
step="5 (sign)"
echo "5. sign: codesign --force -s -"
# `/usr/bin/codesign` is the system's own program, on a Mac without the
# command line tools too: it does not load `libxcselect`, which the shims
# that stand in for the tools' programs (`/usr/bin/clang`) do.
if otool -L /usr/bin/codesign | grep -q libxcselect; then
  fail "/usr/bin/codesign loads libxcselect: it is a shim of the command line tools"
fi
echo "   /usr/bin/codesign loads no libxcselect: not a shim of the command line tools"
/usr/bin/codesign --force -s - "$relinked" 2>"$work/log/sign.log" || fail "codesign refused: $(cat "$work/log/sign.log")"
/usr/bin/codesign --verify --strict "$relinked" || fail "the signature does not verify"

# 6. Run.
step="6 (run)"
echo "6. run the relinked editor"
# The relinked editor's mode `$1` on the config `$2` and the script `$3`,
# with an empty environment, from a working directory outside the stage.
run_editor() {
  (cd "$work/elsewhere" && /usr/bin/env -i "$relinked" "$1" "$stage/toolchain" "$stage/core/lib" "$2" "$3")
}
out=$(run_editor headless "$headless/config" "$headless/script") ||
  fail "the relinked editor's headless mode failed on tests/headless"
printf '%s\n' "$out" | diff "$headless/expected" - ||
  fail "the relinked editor does not print tests/headless/expected"
echo "   headless, tests/headless: prints expected"
out=$(run_editor headless-with-package "$fixture/config" "$fixture/script") ||
  fail "the relinked editor's headless-with-package mode failed on tests/user-link"
printf '%s\n' "$out" | echo_only | diff "$fixture/expected" - ||
  fail "the relinked editor does not print tests/user-link/expected"
echo "   headless-with-package, tests/user-link: prints expected; the package's command ran:"
printf '%s\n' "$out" | echo_only | sed 's/^/     /'

# 7. Nothing outside the stage was used.
step="7 (nothing outside the stage)"
echo "7. what the build and the link used"
link_inputs "$report" >"$work/link-records"
link_missing "$report" >"$work/link-missing"
grep '^/' "$work/link-records" >"$work/link-inputs" || true
[ -s "$work/link-inputs" ] || fail "the linker's dependency report names no input file"
# What is no absolute path is an archive member's bare name; a relative
# path would be a file this cannot place.
members=$(grep -c -v '^/' "$work/link-records" || true)
relative=$(grep -v '^/' "$work/link-records" | grep / || true)
[ -z "$relative" ] || fail "the linker's dependency report names files by relative paths: $relative"
if [ "$linker" = bundled ]; then
  [ ! -s "$work/decoy.log" ] ||
    fail "a developer tool was run by its name: $(cat "$work/decoy.log")"
  echo "   decoy log: empty"
  outside=$(grep -v "^$stage/" "$work/link-inputs" || true)
  [ -z "$outside" ] || fail "the linker opened files outside the stage: $outside"
  echo "   linker: opened $(wc -l <"$work/link-inputs" | tr -d ' ') files, all under <stage>, and $members members of the archives among them"
  sought=$(grep -c -v "^$stage/" "$work/link-missing" || true)
  echo "   linker: looked for and did not find $(wc -l <"$work/link-missing" | tr -d ' ') files, $sought of them outside <stage>"
  grep -v "^$stage/" "$work/link-missing" | sed 's/^/     not found: /' || true
else
  sdk=$(xcrun --show-sdk-path)
  sdk=$(cd "$sdk" && pwd -P)
  echo "   linker: opened $(wc -l <"$work/link-inputs" | tr -d ' ') files: $(grep -c "^$stage/" "$work/link-inputs" || true) under <stage>, $(grep -c "^$sdk/" "$work/link-inputs" || true) under the SDK ($sdk)"
  other=$(grep -v -e "^$stage/" -e "^$sdk/" "$work/link-inputs" || true)
  if [ -n "$other" ]; then
    printf '%s\n' "$other" | sed 's/^/     elsewhere: /'
  fi
fi
grep -e '/libSystem\.tbd$' -e '/libc++\.tbd$' -e '/libc++\.dylib$' "$work/link-inputs" |
  sed -e "s|^$stage/|<stage>/|" -e 's/^/   linker: read /'

# The build wrote into the package's copy and nowhere else in the stage.
staged_listing >"$work/staged-after"
diff "$work/staged-before" "$work/staged-after" >"$work/staged-diff" ||
  fail "the build changed the staged pieces: $(cat "$work/staged-diff")"
echo "   staged pieces: unchanged by the build, which wrote under <stage>/package alone"

relinked_minos=$(build_version "$relinked" minos)
[ "$relinked_minos" = "$minos" ] ||
  fail "the relinked editor's minimum macOS is $relinked_minos, the built editor's $minos"
# With no SDK the linker has no SDK version of its own to record, and the
# link passes on the built editor's (`<stage>/stubs/platform-version`).
if [ "$linker" = bundled ]; then
  [ "$(build_version "$relinked" sdk)" = "$(build_version "$dev_editor" sdk)" ] ||
    fail "the relinked editor's SDK version is $(build_version "$relinked" sdk), the built editor's $(build_version "$dev_editor" sdk)"
fi
# The linker an executable records (its LC_BUILD_VERSION's tool): `LD` is
# Apple's, and the tool number 4, which `vtool` has no name for, is LLD.
linked_by() {
  vtool -show-build "$1" |
    awk '$1 == "tool" { tool = ($2 == "4" ? "LLD" : $2) } $1 == "version" { print tool, $2; exit }'
}
echo "   built editor:    minos $minos, sdk $(build_version "$dev_editor" sdk), linked by $(linked_by "$dev_editor")"
echo "   relinked editor: minos $relinked_minos, sdk $(build_version "$relinked" sdk), linked by $(linked_by "$relinked")"
otool -L "$dev_editor" | tail -n +2 | sed 's/^[[:space:]]*//' | sort >"$work/dev-libraries"
otool -L "$relinked" | tail -n +2 | sed 's/^[[:space:]]*//' | sort >"$work/relinked-libraries"
if diff "$work/dev-libraries" "$work/relinked-libraries" >"$work/libraries-diff"; then
  echo "   libraries (otool -L): the relinked editor loads the built editor's $(wc -l <"$work/dev-libraries" | tr -d ' '), at the same versions"
else
  echo "   libraries (otool -L): the relinked editor's differ from the built editor's (< built, > relinked):"
  sed 's/^/     /' "$work/libraries-diff"
fi

# 8. Report.
step="8 (report)"
echo "8. report"
echo "   machine: $(sysctl -n machdep.cpu.brand_string), $(sw_vers -productName) $(sw_vers -productVersion)"
echo "   lean: $("$stage/toolchain/bin/lean" --version)"
echo "   linker: $linker"

# One line for a staged piece: its files and its size, in MB, or in bytes
# when it is under a twentieth of one.
piece() {
  local label=$1
  shift
  local size
  size=$(bytes "$@")
  if [ "$size" -lt 50000 ]; then
    echo "   piece $label: $(files "$@") files, $size bytes"
  else
    echo "   piece $label: $(files "$@") files, $(mb "$size") MB"
  fi
}
piece "toolchain (the Lean toolchain, whole)" "$stage/toolchain"
opened=$(grep "^$stage/toolchain/" "$work/link-inputs" || true)
if [ -n "$opened" ]; then
  echo "     of it, opened by the linker: $(printf '%s\n' "$opened" | wc -l | tr -d ' ') files, $(mb "$(printf '%s\n' "$opened" | tr '\n' '\0' | xargs -0 stat -f %z | awk '{ s += $1 } END { printf "%d", s }')") MB"
fi
piece "core/lib (the editor's modules, .olean)" "$stage/core/lib"
piece "core/obj (the editor's modules, .c.o.export)" "$stage/core/obj"
piece "core/glue.o (the glue object)" "$stage/core/glue.o"
piece "core/libeditor_ffi.a (the Rust archive)" "$stage/core/libeditor_ffi.a"
piece "core/lakefile.toml, core/lake-manifest.json (the package config)" "$stage/core/lakefile.toml" "$stage/core/lake-manifest.json"
if [ "$linker" = bundled ]; then
  piece "stubs (link stubs, .tbd, and platform-version)" "$stage/stubs"
fi
piece "package (the fixture's sources)" "$package/lakefile.lean" "$package/Main.lean" "$package/UserLinkFixture.lean"

# The link line: the command, then its response file with the stage's path
# cut and the editor's objects counted.
echo "   link line: $(printf '%s\n' "${link_words[*]}" | sed "s|$stage/|<stage>/|g")"
echo "   $(basename "$relinked.rsp"): $(tr -d '"' <"$relinked.rsp" | tr ' ' '\n' | sed "s|$stage/|<stage>/|g" |
  awk '/^<stage>\/core\/obj\// { objects += 1; if (objects == 1) printf "%s", "<the objects under <stage>/core/obj> "; next } { printf "%s ", $0 } END { printf "(%d objects under <stage>/core/obj)", objects }')"

# Five runs of each. A run builds the package's library from a clean build
# directory, then the whole editor from a clean one, then links again with
# the command Lake ran, then signs what that linked.
for _ in 1 2 3 4 5; do
  rm -rf "$package/.lake"
  logged time-package.log "$package" timed "$work/times/package" "${build_env[@]}" "$lake" build UserLinkFixture -K "stage=$stage"
  rm -rf "$package/.lake"
  logged time-whole.log "$package" timed "$work/times/whole" "${build_env[@]}" "$lake" build editor -K "stage=$stage"
  logged time-link.log "$package" timed "$work/times/link" "${build_env[@]}" "${link_words[@]}"
  timed "$work/times/sign" /usr/bin/codesign --force -s - "$relinked" 2>>"$work/log/sign.log"
done
/usr/bin/codesign --verify --strict "$relinked" || fail "the last relinked editor's signature does not verify"
echo "   relinked editor: $(mb "$(bytes "$relinked")") MB (the built editor: $(mb "$(bytes "$dev_editor")") MB)"
echo "   time, median of 5, seconds of wall clock:"
echo "     the package build, clean (lake build UserLinkFixture): $(median <"$work/times/package")"
echo "     the whole build and link, clean (lake build editor):   $(median <"$work/times/whole")"
echo "     the link alone (the link line, run again):             $(median <"$work/times/link")"
echo "     the signing (codesign --force -s -):                   $(median <"$work/times/sign")"
echo "   each run, package / whole / link / sign: $(paste -d/ "$work/times/package" "$work/times/whole" "$work/times/link" "$work/times/sign" | tr '\n' ' ')"
echo "user-link-check: passed, with the $linker linker"
