import Editor.Extension
import Editor.ProjectMode.Format
import Editor.Workspace

/-!
# Project modes: what a minor mode contributes for a kind of project

What makes the editor fit a kind of project, as data a minor mode
registers (`docs/design/keymaps-and-modes.md`, "The compile mode, as
built"): a contribution. The values are plain data, so that config can name
and build them, and they are registered at two extension points
(`Editor/Extension.lean`) with `compileContribution` and `projectCommands`,
below.

## Two extension points, and their reader

`Contribution` and `ProjectCommands` derive `TypeName`: each is an
extension point, a hook. The core's setup port has no request of the
compile mode and its registry holds no contribution: both travel as any
extension point's values do, kept by owner, so a reload replaces config's
and keeps a package's.

- `compileContribution` registers a contribution (`Extension.add`), after
  refusing one with no marker or one that names a command twice.
- `projectCommands` registers one project's commands and settings for a
  mode, after refusing ones that name a command twice. A package may give
  them as config does.
- `Compile.hook` reads both ("The hook's order", below). The compile mode
  (`packages/compile/`), the listing (`Editor/ProjectMode/Listing.lean`)
  and the workspace's modes on markers (`Workspace.markerSettings`, there)
  read it, and none of them reads the points themselves.

The declarations keep their full names (`Editor.Compile.Contribution`,
`Editor.Compile.NamedCommand`, `Editor.Compile.ProjectCommands`,
`Editor.Compile.Hook`, `Editor.compileContribution`,
`Editor.projectCommands`): config, the docs and the tests name them, and a
move changes only `import` lines.

## The hook's order

`Extension.values` holds the packages' values and then config's. The hook
ranks config's first (`Hook.ranked`), which is why it asks for config's
apart (`Extension.configValues`):

- **Contributions**: config's in the order its `setup` registered them,
  then the packages' whose modes config does not give. Each mode is there
  once, at the place it was first registered, as its latest registration:
  so config's contribution of a package's one's name replaces it whole,
  markers, commands and formats, in config's place, until a reload drops
  it; of two packages that contribute one mode the later package's is the
  one used, where the first one's was; and of two contributions of one
  mode in one `setup` the later is used.
- **Project commands**: config's, then the packages', each project and
  mode once among config's and once among the packages', as its latest
  there. What reads a project's settings takes the first entry for the
  project and the mode (`Hook.settingsOf`), so config's are used before a
  package's.

The order is visible: at one root, on-modes are in the hook's order
(`Workspace.onModes`), and the first on-mode's first command is `compile`'s
default.

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

Config, or a package, can give one project (by its identity,
`Project.Identity`) its own named commands and settings for a mode
(`ProjectCommands`). They have one source, the hook (`Hook.projects`),
which holds what is registered now; a project's are read from it by its
identity (`Hook.projectsOf`, `Hook.settingsOf`), so every worktree of that
codebase has them, no other project does, and a reload's change is read at
once.

Pinned by `ModelTest.contributionChecks`: on values, and on the kit's
hosted registry (`Editor/Test/Hosted.lean`) with packages and a config that
register through the two operations. What the compile mode makes of a
contribution is its own tests', in its package
(`CompileTest.compileHookChecks`, `CompileTest.compileOfferChecks`).
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
  deriving TypeName

/-- The contribution's mode, markers and root rule, as the marker search is
handed them. -/
def Contribution.markerMode (contribution : Contribution) : Workspace.MarkerMode :=
  { mode := contribution.mode, markers := contribution.markers,
    outermost := contribution.outermost }

/-- What config, or a package, gives one project for one mode ("Project
commands", in the module docs). -/
structure ProjectCommands where
  /-- The project, by its identity. -/
  project : Project.Identity
  /-- The minor mode. -/
  mode : String
  /-- Its named commands for the mode, in order. -/
  commands : Array NamedCommand := #[]
  /-- Its settings for the mode, by name. -/
  settings : List (String × Value) := []
  deriving BEq, Repr, TypeName

/-- What is registered at the two points, as their readers take it ("The
hook's order", in the module docs): the contributions, each mode once, and
the project commands. -/
structure Hook where
  /-- The contributions, in the hook's order. -/
  contributions : Array Contribution := #[]
  /-- The project commands, config's first. -/
  projects : Array ProjectCommands := #[]

/-- `entries` with each key, as `key` reads it, once: at the place it was
first among them, as the latest entry of that key. -/
def latestBy {α κ : Type} [BEq κ] (key : α → κ) (entries : Array α) : Array α :=
  let keys :=
    entries.foldl
      (fun (keys : Array κ) entry =>
        if keys.contains (key entry) then keys else keys.push (key entry))
      #[]
  keys.filterMap fun wanted => entries.findRev? (key · == wanted)

/-- The hook of config's contributions `config` and the packages'
`packages`, and of config's project commands `configProjects` and the
packages' `packageProjects`, each in registration order ("The hook's
order", in the module docs). -/
def Hook.ranked (config packages : Array Contribution)
    (configProjects packageProjects : Array ProjectCommands) : Hook :=
  let config := latestBy (·.mode) config
  let entry (commands : ProjectCommands) := (commands.project, commands.mode)
  { contributions :=
      config ++
        (latestBy (·.mode) packages).filter fun contribution =>
          !config.any (·.mode == contribution.mode)
    projects := latestBy entry configProjects ++ latestBy entry packageProjects }

/-- The hook: what is registered at the two points now ("The hook's order",
in the module docs). Run bare, where no loop dispatched the command, it is
empty. -/
def hook : EditorM Hook := do
  let contributions ← Extension.values Contribution
  let config ← Extension.configValues Contribution
  let projects ← Extension.values ProjectCommands
  let configProjects ← Extension.configValues ProjectCommands
  return Hook.ranked config (contributions.extract 0 (contributions.size - config.size))
      configProjects (projects.extract 0 (projects.size - configProjects.size))

/-- The project commands for the project of `identity`, in the hook's
order ("Project commands", in the module docs). -/
def Hook.projectsOf (hook : Hook) (identity : Project.Identity) : Array ProjectCommands :=
  hook.projects.filter (·.project == identity)

/-- The settings the project of `identity` is given for the mode `mode`,
those of the hook's first entry for both; none when it is given none
("Project commands", in the module docs). -/
def Hook.settingsOf (hook : Hook) (identity : Project.Identity) (mode : String) :
    List (String × Value) :=
  (((hook.projectsOf identity).find? (·.mode == mode)).map (·.settings)).getD []

/-- What a compile contribution of `mode` that names the command `name`
twice is refused with. -/
def contributionCommandTwice (mode name : String) : String :=
  s!"the compile contribution `{mode}` names the command `{name}` twice"

/-- What project commands of `mode` for the project `project` that name the
command `name` twice are refused with. -/
def projectCommandTwice (mode : String) (project : Project.Identity) (name : String) : String :=
  s!"the project commands of `{mode}` for {project.describe} name the command `{name}` twice"

/-- The first of `names` that an earlier one already is, if any. -/
def repeatedName? (names : Array String) : Option String := do
  for index in [0:names.size] do
    if let some name := names[index]? then
      if (names.extract 0 index).contains name then
        return name
  none

end Compile

/-- The message a compile contribution with no marker is refused with. -/
def compileWithoutMarkers (mode : String) : String :=
  s!"the compile contribution `{mode}` has no marker"

/-- Registers `contribution`, what the minor mode `contribution.mode` gives
the compile mode, at the extension point `Compile.Contribution`: its
markers, which turn the mode on in a buffer whose file is under one of them
inside its workspace, its named commands and its error formats. Config's
contribution of a mode's name replaces a package's of that name whole, and
of two of one mode in one `setup` the later is used ("The hook's order", in
the module docs). Refuses the `setup` for a contribution with no marker, or
one that names a command twice. -/
def compileContribution (contribution : Compile.Contribution) : SetupM Unit := do
  if contribution.markers.isEmpty then
    throw (compileWithoutMarkers contribution.mode)
  if let some name := Compile.repeatedName? (contribution.commands.map (·.name)) then
    throw (Compile.contributionCommandTwice contribution.mode name)
  Extension.add contribution

/-- Gives the project identified by `project` its own `commands`, each a name
and a command line, and `settings` for the minor mode `mode`, at the
extension point `Compile.ProjectCommands`: the compile mode reads them by
that project's identity from the hook, so every worktree of the codebase
has them while the mode is on there, and no other project does. A command
of a name the mode's contribution gives replaces it; one of a new name comes
after the contribution's. Given twice for one project and mode in one
`setup`, the later is used. Refuses the `setup` for project commands that
name a command twice. -/
def projectCommands (project : Project.Identity) (mode : String) (commands : List (String × String))
    (settings : List (String × Value) := []) : SetupM Unit := do
  if let some name := Compile.repeatedName? (commands.toArray.map (·.1)) then
    throw (Compile.projectCommandTwice mode project name)
  Extension.add
      ({  project, mode, settings
          commands := commands.toArray.map fun (name, line) => { name, line } } :
        Compile.ProjectCommands)

end Editor
