import Editor.Api
import Editor.Command.Call
import Editor.File
import Editor.Files
import Editor.Mode
import Editor.Shell

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
how many runs it has started; and the run in flight, with its line and the
clock's reading when it started (`Watch.now`). A workspace's is in its store
(`store`), a directory's in the unscoped store, by directory
(`directoryStore`). The lines compiled are a history, newest first, each
once (`Shell.remember`): the project's (`historyStore`), so every worktree of
a codebase offers the same lines, or for a directory scope the unscoped
store's, which every directory shares. A line is recorded when its run
starts.

## The commands

- **`compile`** (`compileName`): a location that cannot run commands
  (`Location.can`) refuses before anything is asked or started. With no
  line, or an empty one, it prompts, `Compile command: `, with the scope's
  last line as its text and the scope's history as its candidates, and the
  answer comes back to it; an empty answer says `compile: no command`. With
  a line it starts the run ("The run").
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

A start (`start`) runs the line in the workspace's root, or the scope's
directory; a start that is refused is said, `compile: <refusal>`. Then the
scope's record keeps the run, and the compilation buffer is made, or its
text replaced by the header line:

- **The buffer** is the scope's kept buffer while its number still names a
  buffer; otherwise one is made, read-only (`BufferId.setReadOnly`), with
  the scope's workspace or its `compile-directory` local, named
  `*compilation: <label>*`, or, when that is taken, `*compilation: <label>
  (<parent>)*` with the last component of the root's parent directory, then
  the first free name of that (`EditorState.freeName`).
- **The header line** is `<label> in <directory>: <line>`.
- **Shown**: when no view shows the buffer, the asking view is split, the
  new view below shows it and the focus stays where the user is editing; a
  refused split shows it in the asking view. A view that newly shows a made
  buffer has its major mode set to `compilation`.

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
ended with a line feed. `finished` then appends the last line, `Compilation
<how> after <elapsed>` (`lastLine`), clears the run and says
`<label>: <last line>` in the echo area. A compilation buffer closed while
its run ran gets no output; the end is still said.

## The mode

`compilation` (`mode`), whose buffer is read-only to editing commands
(`Editor/Command/Dispatch.lean`, "Read-only buffers"). It fills the role
`refresh` with `recompile`. Phases 4 and 5 add
errors and `next-error`, and the hook.

Pinned by `ModelTest.compileChecks`, on the loop's driver over the editor's
models, the job model and the process model, and over the real process
service by `ContractTest.compileChecks`.
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

/-- The name the command that kills the scope's compilation is registered
under. -/
def killName : String :=
  "kill-compilation"

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
  | .workspace location => .str "workspace" :: Shell.locationArguments location
  | .directory path => [.str "directory", .str path.toString]

/-- The place `arguments` start with (`Place.arguments`), and the rest. -/
def Place.of? : List Argument → Option (Place × List Argument)
  | .str "workspace" :: rest => do
    let (location, rest) ← Shell.locationOf? rest
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
  deriving DecidableEq, Repr

/-- An optional value as a tree: `null` for none. -/
def optional {α : Type} (encode : α → Value) : Option α → Value
  | some value => encode value
  | none => .null

/-- A record as a tree. -/
def Record.encode (record : Record) : Value :=
  .record
    [("buffer", optional .nat record.buffer),
      ("last", optional (fun (line, directory) => .list [.str line, .str directory]) record.last),
      ("runs", .nat record.runs),
      ("running",
        optional (fun running => .list [.nat running.run, .str running.line, .nat running.started])
          record.running)]

/-- The field `name` of `fields`. -/
def field (fields : List (String × Value)) (name : String) : Value :=
  ((fields.find? (·.1 == name)).map (·.2)).getD .null

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
    return { buffer, last, runs, running }
  | _ => none

/-- A workspace's record. -/
def store : Store Record :=
  { name := "compile", version := 1, initial := {}, encode := Record.encode
    decode := Record.decode }

/-- The records of the directory scopes, by directory, in the unscoped
store. -/
def directoryStore : Store (Array (String × Record)) :=
  { name := "compile-directories", version := 1, initial := #[]
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

/-- The label of the prompt for a line. -/
def promptLabel : String :=
  "Compile command: "

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

/-- Puts the cursor of `view` at `offset`, one bar with its shape kept. -/
def placeCursor (view : ViewId) (offset : Nat) : EditorM Unit := do
  if let .ok selection ← view.selection then
    discard <| view.select { selection with ranges := #[⟨offset, offset⟩], primary := 0 }

/-- Appends `lines`, each ended with a line feed, to the buffer `id`, inside
`writing`. Each view showing it whose cursor is on the last line, or the
empty row after it, follows: its cursor is put at the start of the new last
line ("Following", in the module docs). Others are left where they are. -/
def append (id : BufferId) (lines : Array String) : EditorM Unit := do
  if lines.isEmpty then
    return
  let .ok text ← id.text | return
  let count ← text.lineCount
  let mut followers := #[]
  for view in viewsOf (← editorState) id do
    if let .ok selection ← view.selection then
      let head := (selection.ranges[selection.primary]?.map (·.head)).getD 0
      if (← text.pointOf head).row + 1 ≥ count then
        followers := followers.push view
  id.writing do
      text.insert (← text.byteLength) (String.join (lines.map (· ++ "\n")).toList)
  let last ← text.offsetOf { row := (← text.lineCount) - 1, column := 0 }
  for view in followers do
    placeCursor view last

/-- Shows the buffer `id` for a run asked from `view` ("The run", in the
module docs): in a new view below the asking one when no view shows it, the
focus staying, or in the asking one when the split is refused. A made
buffer's new view gets the `compilation` mode. -/
def showFrom (view : ViewId) (id : BufferId) (made : Bool) : EditorM Unit := do
  let state ← editorState
  unless (viewsOf state id).isEmpty do
    return
  let asking := Files.shownIn state view
  let shown ←
    match ← asking.split .rows with
    | .ok below =>
      pure below
    | .error _ =>
      pure asking
  if (← shown.show id) matches .ok () then
    if made then
      discard <| shown.setMajorMode modeName

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
    -- Every view of it starts the new run on the header line, so it follows.
    for view in viewsOf state id do
      placeCursor view 0
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

/-- Starts a run of `line` in `directory` for `scope`, asked from `view` by
the command `name` ("The run", in the module docs). -/
def start (name : String) (view : ViewId) (scope : Scope) (line : String)
    (directory : System.FilePath) : EditorM Unit := do
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
          buffer := (prepared.map (·.1.index)).orElse fun _ => record.buffer }
    if let some (id, made) := prepared then
      showFrom view id made

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

/-- Starts a run of `line` in `directory` for `scope`, asked from `view` by
the command `name`, unless the scope's own run is in flight: then it asks
first, the confirm prompt's continuation carrying the run ("The commands",
in the module docs). -/
def startOrAsk (name : String) (view : ViewId) (scope : Scope) (line : String)
    (directory : System.FilePath) : EditorM Unit := do
  if (recordOf (← editorState) scope.place).running.isSome then
    discard <|
      prompt (confirmLabel scope.label)
        { command := confirmName, arguments := [.str name, .str line, .str directory.toString] }
  else
    start name view scope line directory

/-- `compile` ("The commands", in the module docs): the line is its first
argument; an answer of its prompt comes back with `true` after it. The
prompt offers the scope's last line and its history. -/
def compileCommand (call : Call) : EditorM Unit := do
  let (scope, refusal) ← scopeOf call compileName
  if let some reason := refusal then
    message reason
    return
  match call.arguments with
  | .str line :: rest =>
    if !line.trimAscii.isEmpty then
      startOrAsk compileName call.target.window.id scope line scope.root
    else
      if rest matches .bool true :: _ then
        message noCommand
      else
        ask scope
  | _ =>
    ask scope
where
  /-- Opens the prompt for a line, whose answer comes back to `compile`. -/
  ask (scope : Scope) : EditorM Unit := do
    let state ← editorState
    let initial := ((recordOf state scope.place).last.map (·.1)).getD ""
    discard <|
      prompt promptLabel { command := compileName, arguments := [.bool true] } initial
        (pure (history state scope))

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

/-- `compile-confirm`, the confirm prompt's continuation: its answer, then
the asking command's name, the line and the directory. A yes starts the run,
which cancels the one in flight through its key; anything else leaves both
alone and says so. -/
def confirmCommand (call : Call) : EditorM Unit := do
  let .str answer :: .str name :: .str line :: .str directory :: _ := call.arguments | return
  let scope := Scope.of (← editorState) call.target.window.buffer
  if confirms answer then
    start name call.target.window.id scope line directory
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
      append id #[text]
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

/-- `compilation-output`: appends the lines its arguments carry after the
place and the run to the scope's kept buffer, while that run is in flight
("The run", in the module docs). -/
def outputCommand (call : Call) : EditorM Unit := do
  let some (place, .nat run :: lines) := Place.of? call.arguments | return
  let some (record, _) ← current place run | return
  let some id := kept (← editorState) record | return
  append id
      (lines.toArray.filterMap fun
        | .str line => some line
        | _ => none)

/-- The command a finished run hands the loop ("The run", in the module
docs): while the run is in flight, its last lines and its last line are
appended, the run is cleared and the end is said. -/
def finished (order : Order) (lines : Array String) (how : How) : EditorM Unit := do
  let some (record, running) ← current order.place order.run | return
  let state ← editorState
  let text := lastLine how ((← Watch.now) - running.started)
  setRecord order.place { record with running := none }
  if let some id := kept state record then
    append id (lines.push text)
  let label :=
    match order.place with
    | .workspace location =>
      ((state.workspaces.workspace? location).map fun (found : Workspace) => found.label).getD ""
    | .directory path => (Scope.directory path).label
  message s!"{label}: {text}"

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
  { name := modeName, roles := [(Role.refresh, recompileName)] }

end Editor.Compile
