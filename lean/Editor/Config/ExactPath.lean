/-!
# A path found exactly, whatever the file system makes of case

On a file system that ignores case, macOS's default, a path spelt in
another case opens the same file: `Config/keys.lean` is there when
`Config/Keys.lean` is. A module's name is exact about case, so the config
session's adapters do not ask whether a path exists
(`Editor/Config/Session.lean`, `Lookup`). They ask this module, which
finds a path below a directory one component at a time, by listing each
directory and requiring an entry whose name is the component byte for
byte. It answers the same on a file system that ignores case and on one
that does not.

When a component is not there and an entry is that differs from it only in
the case of its ASCII letters, the walk goes on through that entry and
answers the path as the directory spells it, so that a diagnostic can name
the file found and the spelling to use. Letters outside ASCII are not
folded: a name that differs in the case of one of those is not found at
all, which is still exact.

It lists a directory for each component, where a test of existence is one
call. The config session asks it once for the root and once for each
import of a config file in a reload, and for a module of the toolchain
only while the base does not hold it (`docs/design/lean-runtime.md`,
"Config and reload", has the measured cost).

`config-test` pins it through the two adapters
(`ConfigTest.directoryChecks`, `ConfigTest.elaboratorChecks`).
-/

namespace Editor.Config.ExactPath

/-- What a walk found. -/
inductive Found where
  /-- Every component is there, spelt as it was asked for. -/
  | exact
  /-- A component is not there as it was asked for, and the path is there
  with these components, which differ from the ones asked for only in the
  case of their letters. -/
  | spelled (components : List String)
  /-- The path is not there under any spelling. -/
  | absent
  deriving DecidableEq, Repr

/-- `name` with each of its ASCII letters small. -/
def folded (name : String) : String :=
  name.map Char.toLower

/-- The entry of `directory` for `component`: the component itself when an
entry has exactly that name, or else an entry whose name differs from it
only in case; none when there is neither, and when `directory` cannot be
listed. -/
def entry? (directory : System.FilePath) (component : String) : IO (Option String) := do
  let entries ←
    try
      directory.readDir
    catch _ =>
      return none
  let names := entries.map (·.fileName)
  if names.contains component then
    return some component
  return names.find? (folded · == folded component)

/-- Finds the path `components` below `directory`, one component at a
time (the module docs give the rule). -/
def find (directory : System.FilePath) (components : List String) : IO Found := do
  let mut current := directory
  let mut spelling := #[]
  for component in components do
    let some entry ← entry? current component | return .absent
    spelling := spelling.push entry
    current := current / entry
  return if spelling.toList == components then .exact else .spelled spelling.toList

end Editor.Config.ExactPath
