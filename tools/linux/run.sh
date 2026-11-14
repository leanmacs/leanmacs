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
# the gate's. `window` builds the editor there and runs six things under
# Xvfb, a display that needs no screen and no person, failing if any fails:
# the winit adapter's example, which holds the real window to the window
# port's contract; `editor window-check`, with xdotool giving the window the
# focus and typing into it; the same with composition not allowed; the
# window that draws, `editor-ffi`'s example, with the wgpu renderer drawing
# a fixture frame in the real window on Mesa's software Vulkan driver and
# xdotool giving it keys, the pointer and a resize; the arboard adapter's
# example, which holds that display's clipboard to the clipboard port's
# contract; and text written to it by one process, read by another. Its
# input is synthetic, and its output says so. The clipboard is the
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
#   elan's, mise's installs) and `work/` the copy of the source with Lake's
#   build output. It is not under `target/`, so `cargo clean` leaves it alone.
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
  die "usage: tools/linux/run.sh ci [--clean] | window | render"
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
  report=$(/work/lean/.lake/build/bin/editor window-check --seconds 5 "$@") || status=$?
  wait "$typist" || true
  printf '%s\n' "$report"
  [ "$status" -eq 0 ] || die "the keyboard check exited $status"
  if printf '%s\n' "$report" | grep -q '^keys: 0 key events'; then
    die "no key reached the Lean loop"
  fi
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

# The window that draws (`crates/editor-ffi/examples/window.rs`): the real
# window with the wgpu renderer drawing a fixture frame in it, on Mesa's
# software Vulkan driver, and xdotool giving it input once it says it is
# ready: a key, a named key, a key with modifiers, a press, a drag, a
# release, a turn of the wheel and a resize. Fails if the example fails
# (a frame not laid out at the window's scale, no frame presented, a
# picture that is not the frame's, a frame drawn that nothing asked for,
# no input), if no frame said its 14 points are 14 pixels, or if any of
# those inputs did not come off the queue as the port documents it.
#
# `--require-picture`: every frame's picture must have been read back from
# the surface and compared, or the example fails. Without it the example
# lets a surface pass that does not let its texture be copied from, which
# a desktop's may be. This one does (llvmpipe's, seen), so here a picture
# that was not compared is a read-back that broke.
inside_drawing_window() {
  local log=/tmp/window.log pid window status=0 waited=0 wanted
  /work/target/debug/examples/window --seconds 6 --require-picture >"$log" 2>&1 &
  pid=$!
  # The example says so once it has drawn its frame and left the window
  # alone for a second: nothing is sent before, so that second is idle.
  until grep -q '^window: ready for input' "$log"; do
    waited=$((waited + 1))
    if [ "$waited" -ge 600 ] || ! kill -0 "$pid" 2>/dev/null; then
      cat "$log"
      die "the window that draws was never ready for input"
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
  wait "$pid" || status=$?
  cat "$log"
  [ "$status" -eq 0 ] || die "the window that draws exited $status"
  # The display is at scale 1 and the fixture's text is 14 points: a frame
  # laid out at the scale the window said has glyphs of 14 pixels. The
  # example fails by itself on any other size; this is that it said so of
  # a frame at all.
  grep -qF -- ": 14 points are 14 pixels" "$log" ||
    die "no frame was laid out at the window's scale: no line says 14 points are 14 pixels"
  # Each input as the port documents it, read back from its event. The key
  # with modifiers is matched up to its text, which the X server decides.
  for wanted in \
    "input: key press 'a' at KeyA with none, text \"a\"" \
    "input: key press Escape at Escape with none, text \"\"" \
    "input: key press 'A' at KeyA with shift+control, text " \
    "input: pointer press primary at (10, 20) with none" \
    "input: pointer drag primary at (30, 40) with none" \
    "input: pointer release primary at (30, 40) with none" \
    "input: pointer wheel 0 across and 1 down in lines at (30, 40) with none" \
    "input: resized 300 by 120 at scale 1"; do
    grep -qF -- "$wanted" "$log" || die "no input came off the queue as: $wanted"
  done
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

  echo "linux-window: 1 of 6: the winit platform against the window port's contract, under Xvfb"
  /work/target/debug/examples/contract

  inside_typed_check "2 of 6: the keyboard check"
  inside_typed_check "3 of 6: the keyboard check with composition not allowed" --no-ime

  echo "linux-window: 4 of 6: the window that draws a fixture frame, with input given by xdotool: synthetic, nobody at a keyboard"
  inside_drawing_window

  echo "linux-window: 5 of 6: the system clipboard against the clipboard port's contract, in one process, under Xvfb"
  /work/target/debug/examples/clipboard contract

  echo "linux-window: 6 of 6: text written to the clipboard by one process, read by another"
  inside_clipboard_across

  kill "$display"
  echo "linux-window: all six passed"
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
