#!/bin/sh
# A package's Rust crate outside the editor's repository is refused by the
# package-set build with its reason (`setRustCrates` in lean/lakefile.lean;
# docs/design/packages.md, "Who can build it"): this copies the fixture
# package `echo` (tests/packages/echo) into a fresh temporary directory,
# its requires pointed at the repository by absolute path, writes a set
# there that requires the default set and the copy, and requires
# `lake query :editorRustCrates` on that set to fail saying the crate is
# outside the editor's Cargo workspace. Run from lean/, as `ffi-test` runs
# it. It writes only the temporary directory, and removes it.
set -eu

repo=$(cd .. && pwd -P)
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

mkdir "$dir/echo" "$dir/set"
(cd ../tests/packages/echo && git ls-files) | while IFS= read -r file; do
  mkdir -p "$dir/echo/$(dirname "$file")"
  cp "../tests/packages/echo/$file" "$dir/echo/$file"
done
rm -f "$dir/echo/lake-manifest.json"
sed "s|from \"..\" / \"..\" / \"..\" / \"lean\"|from \"$repo/lean\"|" ../tests/packages/echo/lakefile.lean >"$dir/echo/lakefile.lean"
sed "s|path = \"../../../../crates/editor-service\"|path = \"$repo/crates/editor-service\"|" ../tests/packages/echo/rust/Cargo.toml >"$dir/echo/rust/Cargo.toml"
cp lean-toolchain "$dir/set/lean-toolchain"
printf 'name = "outside"\n\n[[require]]\nname = "default-set"\npath = "%s/packages"\n\n[[require]]\nname = "echo"\npath = "../echo"\n' "$repo" >"$dir/set/lakefile.toml"
lake -d "$dir/set" update -q --keep-toolchain
status=0
out=$(lake -d "$dir/set" query :editorRustCrates 2>&1) || status=$?
expected="echo's Rust crate echo-service is outside the editor's Cargo workspace ($repo): building a third party's Rust is not supported yet; see docs/design/packages.md, 'Who can build it'"
if [ "$status" -eq 0 ] || ! printf '%s\n' "$out" | grep -qF "$expected"; then
  printf '%s\n' "$out"
  echo "rust-outside-check: a crate outside the repository was not refused (exit $status)" >&2
  exit 1
fi
echo "rust-outside-check: echo's crate outside the repository was refused with its reason"
