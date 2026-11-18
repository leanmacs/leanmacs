#!/bin/sh
# Installs elan on a CI runner (.github/workflows/ci.yml, the `ci` job):
#
#   sh tools/ci/install-elan.sh
#
# CI only. On the owner's machine `lean` and `lake` come from mise's local
# `lean` plugin (mise.toml, [tools]), which a runner does not have; in the
# Linux container they come from the elan the image installs
# (tools/linux/Dockerfile). Either way `lean/lean-toolchain` stays the one pin
# of the Lean toolchain: elan reads it and installs that toolchain on first
# use.
#
# ELAN_VERSION must equal the Dockerfile's, and the Linux checksums are the
# Dockerfile's (tools/workflow-check.sh fails when the versions differ). The
# download is checked against the SHA-256 of the release file before it
# runs.
#
# Idempotent: when `~/.elan/bin/elan` is already this version (restored from
# the cache) nothing is downloaded. Either way `~/.elan/bin` is appended to
# $GITHUB_PATH when that is set, so the later steps find `lean` and `lake`.
set -eu

ELAN_VERSION=4.2.4
ELAN_SHA256_AARCH64_APPLE_DARWIN=7ad829861392c718dfebde3a83b5c8508df47be02af68894b094b0b3952616e5
ELAN_SHA256_X86_64_LINUX=42b94d4244e8353142c456ec0e4ca6528fd898a6c604d4059f494e706e431f63
ELAN_SHA256_AARCH64_LINUX=05febd124d84ebf994b2e7479922a5650b1e950c17ae3bd1ddd776b65bb72bf9

case "$(uname -s)/$(uname -m)" in
Darwin/arm64)
  triple=aarch64-apple-darwin
  sum=$ELAN_SHA256_AARCH64_APPLE_DARWIN
  ;;
Linux/x86_64)
  triple=x86_64-unknown-linux-gnu
  sum=$ELAN_SHA256_X86_64_LINUX
  ;;
Linux/aarch64)
  triple=aarch64-unknown-linux-gnu
  sum=$ELAN_SHA256_AARCH64_LINUX
  ;;
*)
  printf 'install-elan: no elan release is pinned for %s/%s\n' \
    "$(uname -s)" "$(uname -m)" >&2
  exit 1
  ;;
esac

elan_home=${ELAN_HOME:-$HOME/.elan}
elan=$elan_home/bin/elan

if [ -x "$elan" ] && "$elan" --version | grep -q "^elan $ELAN_VERSION "; then
  printf 'install-elan: elan %s is already installed\n' "$ELAN_VERSION"
else
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  file=elan-$triple.tar.gz
  curl -sSfL -o "$work/$file" \
    "https://github.com/leanprover/elan/releases/download/v$ELAN_VERSION/$file"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$work" && printf '%s  %s\n' "$sum" "$file" | sha256sum -c -)
  else
    (cd "$work" && printf '%s  %s\n' "$sum" "$file" | shasum -a 256 -c -)
  fi
  tar -xzf "$work/$file" -C "$work"
  "$work/elan-init" -y --default-toolchain none --no-modify-path
fi

if [ -n "${GITHUB_PATH:-}" ]; then
  printf '%s\n' "$elan_home/bin" >>"$GITHUB_PATH"
fi
