/-!
# Where a user's package-set editors live

The layout of per-user editors under the data directory
(`docs/design/packages.md`, "User package sets"):

```
<data>/editors/<core>/<n>/editor     an installed editor, n = 1, 2, …
<data>/editors/staging-<k>/          a build's install before it is published
```

- **`<core>`** is the core's identity (`editor.core`), so an editor linked
  against another core is never started.
- **`<n>`** is a decimal number, one more than the largest there
  (`nextVersion`). A version is published by renaming its staging
  directory to it, which is atomic within one file system; the launcher
  considers only numeric directories that hold `editor`
  (`crates/editor-launch/src/editors.rs`).
- **Pruning** after a publish (`pruned`) removes this core's versions
  older than the one before the new one, every other core's directory but
  the one that holds the running executable, and leftover staging
  directories.

Pure: `model-test` pins it (`ModelTest.packageSetBuildChecks`).
-/

namespace Editor.PackageSet

/-- `<data>/editors`. -/
def editorsDirectory (data : String) : String :=
  data ++ "/editors"

/-- `<data>/editors/<core>`. -/
def coreDirectory (data core : String) : String :=
  editorsDirectory data ++ "/" ++ core

/-- `<data>/editors/<core>/<n>`. -/
def versionDirectory (data core : String) (n : Nat) : String :=
  coreDirectory data core ++ "/" ++ toString n

/-- The staging directory a build numbered `k` installs into:
`<data>/editors/staging-<k>`. -/
def stagingDirectory (data : String) (k : Nat) : String :=
  editorsDirectory data ++ s!"/staging-{k}"

/-- The version a directory's name is: all decimal digits, and at least
one. -/
def versionOf? (name : String) : Option Nat :=
  if !name.isEmpty && name.all Char.isDigit then name.toNat? else none

/-- The number of the next version, given the names in the core's
directory: one more than the largest version there, or 1. -/
def nextVersion (names : Array String) : Nat :=
  (names.filterMap versionOf?).foldl max 0 + 1

/-- The number of the next staging directory, given the names in
`<data>/editors`: one more than the largest `staging-<k>` there, or 1. -/
def nextStaging (names : Array String) : Nat :=
  (names.filterMap fun name =>
          if name.startsWith "staging-" then versionOf? (name.drop 8).toString else none).foldl
      max 0 +
    1

/-- The directories to remove after version `n` of `core` was published
(`pruned`, "Pruning" in the module docs): given the names in the core's
directory (`versions`), the names in `<data>/editors` (`entries`) and the
running executable, this core's versions below `n - 1`, every other core's
directory but the one the running executable is under, and every staging
directory. -/
def pruned (data core : String) (n : Nat) (versions entries : Array String) (running : String) :
    Array String :=
  let old :=
    (versions.filterMap fun name => (versionOf? name).filter (· + 1 < n)).qsort (· < ·) |>.map
      (versionDirectory data core)
  let others :=
    entries.filterMap fun name =>
      if name == core then none
      else
        if name.startsWith "staging-" then some (editorsDirectory data ++ "/" ++ name)
        else
          let directory := editorsDirectory data ++ "/" ++ name
          if running.startsWith (directory ++ "/") then none else some directory
  old ++ others

end Editor.PackageSet
