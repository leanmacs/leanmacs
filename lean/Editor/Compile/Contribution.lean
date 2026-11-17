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
(`commands`, each a name such as `build` and a command line); its error
formats (`formats`, `Editor/Compile/Errors.lean`); and whether its root is
its outermost marker in the workspace rather than its nearest
(`outermost`). Registering a `Mode`
record of the same name is optional: a buffer's minor modes are by name.
A contribution's commands may also be computed (`listing`, "Computed
commands"). A field a later phase needs is added with a default, so every
contribution written before stays valid.

## Computed commands

A contribution's `listing` is a program, run in the mode's root, whose
standard output its `read` turns into named commands, as `mise-mode` reads
`mise tasks ls --json`. When it runs, where what it gave is kept and how a
failure is said are `Editor/Compile/Listing.lean`'s. A named command may
carry the directory it runs in (`NamedCommand.directory`), resolved
against its mode's root, as a mise task runs in its own `dir`.

## Project commands

Config can give one project (by its identity, `Project.Identity`) its own
named commands and settings for a mode (`ProjectCommands`). They have one
source, the hook the loop is told (`Hook.projects`), which holds config's
latest; a project's are read from it by its identity (`Hook.projectsOf`,
`Hook.settingsOf`), so every worktree of that codebase has them, no other
project does, and a reload's change is read at once.

## The rules

- **Offers** (`offers`): each on-mode's commands, in on-mode order (nearest
  root first, then registration order), each mode's in its order. A
  command its listing gave at the mode's root of a name the contribution
  already gives replaces it in place; one of a new name comes after the
  contribution's. A project's command of a name already there replaces it
  in place; one of a new name comes after them. An offer runs in its
  command's directory resolved against the mode's root (`resolve`, so an
  absolute one is kept), else in the mode's root. A mode whose contribution is not registered offers
  nothing. An offer is shown as `<name> (<mode>)` (`Offer.candidate`).
- **Choosing** (`chooseOffer`): an answer, trimmed, matches an offer's
  candidate whole first, then a bare command name, the first offer of that
  name.
- **Formats in use** (`formatsOf`): each on-mode's contribution's formats,
  in on-mode order, then `Format.general`. A mode whose contribution is not
  registered, as after a reload that dropped it, gives none.

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

/-- How an offer is shown among a prompt's candidates: `<name> (<mode>)`. -/
def Offer.candidate (offer : Offer) : String :=
  s!"{offer.name} ({offer.mode})"

/-- The offer `answer` chooses ("Choosing", in the module docs): the one
whose candidate it is, else the first of its name; none for any other. -/
def chooseOffer (offers : Array Offer) (answer : String) : Option Offer :=
  let answer := answer.trimAscii.toString
  (offers.find? (·.candidate == answer)).orElse fun _ => offers.find? (·.name == answer)

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
registered `contributions`, the project's commands `projects` and the
commands each mode's listing gave at a root, `listed` ("Offers", in the
module docs). -/
def offers (contributions : Array Contribution) (projects : Array ProjectCommands)
    (modes : Array Workspace.OnMode)
    (listed : String → System.FilePath → Array NamedCommand := fun _ _ => #[]) : Array Offer :=
  modes.flatMap fun on =>
    match contributions.find? (·.mode == on.mode) with
    | none => #[]
    | some contribution =>
      let project := (projects.filter (·.mode == on.mode)).flatMap (·.commands)
      (withProject (withProject contribution.commands (listed on.mode on.root)) project).map
        fun command =>
        { mode := on.mode, name := command.name, line := command.line
          root :=
            (command.directory.map fun directory => resolve on.root directory.toString).getD
              on.root }

/-- The error formats in use for the on-modes `modes` ("Formats in use", in
the module docs). -/
def formatsOf (contributions : Array Contribution) (modes : Array Workspace.OnMode) :
    Array Format :=
  (modes.flatMap fun on =>
        ((contributions.find? (·.mode == on.mode)).map (·.formats)).getD #[]).push
    Format.general

end Compile

end Editor
