import Editor.Api
import Editor.Command.Call
import Editor.Compile.Contribution
import Editor.Compile.Errors
import Editor.File
import Editor.Mode
import Editor.ProjectMode
import Editor.ProjectMode.Format
import Editor.ProjectMode.Listing
import Editor.Shell
import Editor.Workspace.Modes

/-!
# The compile mode: `compile` into a workspace's compilation buffer

Emacs's `M-x compile`, one per workspace: a build or a test command runs as
`/bin/sh -c <line>`, and its output arrives in the workspace's compilation
buffer while editing goes on (`docs/design/keymaps-and-modes.md`, "The
compile mode, as built"; `docs/design/projects.md`). Written over the
editor API (`Editor/Api.lean`) and the job port (`Editor/Job.lean`). A
command may not wait and a job may, so a compile is the command `compile`,
which starts the job `compile-run`; the job, which runs the child and posts
its output as it comes (`post`); and the commands the posts and the job's
end run. The commands, the job and the mode as compiled code registers them
are in `Editor/Compile/Compiled.lean`.

## The scope

A compile belongs to the focused buffer's **scope** (`Scope`): its
workspace and project; for a buffer with no workspace, the directory its
`compile-directory` local names, which a directory's compilation buffer has;
else its file's directory; else the editor's working directory
(`EditorState.workingDirectory`). So a buffer with no workspace uses its
file's directory as a workspace of its own, and in a compilation buffer the
commands act on its own scope. A scope's label is its workspace's
(`Workspace.label`), or its directory's last component; its place (`Place`)
is what crosses as job arguments and keys its state and its job
(`Place.jobKey`: `compile <location>` or `compile directory <path>`), so
compiles in two workspaces run at once and never touch each other.

Each scope keeps a `Record`: the number of its compilation buffer, found by
it and never by its name; the last line it ran and the directory it ran in;
how many runs it has started; the run in flight, with its line and the
clock's reading when it started (`Watch.now`); the locations its last run's
output gave ("Locations"); the current location ("Stepping"); and the
on-modes its last run started with ("The hook"). A workspace's is in its
store (`store`), a directory's in the unscoped store, by directory
(`directoryStore`), so each workspace has its own error list and current
location. Both stores are at version 3, the version that added the run's
modes; they live for the session. Each post decodes and re-encodes
the record with every location so far: fine for hundreds of locations, and
revisited if a measured build says otherwise. The lines compiled are a history, newest first, each
once (`Shell.remember`): the project's (`historyStore`), so every worktree of
a codebase offers the same lines, or for a directory scope the unscoped
store's, which every directory shares. A line is recorded when its run
starts.

## The commands

- **`compile`** (`compileName`): a location that cannot run commands
  (`Location.can`) refuses before anything is asked or started. With no
  line, or an empty one, it prompts, `Compile command: `, with the scope's
  last line as its text, or with none the first command the buffer's
  on-modes offer ("The hook"), and the scope's history as its candidates,
  and the answer comes back to it; an empty answer says `compile: no
  command`. With a line it starts the run ("The run"), in the first
  on-mode's root, or the scope's root with none.
- **`compile-command`** (`commandName`): the same location refusal; then,
  with no command any on-mode offers, it says `compile-command: no mode
  gives commands in <label>` and asks nothing. With no answer it prompts,
  `Mode command: `, empty, with the offers as candidates, `<name> (<mode>)`,
  in on-mode order ("The hook"). The answer chooses an offer, its whole
  candidate first, then a bare name (`chooseOffer`), whose line runs in its
  mode's root with no second prompt, through the same restart rule; an
  answer that chooses none says `compile-command: no command <answer> in
  <label>`, and an empty one `compile-command: no command`. No key binds
  it; it is a command and an ex name.
- **`recompile`** (`recompileName`): the same location refusal; then the
  scope's last line, in the directory it ran in, with no prompt; with none
  it says `recompile: nothing has been compiled in <label>`.
- **A restart asks first.** When the scope's own run is in flight, `compile`
  and `recompile` open a prompt, `Kill the compilation running in <label>?
  (y or n) `, whose continuation, `compile-confirm` (`confirmName`), starts
  the run on `y` or `yes`, in any case, which cancels the old job through
  its key and empties the buffer; any other answer says `<command>: left
  the compilation running in <label>`, and a cancelled prompt runs
  nothing.
- **`kill-compilation`** (`killName`): with the scope's run in flight, its
  job is cancelled by its key, which kills the child with its process
  group, the run is cleared, and `Compilation killed after <elapsed>` is
  appended and said with the label; with none, it says so.

## The run

A start (`start`) runs the line in the directory it is handed: the first
on-mode's root, or the workspace's root, or the scope's directory; a start
that is refused is said, `compile: <refusal>`. Then the
scope's record keeps the run, and the compilation buffer is made, or its
text replaced by the header line:

- **The buffer** is the scope's kept buffer while its number still names a
  buffer; otherwise one is made, read-only (`BufferId.setReadOnly`), with
  the scope's workspace or its `compile-directory` local, named
  `*compilation: <label>*`, or, when that is taken, `*compilation: <label>
  (<parent>)*` with the last component of the root's parent directory, then
  the first free name of that (`EditorState.freeName`).
- **The header line** is `<label> in <directory>: <line>`.
- **Its mode**: a made buffer is given the major mode `compilation`
  (`BufferId.setMajorMode`) before it is shown, so a display rule can
  match the mode.
- **Shown** where config's display rules say, for the opener `compile` or
  `recompile` (whichever asked), asked from the asking view
  (`BufferId.display`, `Editor/DisplayRules.lean`): a window that shows it
  already is reused, so a recompile while it is open opens nothing; with
  no rule that matches, it opens in a new window at the end of the tiled
  list, the stack, and the focus stays where the user is editing, since
  compile passes `false` as the fallback's focus. A rule that matches
  keeps its own focus (decided 2026-11-17).

The job (`runWork`) starts the child as a streaming one, lines on both
streams, under `lineBound` a line, its input closed, and reads it: each
delivery's lines, standard output's then standard error's, decoded by the
store's escape rule (`File.decodeBytes`) with one trailing `\r` dropped, are
posted to `compilation-output` (`outputName`) while the child runs, with a
pause of `batchPause` after each, so a fast child is posted at most twenty
times a second and its output batches meanwhile. The delivery that ends the
child, a refused start and a refused read finish the job with `finished`.

**Following.** Before lines are appended, each view showing the buffer
whose cursor is on its last line, or on the empty row after it (its row is
at least the text's lines less one, `TextId.lineCount`), follows; after,
each follower's cursor is put at the start of the new last line, its shape
kept, and the loop's cursor-follow scrolls it into view. A view whose
cursor was moved up is left where it is. A restart puts every view's cursor
on the header line, so all follow.

`compilation-output` and `finished` act only while the scope's run in
flight is theirs, so a killed or replaced run's late output is dropped.
Each appends its lines to the kept buffer inside `BufferId.writing`, each
ended with a line feed, and finds the locations in them ("Locations").
`finished` then appends the last line, `Compilation <how> after <elapsed>`
(`lastLine`), clears the run and says `<label>: <last line>` in the echo
area. A compilation buffer closed while its run ran gets no output; the end
is still said.

## Locations

The error formats (`Editor/ProjectMode/Format.lean`), read by the matcher
(`Editor/Compile/Errors.lean`), find the locations of a
run's output as its lines arrive, not at its end: `compilation-output` and
`finished` scan the lines they have just appended (`noteSites`, `scan`),
from the row and byte offset where they start (`append`'s answer), with the
text of the row before them when it is output, so a lead line that came in
an earlier post is seen, and keep the locations in the scope's record. The header line and the last line are
never scanned, and a run whose compilation buffer was closed finds none.

- **The formats** a run's output is read with are its on-modes'
  contributions' formats, in on-mode order, then the general format
  (`formatsOf`, `Editor/Compile/Contribution.lean`): so a line two formats
  read is the nearest mode's location.
- **A relative file** resolves against the directory the run ran in (the
  record's last directory, which `start` set for this run), lexically
  (`resolve`). Make's `Entering directory` lines are not tracked.
- **Faces.** Each new location's text, from its file through its line or
  column, is a span of the compilation buffer (`Buffer.spans`) in its
  severity's face (`Severity.face`): `compilation.error`,
  `compilation.warning` or `compilation.note`. A joined continuation line
  gets none. The loop draws the spans under the last search's matches
  (`Editor/Loop.lean`, "Decorations").
- **A rerun resets them.** `start` writes the scope's record with no
  locations and no current one, and `prepare` empties the kept buffer's
  spans with its text. Only that scope's record is written, so a rerun in
  one workspace leaves every other workspace's list as it was.

## Stepping

Each scope's list has a current location (`Record.current`), none at
first. Three commands visit a location and make it the current one:

- **The list** is the focused buffer's scope's (`Scope.of`), so in a buffer
  of another worktree, project or directory it is that one's list, and in
  a compilation buffer its own scope's.
- **`next-error`** (`nextName`) visits the first location from none, else
  the one after the current; **`previous-error`** (`previousName`) the one
  before the current, and stops from none as from the first. A step past
  either end changes nothing and says `next-error: no more locations in
  <label>` or `previous-error: no earlier locations in <label>`; an empty
  list says `<name>: no locations in <label>` (`stepCommand`).
- **`compile-goto-error`** (`gotoName`), in the scope's kept compilation
  buffer, visits the location whose rows hold the row of the window's
  cursor; on a row no location covers it says `compile-goto-error: no
  location on this line`, and in a buffer that is not its scope's
  compilation buffer `compile-goto-error: <name> is not a compilation
  buffer` (`gotoCommand`).
- **A visit** (`visitLocation`) makes the location current, puts the
  cursor of every view of the kept compilation buffer at the start of the
  location's first row, and visits its file (`Files.visit`) at its line
  and column, both as printed: row `line - 1` and the column less the
  format's column base, in characters, or the row's start with no column.
  The visiting view (`visitingView`) is the asking view, unless that shows
  the scope's compilation buffer: then the first other view that is not
  the minibuffer's, else a new view split from the asking one, placed as
  the layout places a split, else the asking view.
- **Focus.** `compile-goto-error` focuses the visiting view, as Emacs's
  `RET`; `next-error` and `previous-error` asked from a compilation buffer
  (by the ex line) keep the focus there, as Emacs's
  `next-error-no-select`; asked from any other view, the visiting view is
  that view.
- **Only these three change the current location.** Moving the
  compilation buffer's cursor by hand changes nothing; a visit moves that
  cursor, so a view of it that followed stops following.
- **A file that is not there** is said by Files (`Files.notOpened`): the
  location is current and the compilation buffer's cursor on it, and no
  buffer is made, no other cursor moves and the focus stays.

## The hook

Minor modes give the compile mode what fits a kind of project
(`Compile.Contribution`, `Editor/ProjectMode.lean`). A buffer's
on-modes (`Workspace.onModesOf`, `Editor/Workspace/Modes.lean`), nearest
root first, then in registration order, decide where a run goes, what
`compile` offers and how the output is read. The contributions are asked of
the loop (`RegistryRequest.compileHook`), so a reload's change holds from the
next command.

- **Where.** With on-modes, `compile` runs its line, typed or default, in
  the first on-mode's root; with none, in the scope's root.
- **The default.** `compile`'s prompt holds the scope's last line when it
  has one, as projectile keeps the last command per project; else the
  first command the on-modes offer (`offers`); else nothing. Its
  candidates stay the scope's history.
- **The run's modes.** A run keeps its on-modes in the scope's record
  (`Record.modes`), so `recompile`, the restart prompt (whose continuation
  carries them) and the scan of its output use the modes it started with.
  In the scope's own compilation buffer, which has no file and so no
  on-modes of its own, `compile` uses the record's (`modesOf`).
- **Named commands.** `compile-command` offers every on-mode's commands
  (`offers`) and runs the chosen one's line in its mode's root, or in the
  directory the command names.
- **Computed commands.** A use, `compile`'s prompt and every path of
  `compile-command`, first checks the on-modes' listings in the scope's
  place (`refreshScope`, `Editor/ProjectMode/Listing.lean`), which reruns a
  listing whose markers' stamps changed, or after a reload; that use
  offers what was last listed, and a new list is offered from the use after
  the check's job's command arrives. The commands listed are offered with
  the contribution's own (`listedCommands`, `offers`).
- **Formats.** A run's output is read with its modes' formats, then the
  general one ("Locations").
- **Project commands.** Config's project commands (`projectCommands`,
  `Editor/Setup.lean`) have one source: the hook the loop answers, which
  holds config's latest, keyed by the project's identity. `compile` and
  `compile-command` take the scope's project's from it (`hookOffers`), and
  `projectSettings` reads a mode's settings from it, so a reload's change
  holds at the next read in any open buffer, with or without a compile
  first, and every worktree of the project reads the same. Nothing copies
  them into a store. They are offered only while their mode is on. A
  directory scope has no project, and no project commands.

## The mode

`compilation` (`mode`), whose buffer is read-only to editing commands
(`Editor/Command/Dispatch.lean`, "Read-only buffers"). It fills two roles:
`refresh` with `recompile` and `activate` with `compile-goto-error`. It
leaves `next-item` and `previous-item` unfilled: under the Vim scheme those
are `j` and `k`, which stay motions in a compilation buffer, so
`next-error` and `previous-error` are commands and ex names only, and no
global key binds them.

Pinned by `ModelTest.compileChecks`, `ModelTest.compileErrorChecks`,
`ModelTest.compileLocationChecks` and `ModelTest.compileHookChecks`, on the
loop's driver over the editor's models, the job model and the process
model, and over the real process service by `ContractTest.compileChecks`.
-/

namespace Editor.Compile

/-- The name the command that compiles is registered under. -/
def compileName : String :=
  "compile"

/-- The name the command that reruns the scope's last line is registered
under. -/
def recompileName : String :=
  "recompile"

/-- The name the continuation of the prompt that asks before a restart is
registered under. -/
def confirmName : String :=
  "compile-confirm"

/-- The name the command that runs one of the on-modes' named commands is
registered under. -/
def commandName : String :=
  "compile-command"

/-- The name the command that kills the scope's compilation is registered
under. -/
def killName : String :=
  "kill-compilation"

/-- The name the command that visits the next location is registered
under. -/
def nextName : String :=
  "next-error"

/-- The name the command that visits the previous location is registered
under. -/
def previousName : String :=
  "previous-error"

/-- The name the command that visits the location on the cursor's line of a
compilation buffer is registered under. -/
def gotoName : String :=
  "compile-goto-error"

/-- The name the command a compile's job posts its output to is registered
under. -/
def outputName : String :=
  "compilation-output"

/-- The name the job that runs a compile is registered under. -/
def runJob : String :=
  "compile-run"

/-- The name of the compilation buffer's major mode. -/
def modeName : String :=
  "compilation"

/-- The name of the buffer local that keeps a directory scope's directory in
its compilation buffer. -/
def directoryLocal : String :=
  "compile-directory"

/-- The most bytes a line of a compile's output may have: a mebibyte. -/
def lineBound : Nat :=
  1024 * 1024

/-- How long the job waits after posting a batch of output before it reads
again, in milliseconds. -/
def batchPause : Nat :=
  50

/-! ## The scope and its state -/

/-- Where a compile belongs ("The scope", in the module docs). -/
inductive Scope where
  /-- The buffer's workspace and its project. -/
  | workspace (workspace : Workspace) (project : Project)
  /-- A directory standing for a workspace of its own. -/
  | directory (path : System.FilePath)

/-- What a scope's state and its job are keyed by, and what crosses as job
arguments. -/
inductive Place where
  /-- The workspace at `location`. -/
  | workspace (location : Location)
  /-- The directory `path`. -/
  | directory (path : System.FilePath)
  deriving DecidableEq, Repr

/-- The scope of the buffer `buffer` in `state` ("The scope", in the module
docs). -/
def Scope.of (state : EditorState) (buffer : BufferId) : Scope :=
  match state.workspaceOf? buffer with
  | some (found, project) => .workspace found project
  | none =>
    match state.value? buffer directoryLocal with
    | some (.str path) => .directory path
    | _ =>
      match (state.buffer? buffer).bind (·.file) with
      | some file => .directory (file.path.parent.getD state.workingDirectory)
      | none => .directory state.workingDirectory

/-- The scope's place. -/
def Scope.place : Scope → Place
  | .workspace found _ => .workspace found.location
  | .directory path => .directory path

/-- The scope's listing place (`Editor/ProjectMode/Listing.lean`): its
workspace's location, `some none` for a directory scope, and none for a
workspace whose location cannot run commands (`Location.can`). -/
def Scope.listingPlace : Scope → Option (Option Location)
  | .workspace found _ => placeOfLocation found.location
  | .directory _ => some none

/-- The scope's label: its workspace's, or its directory's last
component. -/
def Scope.label : Scope → String
  | .workspace found _ => found.label
  | .directory path => path.fileName.getD path.toString

/-- Where the scope's compile runs: its workspace's root, or its
directory. -/
def Scope.root : Scope → System.FilePath
  | .workspace found _ => found.location.root?.getD "/"
  | .directory path => path

/-- The job key of the run in `place`. -/
def Place.jobKey : Place → String
  | .workspace location => s!"compile {location.describe}"
  | .directory path => s!"compile directory {path}"

/-- A place as arguments: its kind, then its parts. -/
def Place.arguments : Place → List Argument
  | .workspace location => .str "workspace" :: location.arguments
  | .directory path => [.str "directory", .str path.toString]

/-- The place `arguments` start with (`Place.arguments`), and the rest. -/
def Place.of? : List Argument → Option (Place × List Argument)
  | .str "workspace" :: rest => do
    let (location, rest) ← Location.of? rest
    return (.workspace location, rest)
  | .str "directory" :: .str path :: rest => some (.directory path, rest)
  | _ => none

/-- The run in flight in a scope. -/
structure Running where
  /-- Its number among the scope's runs, from 1. -/
  run : Nat
  /-- Its line. -/
  line : String
  /-- The clock's reading when it started, in milliseconds. -/
  started : Nat
  deriving DecidableEq, Repr

/-- What a scope keeps ("The scope", in the module docs). -/
structure Record where
  /-- The number of its compilation buffer. -/
  buffer : Option Nat := none
  /-- The last line it ran, and the directory it ran in. -/
  last : Option (String × String) := none
  /-- How many runs it has started. -/
  runs : Nat := 0
  /-- The run in flight. -/
  running : Option Running := none
  /-- The locations its last run's output has given so far ("Locations", in
  the module docs). -/
  locations : Array Site := #[]
  /-- The index in `locations` of the current location, the one last
  visited ("Stepping", in the module docs); none at first. -/
  current : Option Nat := none
  /-- The on-modes its last run started with ("The hook", in the module
  docs), nearest first. -/
  modes : Array Workspace.OnMode := #[]
  deriving DecidableEq, Repr

/-- A record as a tree. -/
def Record.encode (record : Record) : Value :=
  .record
    [("buffer", optional .nat record.buffer),
      ("last", optional (fun (line, directory) => .list [.str line, .str directory]) record.last),
      ("runs", .nat record.runs),
      ("running",
        optional (fun running => .list [.nat running.run, .str running.line, .nat running.started])
          record.running),
      ("locations", .list (record.locations.toList.map Site.encode)),
      ("current", optional .nat record.current),
      ("modes", .list (record.modes.toList.map Workspace.OnMode.encode))]

/-- The record a tree is (`Record.encode`), if it is one. -/
def Record.decode : Value → Option Record
  | .record fields => do
    let buffer ←
      match field fields "buffer" with
      | .nat n =>
        some (some n)
      | .null =>
        some none
      | _ =>
        none
    let last ←
      match field fields "last" with
      | .list [.str line, .str directory] =>
        some (some (line, directory))
      | .null =>
        some none
      | _ =>
        none
    let .nat runs := field fields "runs" | none
    let running ←
      match field fields "running" with
      | .list [.nat run, .str line, .nat started] =>
        some (some { run, line, started })
      | .null =>
        some none
      | _ =>
        none
    let .list sites := field fields "locations" | none
    let locations ← sites.toArray.mapM Site.decode
    let current ←
      match field fields "current" with
      | .nat n =>
        some (some n)
      | .null =>
        some none
      | _ =>
        none
    let .list modes := field fields "modes" | none
    let modes ← modes.toArray.mapM Workspace.OnMode.decode?
    return { buffer, last, runs, running, locations, current, modes }
  | _ => none

/-- A workspace's record. -/
def store : Store Record :=
  { name := "compile", version := 3, initial := {}, encode := Record.encode
    decode := Record.decode }

/-- The records of the directory scopes, by directory, in the unscoped
store. -/
def directoryStore : Store (Array (String × Record)) :=
  { name := "compile-directories", version := 3, initial := #[]
    encode := fun all =>
      .list (all.toList.map fun (directory, record) => .list [.str directory, record.encode])
    decode := fun
      | .list items =>
        items.toArray.mapM fun
          | .list [.str directory, tree] => (directory, ·) <$> Record.decode tree
          | _ => none
      | _ => none }

/-- The record of `place` in `state`. -/
def recordOf (state : EditorState) : Place → Record
  | .workspace location => state.workspaces.get store location
  | .directory path =>
    (((state.workspaces.getUnscoped directoryStore).find? (·.1 == path.toString)).map (·.2)).getD {}

/-- Has `place` keep `record`. -/
def setRecord (place : Place) (record : Record) : EditorM Unit := do
  match place with
  | .workspace location =>
    discard <| Workspace.set store location record
  | .directory path =>
    let key := path.toString
    let all := (← editorState).workspaces.getUnscoped directoryStore
    let all :=
      if all.any (·.1 == key) then
        all.map fun entry => if entry.1 == key then (key, record) else entry
      else all.push (key, record)
    Workspace.setUnscoped directoryStore all

/-- The lines compiled in a scope, newest first, each once: its project's, or,
for a directory scope, the unscoped store's, which every directory shares. -/
def historyStore : Store (Array String) :=
  { Shell.historyStore with name := "compile-history" }

/-- The history `scope` offers in `state`. -/
def history (state : EditorState) : Scope → Array String
  | .workspace _ project => state.workspaces.getOfProject historyStore project.identity
  | .directory _ => state.workspaces.getUnscoped historyStore

/-- Records `line` first in the history of `scope` (`Shell.remember`). -/
def remember (scope : Scope) (line : String) : EditorM Unit := do
  let lines := Shell.remember line (history (← editorState) scope)
  match scope with
  | .workspace _ project =>
    discard <| Project.set historyStore project.identity lines
  | .directory _ =>
    Workspace.setUnscoped historyStore lines

/-- The settings config gives the project of `identity` for the mode
`mode`, as the hook the loop answers holds them ("The hook", in the module
docs); none when it gives none. -/
def projectSettings (identity : Project.Identity) (mode : String) :
    EditorM (List (String × Value)) := do
  return (← RegistryRequest.ask .compileHook).settingsOf identity mode

/-- The commands the on-modes `modes` offer in `scope` ("The hook", in the
module docs): the hook asked of the loop, with the commands the scope's
listings last gave and, for a workspace scope, its project's commands. -/
def hookOffers (scope : Scope) (modes : Array Workspace.OnMode) : EditorM (Array Offer) := do
  let hook ← RegistryRequest.ask .compileHook
  let projects :=
    match scope with
    | .workspace _ project => hook.projectsOf project.identity
    | .directory _ => #[]
  let state ← editorState
  let listed :=
    match scope.listingPlace with
    | some place => listedCommands state place
    | none => fun _ _ => #[]
  return offers hook.contributions projects modes listed

/-- Checks the listings of the on-modes `modes` in `scope`'s place, at a use
of the hook ("The hook", in the module docs). -/
def refreshScope (scope : Scope) (modes : Array Workspace.OnMode) : EditorM Unit := do
  if let some place := scope.listingPlace then
    refreshListings place modes

/-- The on-modes `modes` as arguments: each one's name, then its root. -/
def modeArguments (modes : Array Workspace.OnMode) : List Argument :=
  modes.toList.flatMap fun on => [.str on.mode, .str on.root.toString]

/-- The on-modes `arguments` are (`modeArguments`), if they are them. -/
def modesOfArguments? : List Argument → Option (Array Workspace.OnMode)
  | [] => some #[]
  | .str mode :: .str root :: rest => (modesOfArguments? rest).map (#[{ mode, root }] ++ ·)
  | _ => none

/-! ## What is said -/

/-- What `name` says in a workspace whose location cannot run commands. -/
def cannotRun (name : String) (workspace : Workspace) : String :=
  s!"{name}: {workspace.label} is {workspace.location.describe}, where commands cannot run"

/-- What `compile` says of an empty line. -/
def noCommand : String :=
  s!"{compileName}: no command"

/-- What `recompile` says in the scope labelled `label` when nothing was
compiled there. -/
def nothingCompiled (label : String) : String :=
  s!"{recompileName}: nothing has been compiled in {label}"

/-- What `name` says when the confirm prompt was answered no. -/
def leftRunning (name : String) (label : String) : String :=
  s!"{name}: left the compilation running in {label}"

/-- The label of the prompt that asks before the run in flight in the scope
labelled `label` is killed. -/
def confirmLabel (label : String) : String :=
  s!"Kill the compilation running in {label}? (y or n) "

/-- Whether `answer` confirms: `y` or `yes`, trimmed and in any case. -/
def confirms (answer : String) : Bool :=
  let answer := answer.trimAscii.toString.toLower
  answer == "y" || answer == "yes"

/-- What `kill-compilation` says with nothing running in the scope labelled
`label`. -/
def nothingRunning (label : String) : String :=
  s!"{killName}: nothing is compiling in {label}"

/-- What `name` says of a start that was refused. -/
def notStarted (name : String) (refusal : JobRefusal) : String :=
  s!"{name}: {refusal.describe}"

/-- What `next-error` says past the last location of the scope labelled
`label`. -/
def noMore (label : String) : String :=
  s!"{nextName}: no more locations in {label}"

/-- What `previous-error` says before the first location of the scope
labelled `label`, or with no current one. -/
def noEarlier (label : String) : String :=
  s!"{previousName}: no earlier locations in {label}"

/-- What the command `name` says in the scope labelled `label` with no
locations. -/
def noLocations (name : String) (label : String) : String :=
  s!"{name}: no locations in {label}"

/-- What `compile-goto-error` says on a line of a compilation buffer that no
location covers. -/
def noLocationHere : String :=
  s!"{gotoName}: no location on this line"

/-- What `compile-goto-error` says in the buffer called `name`, which is not
its scope's compilation buffer. -/
def notCompilation (name : String) : String :=
  s!"{gotoName}: {name} is not a compilation buffer"

/-- The label of the prompt for a line. -/
def promptLabel : String :=
  "Compile command: "

/-- The label of `compile-command`'s prompt for one of the on-modes'
commands. -/
def commandPromptLabel : String :=
  "Mode command: "

/-- What `compile-command` says in the scope labelled `label` when no
on-mode offers a command. -/
def noModeCommands (label : String) : String :=
  s!"{commandName}: no mode gives commands in {label}"

/-- What `compile-command` says of an empty answer. -/
def noNamedCommand : String :=
  s!"{commandName}: no command"

/-- What `compile-command` says of an answer that chooses no command in
the scope labelled `label`. -/
def noSuchCommand (answer label : String) : String :=
  s!"{commandName}: no command {answer} in {label}"

/-- The header line of a run of `line` in `directory` in the scope labelled
`label`. -/
def header (label : String) (directory : System.FilePath) (line : String) : String :=
  s!"{label} in {directory}: {line}"

/-- `milliseconds` as the last line says it: seconds, with tenths. -/
def elapsed (milliseconds : Nat) : String :=
  s!"{milliseconds / 1000}.{milliseconds % 1000 / 100} s"

/-- How a run ended, as its last line says it. -/
inductive How where
  /-- The child exited with this status. -/
  | exited (exit : Process.Exit)
  /-- `kill-compilation` killed it. -/
  | killed
  /-- Its output could not be read on, for this reason. -/
  | stopped (detail : String)
  /-- It could not be started, for this reason. -/
  | couldNotStart (detail : String)
  deriving DecidableEq, Repr

/-- How a run ended, in Emacs's words. -/
def How.describe : How → String
  | .exited (.code 0) => "finished"
  | .exited (.code n) => s!"exited abnormally with code {n}"
  | .exited (.signal n) => s!"killed by signal {n}"
  | .killed => "killed"
  | .stopped detail => s!"stopped: {detail}"
  | .couldNotStart detail => s!"could not start: {detail}"

/-- How a run whose child's last delivery said `ended` ended. -/
def How.ofEnd : Process.End → How
  | .exited exit => .exited exit
  | .lineTooLong .out bound => .stopped s!"a line of standard output was longer than {bound} bytes"
  | .lineTooLong .err bound => .stopped s!"a line of standard error was longer than {bound} bytes"
  | .failed detail => .stopped detail

/-- The last line of a run that ended as `how` after `milliseconds`. -/
def lastLine (how : How) (milliseconds : Nat) : String :=
  s!"Compilation {how.describe} after {elapsed milliseconds}"

/-- The name of the compilation buffer of the scope labelled `label`. -/
def bufferName (label : String) : String :=
  s!"*compilation: {label}*"

/-- The name a new compilation buffer of `scope` gets in `state`
("The run", in the module docs). -/
def freeBufferName (state : EditorState) (scope : Scope) : String :=
  let plain := bufferName scope.label
  if (state.findBuffer plain).isNone then plain
  else
    let parent := scope.root.parent.getD "/"
    let component := parent.fileName.getD parent.toString
    state.freeName (bufferName s!"{scope.label} ({component})")

/-! ## The order -/

/-- What the run job is started with. -/
structure Order where
  /-- The line, as `/bin/sh -c` is handed it. -/
  line : String
  /-- Where the child runs. -/
  directory : System.FilePath
  /-- The scope's place. -/
  place : Place
  /-- The run's number in its scope. -/
  run : Nat
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with. -/
def Order.arguments (order : Order) : List Argument :=
  [.str order.line, .str order.directory.toString, .nat order.run] ++ order.place.arguments

/-- The order `arguments` are, if they are one (`Order.arguments`). -/
def Order.ofArguments? : List Argument → Option Order
  | .str line :: .str directory :: .nat run :: rest =>
    match Place.of? rest with
    | some (place, []) => some { line, directory, place, run }
    | _ => none
  | _ => none

/-- The child an order runs: `/bin/sh -c <line>` in its directory. -/
def Order.command (order : Order) : Process.Command :=
  { program := "/bin/sh", arguments := #["-c", order.line], directory := order.directory }

/-! ## The buffer -/

/-- The views showing the buffer `id`. -/
def viewsOf (state : EditorState) (id : BufferId) : Array ViewId :=
  (state.windows.filter (·.buffer == id)).map (·.id)

/-- The kept compilation buffer of `record`, while its number still names a
buffer. -/
def kept (state : EditorState) (record : Record) : Option BufferId :=
  (record.buffer.filter fun index => (state.buffer? ⟨index⟩).isSome).map (⟨·⟩)

/-- The on-modes a command asked from the buffer `buffer` uses, given its
scope's record `record` ("The hook", in the module docs): the record's in
the scope's kept compilation buffer, else the buffer's own. -/
def modesOf (state : EditorState) (record : Record) (buffer : BufferId) : Array Workspace.OnMode :=
  if kept state record == some buffer then record.modes else Workspace.onModesOf state buffer

/-- Appends `lines`, each ended with a line feed, to the buffer `id`, inside
`writing`, and answers the row and the byte offset where the first of them
starts. Each view showing it whose cursor is on the last line, or the empty
row after it, follows: its cursor is put at the start of the new last line
("Following", in the module docs). Others are left where they are. -/
def append (id : BufferId) (lines : Array String) : EditorM (Option (Nat × Nat)) := do
  if lines.isEmpty then
    return none
  let .ok text ← id.text | return none
  let count ← text.lineCount
  let length ← text.byteLength
  let mut followers := #[]
  for view in viewsOf (← editorState) id do
    if let .ok selection← view.selection then
      let head := (selection.ranges[selection.primary]?.map (·.head)).getD 0
      if (← text.pointOf head).row + 1 ≥ count then
        followers := followers.push view
  id.writing do
      text.insert length (String.join (lines.map (· ++ "\n")).toList)
  let last ← text.offsetOf { row := (← text.lineCount) - 1, column := 0 }
  for view in followers do
    Files.placeCursor view last
  -- The text always ends in a line feed, so its lines before the insert are
  -- the row the first appended line starts.
  return some (count, length)

/-- Shows the buffer `id` for a run the command `name` asked from `view`
("The run", in the module docs): a made buffer is given the `compilation`
mode first, so a display rule can match it, and the buffer is shown where
the display rules say for `name`, a window that shows it already reused,
with the focus staying when no rule matches. -/
def showFrom (name : String) (view : ViewId) (id : BufferId) (made : Bool) : EditorM Unit := do
  if made then
    discard <| id.setMajorMode modeName
  discard <| id.display view name (focus := false)

/-- Makes the scope's compilation buffer hold `content`, the header line: the
kept one's text replaced, or one made ("The run", in the module docs). Its
id, and whether it was made. -/
def prepare (scope : Scope) (record : Record) (content : String) :
    EditorM (Option (BufferId × Bool)) := do
  let state ← editorState
  match kept state record with
  | some id =>
    let .ok text ← id.text | return none
    id.writing do
        text.replaceRange 0 (← text.byteLength) content
    discard <| id.setSpans #[]
    -- Every view of it starts the new run on the header line, so it follows.
    for view in viewsOf state id do
      Files.placeCursor view 0
    return some (id, false)
  | none =>
    let .ok id ← createBuffer (freeBufferName state scope) content | return none
    discard <| id.setReadOnly true
    match scope with
    | .workspace workspace _ =>
      Workspace.setBufferWorkspace id workspace.location
    | .directory path =>
      discard <| id.setValue directoryLocal (.str path.toString)
    return some (id, true)

/-! ## The commands, the job and its commands -/

/-- Starts a run of `line` in `directory` for `scope`, with the on-modes
`modes`, asked from `view` by the command `name` ("The run", in the module
docs). -/
def start (name : String) (view : ViewId) (scope : Scope) (line : String)
    (directory : System.FilePath) (modes : Array Workspace.OnMode) : EditorM Unit := do
  let place := scope.place
  let record := recordOf (← editorState) place
  let run := record.runs + 1
  let order : Order := { line, directory, place, run }
  match ← startJob runJob order.arguments (key := some place.jobKey) with
  | .error refusal =>
    message (notStarted name refusal)
  | .ok () =>
    remember scope line
    let started ← Watch.now
    let prepared ← prepare scope record (header scope.label directory line ++ "\n")
    setRecord place
        { record with
          runs := run, last := some (line, directory.toString)
          running := some { run, line, started }
          locations := #[], current := none, modes
          buffer := (prepared.map (·.1.index)).orElse fun _ => record.buffer }
    if let some (id, made) := prepared then
      showFrom name view id made

/-- The scope of the buffer of `call`'s window, and why it may not run a
command named `name`, if it may not. -/
def scopeOf (call : Call) (name : String) : EditorM (Scope × Option String) := do
  let scope := Scope.of (← editorState) call.target.window.buffer
  match scope with
  | .workspace workspace _ =>
    if workspace.location.can.runCommands then
      return (scope, none)
    else
      return (scope, some (cannotRun name workspace))
  | .directory _ =>
    return (scope, none)

/-- Starts a run of `line` in `directory` for `scope`, with the on-modes
`modes`, asked from `view` by the command `name`, unless the scope's own run
is in flight: then it asks first, the confirm prompt's continuation carrying
the run and its modes ("The commands", in the module docs). -/
def startOrAsk (name : String) (view : ViewId) (scope : Scope) (line : String)
    (directory : System.FilePath) (modes : Array Workspace.OnMode) : EditorM Unit := do
  if (recordOf (← editorState) scope.place).running.isSome then
    discard <|
        prompt (confirmLabel scope.label)
          { command := confirmName
            arguments := [.str name, .str line, .str directory.toString] ++ modeArguments modes }
  else
    start name view scope line directory modes

/-- `compile` ("The commands", in the module docs): the line is its first
argument; an answer of its prompt comes back with `true` after it. It runs
in the first on-mode's root, or the scope's ("The hook"). The prompt offers
the scope's last line, or the on-modes' first command, and its history. -/
def compileCommand (call : Call) : EditorM Unit := do
  let (scope, refusal) ← scopeOf call compileName
  if let some reason := refusal then
    message reason
    return
  let record := recordOf (← editorState) scope.place
  let modes := modesOf (← editorState) record call.target.window.buffer
  let directory := (modes[0]?.map (·.root)).getD scope.root
  match call.arguments with
  | .str line :: rest =>
    if !line.trimAscii.isEmpty then
      startOrAsk compileName call.target.window.id scope line directory modes
    else
      if rest matches .bool true :: _ then
        message noCommand
      else
        ask scope record modes
  | _ =>
    ask scope record modes
where
  /-- Opens the prompt for a line, whose answer comes back to `compile`. -/
  ask (scope : Scope) (record : Record) (modes : Array Workspace.OnMode) : EditorM Unit := do
    refreshScope scope modes
    let offered ← hookOffers scope modes
    let initial :=
      match record.last, offered[0]? with
      | some (line, _), _ => line
      | none, some offer => offer.line
      | none, none => ""
    let state ← editorState
    discard <|
        prompt promptLabel { command := compileName, arguments := [.bool true] } initial
          [.given (.ofTexts "compile-history" "compile" (history state scope))]

/-- `compile-command` ("The commands", in the module docs): the answer is
its first argument; an answer of its prompt comes back with `true` after
it. The chosen command's line runs in its mode's root, with every on-mode
as the run's. -/
def commandCommand (call : Call) : EditorM Unit := do
  let (scope, refusal) ← scopeOf call commandName
  if let some reason := refusal then
    message reason
    return
  let record := recordOf (← editorState) scope.place
  let modes := modesOf (← editorState) record call.target.window.buffer
  refreshScope scope modes
  let offered ← hookOffers scope modes
  if offered.isEmpty then
    message (noModeCommands scope.label)
    return
  match call.arguments with
  | .str answer :: rest =>
    if answer.trimAscii.isEmpty then
      if rest matches .bool true :: _ then
        message noNamedCommand
      else
        ask offered
    else
      match chooseOffer offered answer with
      | some offer =>
        startOrAsk commandName call.target.window.id scope offer.line offer.root modes
      | none =>
        message (noSuchCommand answer.trimAscii.toString scope.label)
  | _ =>
    ask offered
where
  /-- Opens the prompt for a command, whose answer comes back to
  `compile-command`. -/
  ask (offered : Array Offer) : EditorM Unit :=
    discard <|
      prompt commandPromptLabel { command := commandName, arguments := [.bool true] } ""
        [.given (.ofTexts "compile-commands" "compile-command" (offered.map (·.candidate)))]

/-- `recompile` ("The commands", in the module docs): reruns the scope's last
line in the directory it ran in, with no prompt, asking first when the
scope's own run is in flight. -/
def recompileCommand (call : Call) : EditorM Unit := do
  let (scope, refusal) ← scopeOf call recompileName
  if let some reason := refusal then
    message reason
    return
  match (recordOf (← editorState) scope.place).last with
  | none =>
    message (nothingCompiled scope.label)
  | some (line, directory) =>
    startOrAsk recompileName call.target.window.id scope line directory
        (recordOf (← editorState) scope.place).modes

/-- `compile-confirm`, the confirm prompt's continuation: its answer, then
the asking command's name, the line, the directory and the run's on-modes
(`modeArguments`). A yes starts the run, which cancels the one in flight
through its key; anything else leaves both alone and says so. -/
def confirmCommand (call : Call) : EditorM Unit := do
  let .str answer :: .str name :: .str line :: .str directory :: rest := call.arguments | return
  let scope := Scope.of (← editorState) call.target.window.buffer
  if confirms answer then
    start name call.target.window.id scope line directory ((modesOfArguments? rest).getD #[])
  else
    message (leftRunning name scope.label)

/-- `kill-compilation` ("The commands", in the module docs). -/
def killCommand (call : Call) : EditorM Unit := do
  let state ← editorState
  let scope := Scope.of state call.target.window.buffer
  let record := recordOf state scope.place
  match record.running with
  | none =>
    message (nothingRunning scope.label)
  | some running =>
    cancelJob scope.place.jobKey
    let text := lastLine .killed ((← Watch.now) - running.started)
    setRecord scope.place { record with running := none }
    if let some id := kept state record then
      discard <| append id #[text]
    message s!"{scope.label}: {text}"

/-- The record of `place` and its kept buffer, while `run` is its run in
flight. -/
def current (place : Place) (run : Nat) : EditorM (Option (Record × Running)) := do
  let record := recordOf (← editorState) place
  match record.running with
  | some running =>
    return if running.run == run then some (record, running) else none
  | none =>
    return none

/-- The face a location of `severity` is drawn in ("Locations", in the
module docs). -/
def Severity.face : Severity → FaceName
  | .error => ⟨"compilation.error"⟩
  | .warning => ⟨"compilation.warning"⟩
  | .note => ⟨"compilation.note"⟩

/-- The span a site's location text is drawn as: its byte range in the
compilation buffer, in its severity's face. -/
def Site.span (site : Site) : Decoration :=
  { start := site.start, stop := site.stop, face := site.severity.face }

/-- `record` with the locations `lines` give, appended to the buffer `id` at
`start`, its row and byte offset ("Locations", in the module docs); each new
location's span is added to the buffer's, and a joined continuation adds
none. Relative files resolve against the run's directory, and the lines are
read with the run's modes' formats, then the general one (`formatsOf`). -/
def noteSites (record : Record) (id : BufferId) (start : Nat × Nat) (lines : Array String) :
    EditorM Record := do
  let state ← editorState
  let hook ← RegistryRequest.ask .compileHook
  let directory : System.FilePath := (record.last.map (·.2)).getD state.workingDirectory
  -- The row before the first appended one, when it is output and not the
  -- header line (row 0), may be a lead.
  let previous ←
    if start.1 ≥ 2 then
      match ← id.text with
      | .ok text =>
        let from_ ← text.offsetOf ⟨start.1 - 1, 0⟩
        pure (some (← text.slice from_ (start.2 - 1)))
      | .error _ =>
        pure none
    else
      pure none
  let locations :=
    scan (formatsOf hook.contributions record.modes) directory record.locations start.1 start.2
      lines previous
  let added := (locations.extract record.locations.size locations.size).map Site.span
  unless added.isEmpty do
    let old := ((state.buffer? id).map (·.spans)).getD #[]
    discard <| id.setSpans (old ++ added)
  return { record with locations }

/-- `compilation-output`: appends the lines its arguments carry after the
place and the run to the scope's kept buffer, while that run is in flight
("The run", in the module docs). -/
def outputCommand (call : Call) : EditorM Unit := do
  let some (place, .nat run :: lines) := Place.of? call.arguments | return
  let some (record, _) ← current place run | return
  let some id := kept (← editorState) record | return
  let lines :=
    lines.toArray.filterMap fun
      | .str line => some line
      | _ => none
  let some start ← append id lines | return
  setRecord place (← noteSites record id start lines)

/-- The command a finished run hands the loop ("The run", in the module
docs): while the run is in flight, its last lines and its last line are
appended, the run is cleared and the end is said. -/
def finished (order : Order) (lines : Array String) (how : How) : EditorM Unit := do
  let some (record, running) ← current order.place order.run | return
  let state ← editorState
  let text := lastLine how ((← Watch.now) - running.started)
  let mut record := { record with running := none }
  if let some id := kept state record then
    -- The last line is no output of the child's, and is never scanned.
    if let some start← append id (lines.push text) then
      record ← noteSites record id start lines
  setRecord order.place record
  let label :=
    match order.place with
    | .workspace location =>
      ((state.workspaces.workspace? location).map fun (found : Workspace) => found.label).getD ""
    | .directory path => (Scope.directory path).label
  message s!"{label}: {text}"

/-! ## Stepping -/

/-- The view a location is visited in, asked from `asking` ("Stepping", in
the module docs): the asking view, unless it shows the scope's compilation
buffer `compilation`; then the first other view that is not the
minibuffer's, or, with none, a new view split from the asking one
(`ViewId.split`), or, when the split is refused, the asking view. -/
def visitingView (asking : ViewId) (compilation : Option BufferId) : EditorM ViewId := do
  let state ← editorState
  let shows (view : ViewId) : Bool :=
    compilation.isSome && (state.window? view).map (·.buffer) == compilation
  if !shows asking then
    return asking
  let minibuffer := state.minibufferView?
  match state.windows.find? fun window => !shows window.id && some window.id != minibuffer with
  | some window =>
    return window.id
  | none =>
    match ← asking.split with
    | .ok below =>
      return below
    | .error _ =>
      return asking

/-- Visits the location `index` of `place`'s record `record`, asked from
`asking` ("Stepping", in the module docs): it becomes the current location,
every view of the kept compilation buffer has its cursor put at the start of
the location's first row, and its file is visited at its line and column in
the visiting view (`visitingView`), which is focused with `focus`. -/
def visitLocation (asking : ViewId) (place : Place) (record : Record) (index : Nat) (focus : Bool) :
    EditorM Unit := do
  let some site := record.locations[index]? | return
  setRecord place { record with current := some index }
  let state ← editorState
  let compilation := kept state record
  if let some id := compilation then
    if let .ok text← id.text then
      let offset ← text.offsetOf ⟨site.first, 0⟩
      for view in viewsOf state id do
        Files.placeCursor view offset
  let visiting ← visitingView asking compilation
  Files.visit visiting site.file
      { row := site.line - 1, column := (site.column.map (· - site.columnBase)).getD 0 } focus

/-- `next-error` (`forward`) and `previous-error` ("Stepping", in the module
docs), registered under `name`: one location on in the list of the focused
buffer's scope, from none to the first, stopping with a message at either
end. Asked from a compilation buffer, the focus stays there. -/
def stepCommand (name : String) (forward : Bool) (call : Call) : EditorM Unit := do
  let state ← editorState
  let scope := Scope.of state call.target.window.buffer
  let record := recordOf state scope.place
  if record.locations.isEmpty then
    message (noLocations name scope.label)
    return
  let index :=
    if forward then
      match record.current with
      | none => some 0
      | some current => if current + 1 < record.locations.size then some (current + 1) else none
    else
      match record.current with
      | some (current + 1) => some current
      | _ => none
  match index with
  | some index =>
    visitLocation call.target.window.id scope.place record index false
  | none =>
    message (if forward then noMore scope.label else noEarlier scope.label)

/-- `compile-goto-error` ("Stepping", in the module docs): in its scope's
kept compilation buffer, visits the location whose rows hold the row of the
window's cursor, focusing the visiting view. -/
def gotoCommand (call : Call) : EditorM Unit := do
  let state ← editorState
  let buffer := call.target.window.buffer
  let scope := Scope.of state buffer
  let record := recordOf state scope.place
  if kept state record != some buffer then
    message (notCompilation call.target.buffer.name)
    return
  let selection ← call.target.selection
  let head := (selection.ranges[selection.primary]?.map (·.head)).getD 0
  let row := (← call.target.buffer.text.pointOf head).row
  match record.locations.findIdx? fun site => site.first ≤ row && row ≤ site.last with
  | some index =>
    visitLocation call.target.window.id scope.place record index true
  | none =>
    message noLocationHere

/-- The lines of `frames` as text: each decoded by the store's escape rule,
one trailing carriage return dropped. -/
def linesOf : Process.Frames → Array String
  | .lines lines =>
    lines.map fun line =>
      let text := File.decodeBytes line
      if text.endsWith "\r" then String.ofList text.toList.dropLast else text
  | .bytes _ => #[]

/-- The most reads a run makes: more than any run lives for. -/
def readLimit : Nat :=
  1000000000

/-- The run job ("The run", in the module docs): starts its order's child,
posts its output as it comes, and finishes with how it ended. It fails only
for arguments that are not an order. -/
def runWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    Order.ofArguments? arguments | throw s!"{runJob}: its arguments are not a compile order"
  match
    ← Process.start order.command { stdout := .lines, stderr := .lines, bound := lineBound } with
  | .error error =>
    return finished order #[] (.couldNotStart error.describe)
  | .ok child =>
    for _ in [0:readLimit] do
      match ← Process.read child with
      | .error error =>
        return finished order #[] (.stopped error.describe)
      | .ok delivery =>
        let lines := linesOf delivery.stdout ++ linesOf delivery.stderr
        match delivery.ended with
        | some ended =>
          return finished order lines (How.ofEnd ended)
        | none =>
          unless lines.isEmpty do
            post {
                  command := outputName
                  arguments := order.place.arguments ++ [.nat order.run] ++ lines.toList.map .str }
          sleep batchPause
    return finished order #[] (.stopped s!"no end after {readLimit} reads")

/-- The `compilation` mode ("The mode", in the module docs). -/
def mode : Mode :=
  { name := modeName, roles := [(Role.refresh, recompileName), (Role.activate, gotoName)] }

end Editor.Compile
