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
named commands and settings for a mode (`ProjectCommands`). The compile
mode keeps them in the project's store (`Compile.projectStore`), so every
worktree of that codebase has them and no other project does.

## The rules

- **Offers** (`offers`): each on-mode's commands, in on-mode order (nearest
  root first, then registration order), each mode's in its order, with the
  mode's root. A project's command of a name the contribution already
  gives replaces it in place; one of a new name comes after the
  contribution's. A mode whose contribution is not registered offers
  nothing.
- **Formats in use** (`formatsOf`): each on-mode's contribution's formats,
  in on-mode order, then `Format.general`. A mode whose contribution is not
  registered, as after a reload that dropped it, gives none.

Pinned by `ModelTest.setupChecks`, `ModelTest.registryChecks` and
`ModelTest.compileHookChecks`.
-/

namespace Editor

/-- A project's identity as a plain tree: one named field, the kind's. -/
def Project.Identity.encode : Project.Identity → Value
  | .remote normalised => .record [("remote", .str normalised)]
  | .commonDir path => .record [("commonDir", .str path.toString)]
  | .root path => .record [("root", .str path.toString)]
  | .declared name => .record [("declared", .str name)]

/-- The identity a tree stands for (`Project.Identity.encode`), if it is
one. -/
def Project.Identity.decode? : Value → Option Project.Identity
  | .record [("remote", .str normalised)] => some (.remote normalised)
  | .record [("commonDir", .str path)] => some (.commonDir path)
  | .record [("root", .str path)] => some (.root path)
  | .record [("declared", .str name)] => some (.declared name)
  | _ => none

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

/-- A named command offered in a buffer: its mode, its name, its line and
the mode's root, where it runs. -/
structure Offer where
  /-- The minor mode that gives it. -/
  mode : String
  /-- Its name. -/
  name : String
  /-- Its command line. -/
  line : String
  /-- The mode's root. -/
  root : System.FilePath
  deriving DecidableEq, Repr

/-- `commands` with each of `project`'s in it: one of a name already there
in its place, one of a new name after them ("Offers", in the module
docs). -/
def withProject (commands project : Array NamedCommand) : Array NamedCommand :=
  project.foldl
    (fun (commands : Array NamedCommand) command =>
      if commands.any (·.name == command.name) then
        commands.map fun kept => if kept.name == command.name then command else kept
      else commands.push command)
    commands

/-- The named commands offered for the on-modes `modes`, given the
registered `contributions` and the project's `stored` commands ("Offers",
in the module docs). -/
def offers (contributions : Array Contribution) (stored : Array ProjectCommands)
    (modes : Array Workspace.OnMode) : Array Offer :=
  modes.flatMap fun on =>
    match contributions.find? (·.mode == on.mode) with
    | none => #[]
    | some contribution =>
      let project := (stored.filter (·.mode == on.mode)).flatMap (·.commands)
      (withProject contribution.commands project).map fun command =>
        { mode := on.mode, name := command.name, line := command.line, root := on.root }

/-- The error formats in use for the on-modes `modes` ("Formats in use", in
the module docs). -/
def formatsOf (contributions : Array Contribution) (modes : Array Workspace.OnMode) :
    Array Format :=
  (modes.flatMap fun on =>
        ((contributions.find? (·.mode == on.mode)).map (·.formats)).getD #[]).push
    Format.general

/-- A named command as a tree: its name, then its line. -/
def NamedCommand.encode (command : NamedCommand) : Value :=
  .list [.str command.name, .str command.line]

/-- The named command a tree stands for (`NamedCommand.encode`), if it is
one. -/
def NamedCommand.decode? : Value → Option NamedCommand
  | .list [.str name, .str line] => some { name, line }
  | _ => none

/-- A project's commands as a tree. -/
def ProjectCommands.encode (entry : ProjectCommands) : Value :=
  .record
    [("project", entry.project.encode), ("mode", .str entry.mode),
      ("commands", .list (entry.commands.toList.map NamedCommand.encode)),
      ("settings", .record entry.settings)]

/-- The project's commands a tree stands for (`ProjectCommands.encode`), if
it is them. -/
def ProjectCommands.decode? : Value → Option ProjectCommands
  |
  .record
      [("project", project), ("mode", .str mode), ("commands", .list commands),
        ("settings", .record settings)] =>
    do
    let project ← Project.Identity.decode? project
    let commands ← commands.toArray.mapM NamedCommand.decode?
    return { project, mode, commands, settings }
  | _ => none

end Compile

end Editor
