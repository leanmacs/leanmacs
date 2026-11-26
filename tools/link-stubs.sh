#!/bin/sh
exec cargo run --quiet --locked --manifest-path "$(dirname "$0")/../Cargo.toml" -p editor-release-std --bin link-stubs -- "$@"
