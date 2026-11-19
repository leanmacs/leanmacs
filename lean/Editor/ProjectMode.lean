import Editor.ProjectMode.Format
import Editor.Workspace

/-!
# Project modes: what a minor mode contributes for a kind of project

What makes the editor fit a kind of project, as data a minor mode
registers (`docs/design/keymaps-and-modes.md`, "The compile mode, as
built"): a contribution. Pure, with no editor API, so that config can name
and build it (`compileContribution` and `projectCommands`,
`Editor/Setup.lean`).

## Why this is a core module that declares names in `Editor.Compile`

The setup port registers contributions (`Editor/Setup.lean`), the registry
holds them by owner (`Editor/Config/Registry.lean`, "Compile
contributions"), the loop is told them (`Hook`, `Loop.Registered.compile`),
and the workspace turns a contribution's minor mode on from its markers
(`Editor/Workspace/Modes.lean`). So the vocabulary is the core's, and the
compile mode, which is not a core module (`docs/design/packages.md`), is
one reader of it: what it makes of contributions is in
`Editor/Compile/Contribution.lean`. The declarations were moved here from
that module and keep their full names (`Editor.Compile.Contribution`,
`Editor.Compile.NamedCommand`, `Editor.Compile.ProjectCommands`,
`Editor.Compile.Hook`): config, the docs and the tests name them, and a
move changes only `import` lines.

## A contribution

A contribution (`Contribution`) is registered under its minor mode's name
(`mode`): the names of its marker files (`markers`), which turn the mode on
in a buffer whose file is under one of them inside its workspace
(`Editor/Workspace.lean`, "Modes on markers"); its named commands
(`commands`, each a name such as `build` and a command line); its error
formats (`formats`, `Editor/ProjectMode/Format.lean`); and whether its root
is its outermost marker in the workspace rather than its nearest
(`outermost`). Registering a `Mode`
record of the same name is optional: a buffer's minor modes are by name.
A contribution's commands may also be computed (`listing`, "Computed
commands"). A field a later phase needs is added with a default, so every
contribution written before stays valid.

## Computed commands

A contribution's `listing` is a program, run in the mode's root, whose
standard output its `read` turns into named commands, as `mise-mode` reads
`mise tasks ls --json`. When it runs, where what it gave is kept and how a
failure is said are `Editor/ProjectMode/Listing.lean`'s. A named command may
carry the directory it runs in (`NamedCommand.directory`), resolved
against its mode's root, as a mise task runs in its own `dir`.

## Project commands

Config can give one project (by its identity, `Project.Identity`) its own
named commands and settings for a mode (`ProjectCommands`). They have one
source, the hook the loop is told (`Hook.projects`), which holds config's
latest; a project's are read from it by its identity (`Hook.projectsOf`,
`Hook.settingsOf`), so every worktree of that codebase has them, no other
project does, and a reload's change is read at once.

Pinned by `ModelTest.setupChecks`, `ModelTest.registryChecks` and
`ModelTest.compileHookChecks`.
-/

namespace Editor

namespace Compile

/-- A named command a minor mode gives: a name, such as `build`, the command
line it runs, and where it runs when that is not its mode's root. -/
structure NamedCommand where
  /-- Its name. -/
  name : String
  /-- The command line, as `/bin/sh -c` is handed it. -/
  line : String
  /-- Where it runs, resolved against its mode's root; none for the root. -/
  directory : Option System.FilePath := none
  deriving BEq, Repr

/-- How a contribution's commands are also computed ("Computed commands",
in the module docs): `program arguments…`, run in the mode's root, whose
standard output `read` turns into named commands. -/
structure Listing where
  /-- The program, a bare name looked up on the child's `PATH`, or an
  absolute path. -/
  program : String
  /-- Its arguments. -/
  arguments : Array String := #[]
  /-- What its standard output gives, or why it gives nothing. -/
  read : ByteArray → Except String (Array NamedCommand)

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
  /-- Whether its root is its outermost marker in the workspace, not its
  nearest (`Editor/Workspace.lean`, "Modes on markers"). -/
  outermost : Bool := false
  /-- How its commands are also computed, if they are ("Computed commands",
  in the module docs). -/
  listing : Option Listing := none

/-- The contribution's mode, markers and root rule, as the marker search is
handed them. -/
def Contribution.markerMode (contribution : Contribution) : Workspace.MarkerMode :=
  { mode := contribution.mode, markers := contribution.markers,
    outermost := contribution.outermost }

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

/-- Config's project commands for the project of `identity`, in the order
config gave them ("Project commands", in the module docs). -/
def Hook.projectsOf (hook : Hook) (identity : Project.Identity) : Array ProjectCommands :=
  hook.projects.filter (·.project == identity)

/-- The settings config gives the project of `identity` for the mode
`mode`; none when it gives none ("Project commands", in the module
docs). -/
def Hook.settingsOf (hook : Hook) (identity : Project.Identity) (mode : String) :
    List (String × Value) :=
  (((hook.projectsOf identity).find? (·.mode == mode)).map (·.settings)).getD []

end Compile

end Editor
