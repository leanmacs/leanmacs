# A hermetic stand-in for github.com/leanmacs/leanmacs, for the checks of a
# package that names the core from git (docs/design/packages.md, "A config
# directory requires the core and the set"): sourced by
# tools/user-sets-test.sh, tools/bundle-sets.sh and tools/user-sets-check.sh.
# Defines functions only; runs nothing. Needs `git` and `lake` on the PATH
# when its functions run; it never touches the network.

# The tag the stand-in's one commit carries: the form a nightly's tag has
# (`nightly-<build id>`), which a package pins.
core_repo_tag=nightly-20000101000000

# Makes a git repository at `$1` (a directory that does not exist yet)
# standing in for the core's: `lean/lakefile.toml` names the package
# `editor-core` with one library, `lean/lean-toolchain` holds the pin `$2`
# names (a file), one commit, and the tag `$core_repo_tag`. It holds none
# of the real core's sources, so any build against a clone of it fails, and
# a clone under a set's `.lake/packages/editor-core` is plain to see.
core_repo() {
  mkdir -p "$1/lean"
  cp "$2" "$1/lean/lean-toolchain"
  printf '# A stand-in for the core, made by tools/core-repo.sh.\nname = "editor-core"\n\n[[lean_lib]]\nname = "EditorCoreStub"\n' \
    >"$1/lean/lakefile.toml"
  printf '/-! A stand-in for the core: none of its sources. -/\n' >"$1/lean/EditorCoreStub.lean"
  (
    cd "$1"
    git init -q
    git add -A
    git -c user.name=core-repo -c user.email=core-repo@example.invalid -c commit.gpgsign=false \
      commit -qm 'A stand-in for the core'
    git -c tag.gpgsign=false tag "$core_repo_tag"
  )
}

# Copies the package at `$1` to `$2` (which must not exist), without its
# `.lake/`, naming the core from the git repository at `$3` (made by
# `core_repo`) as a published package does: the `path = …` line of its
# `editor-core` table becomes `git = "file://$3"`, `subDir = "lean"` and
# `rev = "$core_repo_tag"`. Its `lake-manifest.json` is then written as its
# author's would be, by `lake update --keep-toolchain` run in the copy
# against the stand-in (a `file://` clone, no network), and the copy's
# `.lake/` is removed again.
git_core_copy() {
  cp -RL "$1" "$2"
  rm -rf "$2/.lake" "$2/lake-manifest.json"
  awk -v url="file://$3" -v rev="$core_repo_tag" '
    /^\[\[require\]\]/ { table = 1; core = 0 }
    /^\[\[lean_lib\]\]/ { table = 0 }
    table && /^name = "editor-core"$/ { core = 1 }
    table && core && /^path = / {
      print "git = \"" url "\""
      print "subDir = \"lean\""
      print "rev = \"" rev "\""
      next
    }
    { print }' "$1/lakefile.toml" >"$2/lakefile.toml"
  grep -qxF "git = \"file://$3\"" "$2/lakefile.toml" || {
    echo "core-repo: $1/lakefile.toml has no editor-core table by path to point at $3" >&2
    return 1
  }
  (cd "$2" && lake update --keep-toolchain >"$2.update-log" 2>&1) || {
    cat "$2.update-log" >&2
    echo "core-repo: lake update in $2 failed" >&2
    return 1
  }
  rm -rf "$2/.lake" "$2.update-log"
}
