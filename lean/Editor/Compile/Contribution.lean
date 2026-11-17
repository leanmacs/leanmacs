import Editor.Compile.Errors
import Editor.Workspace

/-!
# Compile contributions: what a minor mode gives the compile mode

What makes the compile mode (`Editor/Compile.lean`) fit a kind of project,
as data a minor mode registers (`docs/design/keymaps-and-modes.md`, "The
compile mode, as built"). Pure, with no editor API, so that config can
name and build it (`compileContribution` and `projectCommands`,
`Editor/Setup.lean`).

## A contribution

A contribution (`Contribution`) is registered under its minor mode's name
(`mode`): the names of its marker files (`markers`), which turn the mode on
in a buffer whose file is under one of them inside its workspace
(`Editor/Workspace.lean`, "Modes on markers"); its named commands
(`commands`, each a name such as `build` and a command line); and its error
formats (`formats`, `Editor/Compile/Errors.lean`). Registering a `Mode`
record of the same name is optional: a buffer's minor modes are by name.
A field a later phase needs, such as a command computed from the project,
is added with a default, so every contribution written now stays valid.

## Project commands

Config can give one project (by its identity, `Project.Identity`) its own
named commands and settings for a mode (`ProjectCommands`), so every
worktree of that codebase has them and no other project does.

Pinned by `ModelTest.setupChecks` and `ModelTest.registryChecks`.
-/

namespace Editor

namespace Compile

/-- A named command a minor mode gives: a name, such as `build`, and the
command line it runs. -/
structure NamedCommand where
  /-- Its name. -/
  name : String
  /-- The command line, as `/bin/sh -c` is handed it. -/
  line : String
  deriving BEq, Repr

/-- What a minor mode gives the compile mode ("A contribution", in the
module docs). -/
structure Contribution where
  /-- The minor mode's name, which is the contribution's. -/
  mode : String
  /-- The names of its marker files. -/
  markers : Array String
  /-- Its named commands, in order: the first is `compile`'s default. -/
  commands : Array NamedCommand := #[]
  /-- Its error formats, in the order they are tried. -/
  formats : Array Format := #[]

/-- The contribution's mode and markers, as the marker search is handed
them. -/
def Contribution.markerMode (contribution : Contribution) : Workspace.MarkerMode :=
  { mode := contribution.mode, markers := contribution.markers }

/-- What config gives one project for one mode ("Project commands", in the
module docs). -/
structure ProjectCommands where
  /-- The project, by its identity. -/
  project : Project.Identity
  /-- The minor mode. -/
  mode : String
  /-- Its named commands for the mode, in order. -/
  commands : Array NamedCommand := #[]
  /-- Its settings for the mode, by name. -/
  settings : List (String × Value) := []
  deriving BEq, Repr

/-- What the loop is told of the registered contributions: the
contributions in registration order (`Registry.compileContributions`), and
config's project commands. -/
structure Hook where
  /-- The contributions, in registration order. -/
  contributions : Array Contribution := #[]
  /-- Config's project commands, in the order config gave them. -/
  projects : Array ProjectCommands := #[]

end Compile

end Editor
