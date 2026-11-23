#!/bin/sh
# The one source of the wait bans (the root `clippy.toml`; AGENTS.md,
# "Deterministic concurrency in tests"): the root `clippy.toml` holds the
# block of `disallowed-methods` entries that bans the raw timed waits and
# the readouts a test waits on, between a line `# BEGIN wait-bans` and a
# line `# END wait-bans`. Clippy reads only the first `clippy.toml` it
# finds walking up from a crate, so each `crates/*/clippy.toml` holds a
# copy of that block, byte for byte; this script writes the copies and
# checks them, and hands the gate the paths the block bans.
#
#   tools/wait-bans.sh paths <root>             the block's paths, one a line
#   tools/wait-bans.sh check <root> <conf>...   each conf's block is the root's
#   tools/wait-bans.sh write <root> <conf>...   make each conf's block the root's
#
# A path is the `path = "..."` of an entry of the block, each entry on a
# line of its own. `write` replaces what lies between a conf's two marker
# lines, the markers included, and keeps every other line of it as it is.
#
# `paths` and `write` exit 0. `check` exits 0 when every conf's block is
# the root's, and otherwise prints each conf whose block differs, one a
# line, and exits 1. Every mode exits 2, with the reason on stderr, for a
# command line it does not take, a file it cannot read, a file without
# exactly one `# BEGIN wait-bans` line followed by one `# END wait-bans`
# line, and a root whose block bans no path, which would let the gate pass
# for no reason.
set -eu

usage() {
  echo "usage: tools/wait-bans.sh paths <root> | check <root> <conf>... | write <root> <conf>..." >&2
  exit 2
}

# The block of the file $1, its marker lines included; exit 2 if the file
# cannot be read or does not hold exactly one closed block.
block() {
  if [ ! -r "$1" ] || [ -d "$1" ]; then
    echo "wait-bans: cannot read $1" >&2
    exit 2
  fi
  awk '
    /^[[:space:]]*# BEGIN wait-bans/ { begins++; if (open) bad = 1; open = 1 }
    open { print }
    /^[[:space:]]*# END wait-bans/ { ends++; if (!open) bad = 1; open = 0 }
    END { if (bad || open || begins != 1 || ends != 1) exit 3 }
  ' "$1" || {
    echo "wait-bans: $1 does not hold exactly one block from a '# BEGIN wait-bans' line to a '# END wait-bans' line" >&2
    exit 2
  }
}

# The paths of the block $1 (its text), one a line.
paths_of() {
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*{[[:space:]]*path[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p'
}

[ "$#" -ge 2 ] || usage
mode=$1
root=$2
shift 2

root_block=$(block "$root")
root_paths=$(paths_of "$root_block")
if [ -z "$root_paths" ]; then
  echo "wait-bans: the block of $root bans no path" >&2
  exit 2
fi

case $mode in
  paths)
    [ "$#" -eq 0 ] || usage
    printf '%s\n' "$root_paths"
    ;;
  check)
    [ "$#" -ge 1 ] || usage
    differ=
    for conf; do
      conf_block=$(block "$conf")
      [ "$conf_block" = "$root_block" ] || differ="$differ$conf
"
    done
    if [ -n "$differ" ]; then
      printf '%s' "$differ"
      exit 1
    fi
    ;;
  write)
    [ "$#" -ge 1 ] || usage
    for conf; do
      block "$conf" > /dev/null
      written="$conf.wait-bans"
      WAIT_BANS_BLOCK=$root_block awk '
        BEGIN { text = ENVIRON["WAIT_BANS_BLOCK"] "\n" }
        /^[[:space:]]*# BEGIN wait-bans/ { printf "%s", text; skipping = 1 }
        !skipping { print }
        /^[[:space:]]*# END wait-bans/ { skipping = 0 }
      ' "$conf" > "$written"
      mv "$written" "$conf"
    done
    ;;
  *)
    usage
    ;;
esac
