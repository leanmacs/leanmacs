import Editor.Test.Fixture.Fixture

/-!
# The headless fixture harness: discovery

Which fixtures a discovery root holds, read through a port over the
repository's files (`Tree`), whose real adapter is the harness's edge
(`Editor/Test/Fixture/Main.lean`) and whose hand-written fake is model-test's
(`ModelTest/Editor/Test/Fixture/Discover.lean`):

- a fixture is a file named `script` or `<x>-script` in the root or in a
  directory directly under it;
- its expected output is `expected`, or `<x>-expected`, beside it, when that
  file is there;
- its config directory is the first that exists of `<x>-config` beside it,
  `config` beside it, and `<root>/config`; a fixture with none is refused,
  naming its script.

A directory holding no script is skipped. The fixtures come in the order of
their scripts' paths. Pure: the port's monad is the caller's.
-/

namespace Editor.Test.Fixture

/-- The repository's files as discovery reads them, every path from the
repository's root: the port the harness's edge implements over the real
files and model-test fakes by hand. -/
structure Tree (m : Type → Type) where
  /-- The names of the entries of a directory, none for a path that is no
  directory. -/
  entries : String → m (Array String)
  /-- Whether a path is a file. -/
  isFile : String → m Bool
  /-- Whether a path is a directory. -/
  isDirectory : String → m Bool

/-- What a script's name says of its fixture's parts: `""` for `script`,
`x` for `x-script`, and none for a file that is no script. -/
def scriptPrefix? (name : String) : Option String :=
  if name == "script" then some ""
  else
    if name.endsWith "-script" && name.length > "-script".length then
      some (name.dropEnd "-script".length).toString
    else none

/-- The name of a fixture's part `part` for the script's stem `stem`:
`part` for none, `<stem>-part` otherwise. -/
def partName (stem part : String) : String :=
  if stem.isEmpty then part else s!"{stem}-{part}"

variable {m : Type → Type} [Monad m]

/-- The fixture whose script is the file `name` in the directory
`directory`, under the discovery root `root` (the module docs); or why it
is refused. -/
def fixtureAt (tree : Tree m) (root directory name stem : String) : m (Except String Parts) := do
  let script := joinPath directory name
  let expectedPath := joinPath directory (partName stem "expected")
  let expected := if ← tree.isFile expectedPath then some expectedPath else none
  let candidates :=
    (if stem.isEmpty then [] else [joinPath directory (partName stem "config")]) ++
      [joinPath directory "config", joinPath root "config"]
  for config in candidates do
    if ← tree.isDirectory config then
      return .ok { script, config, expected }
  return .error s!"{script}: no config directory: none of {", ".intercalate candidates}"

/-- The scripts among the entries of `directory`, with their prefixes, in
order. -/
def scriptsIn (tree : Tree m) (directory : String) : m (Array (String × String)) := do
  let names := (← tree.entries directory).qsort (· < ·)
  let mut scripts := #[]
  for name in names do
    if let some stem := scriptPrefix? name then
      if ← tree.isFile (joinPath directory name) then
        scripts := scripts.push (name, stem)
  return scripts

/-- The fixtures the discovery root `root` holds (the module docs), in the
order of their scripts' paths; or why one of them is refused. -/
def discover (tree : Tree m) (root : String) : m (Except String (Array Parts)) := do
  let root := trimmed root
  let mut found := #[]
  let mut directories := #[root]
  for name in (← tree.entries root).qsort (· < ·) do
    let directory := joinPath root name
    if ← tree.isDirectory directory then
      directories := directories.push directory
  for directory in directories do
    for (name, stem) in ← scriptsIn tree directory do
      match ← fixtureAt tree root directory name stem with
      | .ok fixture =>
        found := found.push fixture
      | .error reason =>
        return .error reason
  return .ok (found.qsort (·.script < ·.script))

end Editor.Test.Fixture
