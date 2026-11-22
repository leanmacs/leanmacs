#!/usr/bin/env bash
# Runs the gate on Linux, in a container (`mise run linux-ci`;
# docs/dev-practices/on-demand-checks.md, "The gate on Linux"), and the
# real window there under Xvfb
# (`mise run linux-window`), and the wgpu renderer there on a software
# Vulkan driver (`mise run linux-render`). Opt-in, never part of `ci`: it
# needs Docker and, the first time, the network.
#
#   tools/linux/run.sh ci [--clean]
#   tools/linux/run.sh window
#   tools/linux/run.sh render
#
# It builds the image from the Dockerfile beside it and copies the checkout
# into a work directory. `ci` runs `mise run ci` there, and its exit status is
# the gate's. `window` builds the editor there and runs seven things under
# Xvfb, a display that needs no screen and no person, failing if any fails:
# the winit adapter's example, which holds the real window to the window
# port's contract; `editor window-check`, with xdotool giving the window the
# focus and typing into it; the same with composition not allowed; the
# window that draws, `editor-ffi`'s example, with the wgpu renderer drawing
# a fixture frame in the real window on Mesa's software Vulkan driver and
# xdotool giving it keys, the pointer and a resize, once at the display's
# own scale of 1, ending with a change of scale to 2, and once at scale 2
# from the start; the arboard adapter's
# example, which holds that display's clipboard to the clipboard port's
# contract; text written to it by one process, read by another; and the
# editor on a file, `editor --report <file>`, with xdotool typing an edit,
# `:w` and `:q`, after which the file must hold the edit. Its input is
# synthetic, and its output says so. The clipboard is the
# container's own: nothing of the host's is read or written. `render` runs
# the renderer's example there (`crates/editor-render-wgpu/examples/gpu.rs`):
# the wgpu
# adapter on Mesa's software Vulkan driver, llvmpipe, held to the renderer
# port's contract and compared with the reference image; its exit status is
# the example's.
#
# The source is copied, never mounted in place: the tracked files and the
# untracked files git does not ignore, so uncommitted work is tested and the
# host's own build output (`target/`, `lean/.lake/`) is never touched.
#
# Where state lives:
#
# - `${EDITOR_LINUX_CACHE:-.linux-ci}`, a directory of the host at the root of
#   the checkout (ignored by git): `home/` holds the toolchains (rustup's,
#   elan's, mise's installs) and `work/` the copy of the source with the
#   core's Lake build output and the formatter's clone (`lean/.lake`). It is
#   not under `target/`, so `cargo clean` leaves it alone. Only `lean/.lake`
#   is kept from one run to the next: the copy removes everything else, the
#   build output of the package sets and of the packages among it
#   (`packages/.lake`, `tests/packages/**/.lake`), so every run writes the
#   sets' roots again, rebuilds the fixture packages and links the editors.
#   That is seconds on top of the core's modules, which are kept.
# - The Docker volume `${EDITOR_LINUX_VOLUME:-editor-linux-ci-cargo}`: Cargo's
#   home and Cargo's `target/`. These two must not be on a directory mounted
#   from macOS. With them there, clean runs of the gate failed within seconds
#   once the dependency graph was large (`failed to map object file`, `failed
#   to create encoded metadata from file`); `ci` runs `lint`, `doc` and `test`
#   at once, and file locks do not seem to hold on that mount.
#
# Docker's disk is the scarce one, so in the container Cargo's development
# profile is built without debug information (`CARGO_PROFILE_DEV_DEBUG=0`).
# Nothing the gate does reads it: the same lints, documentation and tests run
# and a failing test still names itself, only without line numbers in a
# backtrace. With it, `target/` on the volume was 2.1 GB once the window
# library was in the dependency graph.
#
# `--clean` empties the copy's `lean/.lake/build/` and Cargo's `target/` before
# the gate runs, and keeps the toolchains and Cargo's registry: everything is
# compiled again and nothing is downloaded again. The sets' and the packages'
# build output needs no emptying: no run keeps it.
#
# The same file is the script that runs inside the container (`inside …`),
# where it is read from the copy.

set -euo pipefail

die() {
  echo "linux: $*" >&2
  exit 1
}

usage() {
  die "usage: tools/linux/run.sh ci [--clean] | window | render"
}

# ---- Inside the container ----

# Points the copy's `target/` at the volume, makes the copy a git repository
# of its own (the `c-fmt` task lists files with `git ls-files`) and installs
# the tools `mise.toml` pins.
#
# The volume's `target/` is made here, not by Cargo, so it is given the
# `CACHEDIR.TAG` Cargo writes in a target directory it makes: without it
# `cargo clean`, which the lakefile runs when a cached Rust archive left no
# list of its system libraries (lean/lakefile.lean, `buildRust`), refuses
# the directory ("missing or invalid `CACHEDIR.TAG` file").
inside_prepare() {
  mkdir -p /cargo/home /cargo/target
  [ -f /cargo/target/CACHEDIR.TAG ] ||
    printf '%s\n' 'Signature: 8a477f597d28d172789f06886806bc55' \
      '# This file is a cache directory tag created by cargo.' \
      '# For information about cache directory tags see https://bford.info/cachedir/' \
      >/cargo/target/CACHEDIR.TAG
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
    find /cargo/target -mindepth 1 ! -path /cargo/target/CACHEDIR.TAG -delete
  fi
  inside_versions

  local start status=0
  start=$(date +%s)
  mise run ci || status=$?
  echo "linux: \`mise run ci\` exited $status after $(($(date +%s) - start)) s (clean build: $clean)"
  if [ "$status" -eq 0 ]; then
    ls -l /work/packages/.lake/build/bin/editor
    (cd /work/lean/.lake/build/bin && ls -l ffi-test config-test contract-test model-test)
    ldd /work/packages/.lake/build/bin/editor
  fi
  return "$status"
}

# Runs `editor window-check` under the display, with xdotool giving the
# window the focus and typing into it: synthetic keys, sent through the X
# server, so they take the real window library's path. Fails if the window
# did not run or no key reached the Lean loop. `$1` is a label and the rest
# are the tool's own arguments.
inside_typed_check() {
  local label=$1
  shift
  echo "linux-window: $label, on keys typed by xdotool under Xvfb: synthetic, nobody at a keyboard"
  (
    # The window, once it is there; then the focus; then the keys: a
    # sentence, and a dead key followed by a letter.
    window=$(timeout 10 xdotool search --sync --name 'editor: window check' | head -n 1)
    timeout 5 xdotool windowfocus --sync "$window"
    sleep 0.3
    xdotool type --delay 20 'the quick brown fox'
    xdotool key dead_acute e
  ) &
  local typist=$! report status=0
  report=$(/work/packages/.lake/build/bin/editor window-check --seconds 5 "$@") || status=$?
  wait "$typist" || true
  printf '%s\n' "$report"
  [ "$status" -eq 0 ] || die "the keyboard check exited $status"
  if printf '%s\n' "$report" | grep -q '^keys: 0 key events'; then
    die "no key reached the Lean loop"
  fi
}

# The editor on a file under the display (`editor <file>`,
# lean/Editor/Window/Real.lean): a copy of `tests/window/session.txt` in a
# temporary directory, opened with `--report` and no toolchain, so no config
# is loaded. xdotool gives the window the focus and types `ihello `,
# `<Escape>`, `:w` and `<Return>`, then `:q` and `<Return>`. The editor must
# exit 0 within 60 seconds, the copy must hold the bytes of
# `tests/window/session-expected`, and the report, on stderr once the window
# has closed, must count at least one frame. The report is printed: its
# figures are Xvfb's and llvmpipe's, not milestone figures.
inside_editor_session() {
  local dir log=/tmp/editor-session.log pid status=0 waited=0
  dir=$(mktemp -d)
  cp /work/tests/window/session.txt "$dir/session.txt"
  : >"$log"
  /work/packages/.lake/build/bin/editor --report "$dir/session.txt" 2>"$log" &
  pid=$!
  (
    window=$(timeout 10 xdotool search --sync --name 'editor: window check' | head -n 1)
    timeout 5 xdotool windowfocus --sync "$window"
    sleep 1
    xdotool type --delay 50 'ihello '
    xdotool key Escape
    sleep 0.5
    xdotool type --delay 50 ':w'
    xdotool key Return
    sleep 1
    xdotool type --delay 50 ':q'
    xdotool key Return
  ) || die "xdotool could not type into the editor's window: $(cat "$log")"
  while kill -0 "$pid" 2>/dev/null; do
    waited=$((waited + 1))
    if [ "$waited" -ge 600 ]; then
      kill "$pid" 2>/dev/null || true
      cat "$log"
      die "the editor did not quit within 60 seconds"
    fi
    sleep 0.1
  done
  wait "$pid" || status=$?
  cat "$log"
  [ "$status" -eq 0 ] || die "the editor exited $status"
  cmp "$dir/session.txt" /work/tests/window/session-expected ||
    die "the file the editor saved is not tests/window/session-expected"
  grep -q '^frames: [1-9]' "$log" || die "the editor's report counts no frame"
  rm -rf "$dir"
}

# Text written to the clipboard by one process and read by another, which
# one process cannot show: on X11 the text is served by the process that
# wrote it, so the writer stays alive while the reader reads. Fails if the
# text read is not the text written.
inside_clipboard_across() {
  local text='held by another process: é, 日本' held=/tmp/clipboard-hold.log
  local holder got waited=0
  /work/target/debug/examples/clipboard hold "$text" 10 >"$held" 2>&1 &
  holder=$!
  until grep -q '^clipboard: holding' "$held"; do
    waited=$((waited + 1))
    [ "$waited" -lt 50 ] || die "the clipboard was not written: $(cat "$held")"
    sleep 0.1
  done
  got=$(/work/target/debug/examples/clipboard read) ||
    die "another process could not read the clipboard"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  printf 'clipboard: one process wrote "%s"; another read "%s"\n' "$text" "$got"
  [ "$got" = "$text" ] || die "the text read is not the text written"
}

# The window that draws (`crates/editor-ffi/examples/window/`): the real
# window with the wgpu renderer drawing a fixture frame in it, on Mesa's
# software Vulkan driver, and xdotool giving it input once it says it is
# ready: a key, a named key, a key with modifiers, a press, a drag, a
# release, a turn of the wheel and a resize. Fails if the example fails
# (a frame not laid out at the window's scale, no frame presented, a
# picture that is not the frame's, a frame drawn that nothing asked for,
# no input), if no frame at the scale asked for said its 14 points are 14
# pixels times that scale, or if any of those inputs did not come off the
# queue as the port documents it.
#
# `$1` is the scale the window is to be at: 1 or 2. Xvfb's display is at
# scale 1, and for 1 the window is opened on it as it is. For 2 winit is
# told the scale in `WINIT_X11_SCALE_FACTOR`, which its X11 back end takes
# in place of what the display says (seen at the pin: the window then
# says scale 2 as it opens, and the pictures are compared as at scale 1).
# This is the run that shows the window's scale reaching layout: at scale
# 1 a layout that was never told the scale lays out the same, and at 2 it
# does not. It is winit that is told, not the display: nothing here is a
# display at scale 2.
#
# The run at scale 1 ends with a change of scale, to 2, while the window
# is open: the one way here to make winit send the event for it, which no
# test can build, so that the line of the adapter that takes it apart is
# run (`App::window_event`, the `ScaleFactorChanged` arm). winit's X11
# back end hears of a scale from the display's settings: `Xft/DPI` of
# XSETTINGS when a daemon serves them, else `Xft.dpi` of the X resources.
# It is told of a change to the first and not, here, of a change to the
# second: nothing selects property changes on the root window, so `xrdb
# -merge` of another `Xft.dpi` reached no window (seen), with or without a
# RandR event after it. So xsettingsd serves 96 dots an inch from before
# the window opens, and once the resize has arrived and been drawn its
# file is rewritten to 192 and it is signalled to read it again. The port
# documents a change of scale as a resize at the size last known and the
# new scale, so the run requires `input: resized 300 by 120 at scale 2`.
# winit then asks the X server for the window at twice its size, and that
# resize arrives as its own or does not (600 by 240, seen eighteen times
# of twenty): it is not required.
#
# `--require-picture`: every frame's picture must have been read back from
# the surface and compared, or the example fails. Without it the example
# lets a surface pass that does not let its texture be copied from, which
# a desktop's may be. This one does (llvmpipe's, seen), so here a picture
# that was not compared is a read-back that broke.
inside_drawing_window() {
  local scale=$1 log=/tmp/window-$1.log pid window status=0 waited=0 wanted
  local settings=/tmp/xsettings.conf serving=/tmp/xsettingsd.log daemon=
  local -a told=()
  [ "$scale" = 1 ] || told=("WINIT_X11_SCALE_FACTOR=$scale")
  echo "linux-window: 4 of 7, the window at scale $scale"
  if [ "$scale" = 1 ]; then
    # The display's settings, served before the window opens: winit asks
    # who owns them once, as it connects. `Xft/DPI` is in 1024ths of a
    # dot an inch, and 96 dots an inch is a scale of 1.
    printf 'Xft/DPI %d\n' $((96 * 1024)) >"$settings"
    : >"$serving"
    xsettingsd -c "$settings" >"$serving" 2>&1 &
    daemon=$!
    until grep -q 'Took ownership of selection' "$serving"; do
      waited=$((waited + 1))
      if [ "$waited" -ge 50 ] || ! kill -0 "$daemon" 2>/dev/null; then
        die "xsettingsd did not come to serve the display's settings: $(cat "$serving")"
      fi
      sleep 0.1
    done
    waited=0
  fi
  # The log is there before it is read.
  : >"$log"
  env "${told[@]}" /work/target/debug/examples/window --seconds 6 --require-picture >"$log" 2>&1 &
  pid=$!
  # The example says so once it has drawn its frame and left the window
  # alone for a second: nothing is sent before, so that second is idle.
  until grep -q '^window: ready for input' "$log"; do
    waited=$((waited + 1))
    if [ "$waited" -ge 600 ] || ! kill -0 "$pid" 2>/dev/null; then
      cat "$log"
      die "the window that draws, at scale $scale, was never ready for input"
    fi
    sleep 0.1
  done
  window=$(timeout 10 xdotool search --sync --name 'editor: window check' | head -n 1)
  timeout 5 xdotool windowfocus --sync "$window"
  sleep 0.3
  xdotool key a
  xdotool key Escape
  xdotool key ctrl+shift+a
  xdotool mousemove --window "$window" 10 20
  xdotool mousedown 1
  xdotool mousemove --window "$window" 30 40
  xdotool mouseup 1
  xdotool click 4
  xdotool windowsize "$window" 300 120
  if [ -n "$daemon" ]; then
    # The change of scale, once the resize has arrived: before it, the
    # size last known would be the one the window opened at, or the two
    # would race.
    waited=0
    until grep -qF -- "input: resized 300 by 120 at scale 1" "$log"; do
      waited=$((waited + 1))
      if [ "$waited" -ge 100 ] || ! kill -0 "$pid" 2>/dev/null; then
        cat "$log"
        die "the resize did not come off the queue, so the scale was not changed after it"
      fi
      sleep 0.1
    done
    # And once the window has been left alone at that size for a second:
    # the frame laid out for the resize is drawn and judged first, as in
    # the run at scale 2, and not overtaken by the frame for the scale.
    sleep 1.5
    printf 'Xft/DPI %d\n' $((192 * 1024)) >"$settings"
    kill -HUP "$daemon"
  fi
  wait "$pid" || status=$?
  if [ -n "$daemon" ]; then
    kill "$daemon" 2>/dev/null || true
    wait "$daemon" 2>/dev/null || true
  fi
  cat "$log"
  [ "$status" -eq 0 ] || die "the window that draws, at scale $scale, exited $status"
  # The fixture's text is 14 points: a frame laid out at the scale the
  # window said has glyphs of 14 pixels times that scale. The example
  # fails by itself on any other size; this is that it said so of a frame
  # at all, and of one at the scale this run asked for. At scale 1 a
  # layout never told the scale gives the same line, so there it shows
  # the fixture's 14 points reaching the shaper; at scale 2 it shows the
  # window's scale reaching layout.
  grep -qF -- "at scale $scale: 14 points are $((14 * scale)) pixels" "$log" ||
    die "no frame said it is laid out at scale $scale and its 14 points are $((14 * scale)) pixels"
  # Each input as the port documents it, read back from its event. The key
  # with control held carries no text, whatever the X server gave it (`A`,
  # seen): a key pressed with control or the system key inserts nothing.
  for wanted in \
    "input: key press 'a' at KeyA with none, text \"a\"" \
    "input: key press Escape at Escape with none, text \"\"" \
    "input: key press 'A' at KeyA with shift+control, text \"\"" \
    "input: pointer press primary at (10, 20) with none" \
    "input: pointer drag primary at (30, 40) with none" \
    "input: pointer release primary at (30, 40) with none" \
    "input: pointer wheel 0 across and 1 down in lines at (30, 40) with none" \
    "input: resized 300 by 120 at scale $scale"; do
    grep -qF -- "$wanted" "$log" ||
      die "at scale $scale, no input came off the queue as: $wanted"
  done
  # The change of scale, as the port documents it: a resize at the size
  # last known and the new scale. The window opened at scale 1, so the
  # line is after the change.
  if [ -n "$daemon" ]; then
    wanted="input: resized 300 by 120 at scale 2"
    grep -qF -- "$wanted" "$log" ||
      die "the change of scale did not come off the queue as: $wanted"
  fi
}

# The real window on a display that needs no screen and no person (Xvfb):
# the winit adapter held to the window port's contract, then the keyboard
# check with composition allowed and with it not, then the window that
# draws; and the clipboard of that display, which is the container's own:
# the arboard adapter held to the clipboard port's contract, then a round
# trip across two processes.
inside_window() {
  [ $# -eq 0 ] || usage
  inside_prepare
  inside_versions

  # What it runs: the editor, built as the gate builds it, and the adapters'
  # examples.
  mise run lean
  mise exec -- cargo build --locked --package editor-platform-winit --example contract
  mise exec -- cargo build --locked --package editor-platform-arboard --example clipboard
  mise exec -- cargo build --locked --package editor-ffi --example window

  Xvfb :99 -screen 0 1024x768x24 >/tmp/xvfb.log 2>&1 &
  local display=$!
  export DISPLAY=:99
  local waited=0
  until xdotool getdisplaygeometry >/dev/null 2>&1; do
    waited=$((waited + 1))
    [ "$waited" -lt 50 ] || die "Xvfb did not start: $(cat /tmp/xvfb.log)"
    sleep 0.1
  done

  echo "linux-window: 1 of 7: the winit platform against the window port's contract, under Xvfb"
  /work/target/debug/examples/contract

  inside_typed_check "2 of 7: the keyboard check"
  inside_typed_check "3 of 7: the keyboard check with composition not allowed" --no-ime

  echo "linux-window: 4 of 7: the window that draws a fixture frame, at scale 1 and then at scale 2, with input given by xdotool: synthetic, nobody at a keyboard"
  inside_drawing_window 1
  inside_drawing_window 2

  echo "linux-window: 5 of 7: the system clipboard against the clipboard port's contract, in one process, under Xvfb"
  /work/target/debug/examples/clipboard contract

  echo "linux-window: 6 of 7: text written to the clipboard by one process, read by another"
  inside_clipboard_across

  echo "linux-window: 7 of 7: the editor on a file, with an edit, :w and :q typed by xdotool: synthetic, nobody at a keyboard; its report's figures are Xvfb's and llvmpipe's"
  inside_editor_session

  kill "$display"
  echo "linux-window: all seven passed"
}

# The wgpu renderer on a real adapter with no GPU: Mesa's software Vulkan
# driver, llvmpipe, which the image installs. The example opens no window;
# it draws to a texture and reads it back.
inside_render() {
  [ $# -eq 0 ] || usage
  inside_prepare
  inside_versions
  echo "linux-render: the wgpu renderer on Mesa's software Vulkan driver"
  mise exec -- cargo run --locked --package editor-render-wgpu --example gpu
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

  # No debug information in Cargo's development builds: see the header.
  docker run --rm --init \
    --volume "$cache/work:/work" \
    --volume "$cache/home:/cache" \
    --volume "$volume:/cargo" \
    --env CARGO_PROFILE_DEV_DEBUG=0 \
    "$image" /work/tools/linux/run.sh inside "$mode" "$@"
}

[ $# -ge 1 ] || usage
case "$1" in
ci | window | render)
  on_host "$@"
  ;;
inside)
  shift
  [ $# -ge 1 ] || usage
  mode=$1
  shift
  case "$mode" in
  ci) inside_ci "$@" ;;
  window) inside_window "$@" ;;
  render) inside_render "$@" ;;
  *) usage ;;
  esac
  ;;
*)
  usage
  ;;
esac
