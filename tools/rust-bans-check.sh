#!/bin/sh
# Checks the Rust crates of a package set with cargo-deny's bans, over the
# crate the package-set build generates from the set
# (docs/design/packages.md, "Rust in a package"; docs/dev-practices/the-gate.md,
# "The Rust bans check"): a package's crate may depend on `editor-service`
# and on nothing else of the editor's, so neither on `editor-ffi` nor on
# another package's crate.
#
#   tools/rust-bans-check.sh <set dir>
#
# Run it in `lean/`. The set's directory holds the set's lakefile, which
# must reach the core, which defines the facet asked. It asks Lake to write
# the generated crate (`lake -d <set dir> query :editorRustCrate`, a facet
# of lean/lakefile.lean), which prints its directory and builds nothing.
# Beside the crate's manifest the generator writes a `deny.toml` in which
# the generated crate is the only crate allowed to depend on `editor-ffi`
# or on any package crate of the set, and no crate may depend on
# `editor-release-std`. The root `deny.toml` cannot say that: cargo-deny
# bans a crate nothing depends on outright under `wrappers = []`, and
# `-D unused-wrapper` fails a wrapper it never meets, while nothing in the
# root graph depends on `editor-ffi` or on a package's crate.
#
# It runs `cargo deny --offline` over that crate with that config, bans
# alone and stale wrappers errors, as `mise run deny` does over the root,
# and reads no network: the crate's lock is seeded from the root's. It
# writes the generated crate under `target/editor-rust/` and Lake's
# configuration in the set's and its packages' `.lake`, and nothing else.
#
# It exits 0 when the bans hold, and 1, with cargo-deny's report on stderr,
# when cargo-deny fails (its own status, a bit for each failed check, is 2
# for the bans). It exits 2 for a command line it does not take and when
# Lake fails the query.
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: tools/rust-bans-check.sh <set dir>" >&2
  exit 2
fi

dir=$(lake -d "$1" query :editorRustCrate) || {
  echo "rust-bans-check: lake -d $1 query :editorRustCrate failed" >&2
  exit 2
}

status=0
cargo deny --offline --manifest-path "$dir/Cargo.toml" check --config "$dir/deny.toml" \
  -D unused-wrapper bans || status=1
exit "$status"
