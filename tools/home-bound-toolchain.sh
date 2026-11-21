#!/bin/sh
# Runs a command with a `lean` and a `lake` that, like elan's proxies, are
# bound to the HOME they were made under:
#
#   sh tools/home-bound-toolchain.sh <command...>
#
# On CI `lean` and `lake` come from elan, whose proxies find their
# toolchains under $ELAN_HOME, by default $HOME/.elan. A check that moves
# HOME and then runs the bare `lake` gets another copy of the toolchain,
# which elan installs under the new HOME, and the default editor's link
# trace names the toolchain's directory, so that copy reads the editor as
# out of date. mise's `lean`, on a developer's PATH, does not depend on
# HOME and hides this. With these shims first on the PATH, a `lean` or
# `lake` run under any other HOME exits 1 and says so, on every machine
# (docs/dev-practices/the-gate.md, "The user sets test"); under the HOME
# they were made under, each runs the real tool, found on the PATH when
# the shims are made.
#
# It writes only its own temporary directory, removed on exit.
set -eu

if [ "$#" -eq 0 ]; then
  echo 'usage: sh tools/home-bound-toolchain.sh <command...>' >&2
  exit 2
fi

bin=$(mktemp -d)
trap 'rm -rf "$bin"' EXIT
trap 'exit 1' HUP INT TERM

for tool in lean lake; do
  real=$(command -v "$tool") || {
    echo "home-bound-toolchain: no $tool on the PATH" >&2
    exit 2
  }
  cat >"$bin/$tool" <<EOF
#!/bin/sh
if [ "\$HOME" != '$HOME' ]; then
  echo "home-bound-toolchain: $tool run with HOME=\$HOME, not $HOME: a toolchain manager that resolves under HOME (elan) would run another toolchain" >&2
  exit 1
fi
exec '$real' "\$@"
EOF
  chmod +x "$bin/$tool"
done

PATH="$bin:$PATH" "$@"
