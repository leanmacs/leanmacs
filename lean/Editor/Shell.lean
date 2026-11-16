import Editor.Api
import Editor.Command.Call
import Editor.File
import Editor.Files

/-!
# `:!`, in the buffer's workspace

A shell command typed on the ex line, `:!cmd`, run in the focused buffer's
workspace (`docs/design/keymaps-and-modes.md`, "The ex command line";
`docs/design/projects.md`). Written over the editor API (`Editor/Api.lean`)
and the job port's process requests (`Editor/Job.lean`). A command may not
wait and a job may, so a run is three programs, as opening a file is
(`Editor/Files.lean`): the command `shell-command`, which starts the job
`shell-run`; the job, which runs the child; and the job's command, which
says what came of it. The ex line hands the command its line
(`Editor/Ex.lean`, "Running a line"). The command and the job as compiled
code registers them are in `Editor/Shell/Compiled.lean`.

## The scope

A run belongs to the focused buffer's **scope** (`Scope`): its workspace and
project, or `outside` for a buffer with no workspace, which has no project
either. Each scope keeps, by `Store` (`Editor/Store.lean`):

- **its history** (`historyStore`): the ex lines run, newest first, each
  once, at most `historyLimit`. It is the project's, so every worktree of a
  codebase offers the same lines; outside, the unscoped store's
  (`Workspace.Table.unscoped`), one for the editor. A line is recorded when
  its run starts. The ex prompt offers the focused buffer's history before
  the bound ex names (`history`).
- **its output buffer** (`outputStore`): the id of the buffer its long
  output went to, the workspace's, or the unscoped store's outside. A
  buffer is never found by its name, so two projects whose labels clash
  never share one.
- **what it is running** (`runningStore`): the ex line of the run in
  flight, the workspace's, or the unscoped store's outside.

Each scope has one job key (`Scope.jobKey`): `shell ` and its location as a
person reads it (`Location.describe`), or `shell outside`. A run is started
under its scope's key, so a second run in a workspace while one runs cancels
the first, and a run in another workspace is left alone.

## The command

`shell-command` (`commandName`, `command`) is handed the shell text and the
ex line, in that order:

1. **A location that cannot run commands** (`Location.can`) refuses before
   anything is recorded or started (`cannotRun`).
2. **The directory** is the workspace's root; with no workspace, the
   directory of the buffer's file; with neither, the editor's working
   directory (`EditorState.workingDirectory`), which the host set.
3. **The time limit** is config's (`shellTimeLimit`, `Editor/Setup.lean`), or
   `defaultTimeLimit`, 30 seconds.
4. **The job is started** (`runJob`) with an order (`Order`), under the
   scope's key. A start that is refused is said, and nothing is recorded.
5. **The line is recorded** in the scope's history, and as what it runs.

## The run

The job (`runWork`) runs `/bin/sh -c <text>` in the directory, with the
directory's environment, as every child gets (`Process.runWithin`), under
`outputLimit` for each stream and the time limit. `/bin/sh`, not `$SHELL`,
so a user's interactive set-up cannot change what runs. A run past its
limit is killed, and so is the child of a job that is cancelled.

## What comes of it

The job's command (`finished`) clears what the scope is running, then:

- **A refusal** (`notFound`, `outputTooLarge`, `timedOut`, …) is said as
  `<line>: ` and its sentence (`ProcessError.describe`).
- **One line or none** (`echoText`): with nothing on standard error and at
  most one line on standard output (one last `\n` or `\r\n` allowed), the
  line goes to the echo area, with ` [exit <n>]` or ` [killed by signal
  <n>]` after it when the exit is not 0. No output says `<line>: no output`.
- **Anything else** (`outputText`) replaces the text of the scope's output
  buffer with standard output, then standard error, each ended with a line
  feed when it is not empty and has none, then a last line `[exit <n>]` or
  `[killed by signal <n>]`. The kept buffer's text is replaced in one
  transaction, so `u` in it brings the last run back. With none kept, one
  is made, named `*shell output: <workspace label>*` or `*shell output*`
  (`<2>`, `<3>` when the name is taken), with the scope's workspace. It is
  shown in the view the line was asked from, or in the focused view when
  that one was closed, by the open command's rule (`Files.shownIn`).
- Bytes become text by the store's escape rule (`File.decodeBytes`), so a
  byte that is not UTF-8 keeps its byte.

Pinned by `ModelTest.shellChecks`, on the loop's driver over the editor's
models, the job model and the process model, and over the real process
service by `ContractTest.shellChecks`.
-/

namespace Editor.Shell

/-- The name the command that runs a shell command is registered under. -/
def commandName : String :=
  "shell-command"

/-- The name the job that runs the child is registered under. -/
def runJob : String :=
  "shell-run"

/-- How long a run may take when config sets no limit, in milliseconds. -/
def defaultTimeLimit : Nat :=
  30000

/-- The most bytes of each stream a run may write: 16 MiB. -/
def outputLimit : Nat :=
  16 * 1024 * 1024

/-- How many lines a scope's history keeps. -/
def historyLimit : Nat :=
  100

/-! ## The scope and its stores -/

/-- Where a run belongs: a workspace and its project, or outside any. -/
inductive Scope where
  /-- The focused buffer's workspace and its project. -/
  | workspace (workspace : Workspace) (project : Project)
  /-- The buffer has no workspace, and so no project. -/
  | outside
  deriving DecidableEq, Repr

/-- The scope of the buffer `buffer` in `state`. -/
def Scope.of (state : EditorState) (buffer : BufferId) : Scope :=
  match state.workspaceOf? buffer with
  | some (found, project) => .workspace found project
  | none => .outside

/-- The location of a scope's workspace, `none` outside any. -/
def Scope.location? : Scope → Option Location
  | .workspace found _ => some found.location
  | .outside => none

/-- The job key of the scope whose workspace is at `location`, or of the one
outside any workspace ("The scope", in the module docs). -/
def keyOf : Option Location → String
  | some location => s!"shell {location.describe}"
  | none => "shell outside"

/-- The scope's job key (`keyOf`). -/
def Scope.jobKey (scope : Scope) : String :=
  keyOf scope.location?

/-- The ex lines run in a scope, newest first, each once. -/
def historyStore : Store (Array String) :=
  { name := "shell-history", version := 1, initial := #[]
    encode := fun lines => .list (lines.toList.map .str)
    decode := fun
      | .list items =>
        items.toArray.mapM fun
          | .str line => some line
          | _ => none
      | _ => none }

/-- An optional number as a tree: `null` for none. -/
def optionalNat : Store (Option Nat) :=
  { name := "", version := 1, initial := none
    encode := fun
      | some n => .nat n
      | none => .null
    decode := fun
      | .nat n => some (some n)
      | .null => some none
      | _ => none }

/-- The number of the buffer a scope's long output went to. -/
def outputStore : Store (Option Nat) :=
  { optionalNat with name := "shell-output" }

/-- The ex line of the run in flight in a scope. -/
def runningStore : Store (Option String) :=
  { name := "shell-running", version := 1, initial := none
    encode := fun
      | some line => .str line
      | none => .null
    decode := fun
      | .str line => some (some line)
      | .null => some none
      | _ => none }

/-- The value of `store` in the workspace at `location`, or in the unscoped
store for `none`. -/
def scopedValue {α : Type} (state : EditorState) (store : Store α) : Option Location → α
  | some location => state.workspaces.get store location
  | none => state.workspaces.getUnscoped store

/-- Has the workspace at `location`, or the unscoped store for `none`, keep
`value` as the value of `store`. A workspace that is gone keeps nothing. -/
def setScoped {α : Type} (store : Store α) (value : α) : Option Location → EditorM Unit
  | some location => discard <| Workspace.set store location value
  | none => Workspace.setUnscoped store value

/-- The history of the buffer `buffer`'s scope: its project's, or the
unscoped store's ("The scope", in the module docs). -/
def history (state : EditorState) (buffer : BufferId) : Array String :=
  match Scope.of state buffer with
  | .workspace _ project => state.workspaces.getOfProject historyStore project.identity
  | .outside => state.workspaces.getUnscoped historyStore

/-- `lines` with `line` first, and no other copy of it, cut at
`historyLimit`. -/
def remember (line : String) (lines : Array String) : Array String :=
  (#[line] ++ lines.filter (· != line)).extract 0 historyLimit

/-- Records `line` in the history of `scope`: its project's, or the unscoped
store's. -/
def record (scope : Scope) (line : String) : EditorM Unit := do
  let state ← editorState
  match scope with
  | .workspace _ project =>
    let lines := state.workspaces.getOfProject historyStore project.identity
    discard <| Project.set historyStore project.identity (remember line lines)
  | .outside =>
    Workspace.setUnscoped historyStore (remember line (state.workspaces.getUnscoped historyStore))

/-! ## The order -/

/-- What the run job is started with: the ex line, the shell text, the
directory and the time limit, the buffer and the view it was asked from,
and the location of its scope's workspace. -/
structure Order where
  /-- The ex line, as run: `!make`. -/
  line : String
  /-- What `/bin/sh -c` is handed. -/
  text : String
  /-- Where the child runs. -/
  directory : System.FilePath
  /-- How long it may run, in milliseconds. -/
  time : Nat
  /-- The buffer the line was run in. -/
  buffer : BufferId
  /-- The view the line was asked from. -/
  view : ViewId
  /-- The location of the scope's workspace; `none` outside any. -/
  scope : Option Location := none
  deriving DecidableEq, Repr

/-- A location as arguments: its kind, then its parts. -/
def locationArguments : Location → List Argument
  | .local root => [.str "local", .str root.toString]
  | .reachable kind target root => [.str "reachable", .str kind, .str target, .str root.toString]
  | .branchOnly remote branch => [.str "branchOnly", .str remote, .str branch]

/-- The location `arguments` start with (`locationArguments`), and the rest. -/
def locationOf? : List Argument → Option (Location × List Argument)
  | .str "local" :: .str root :: rest => some (.local root, rest)
  | .str "reachable" :: .str kind :: .str target :: .str root :: rest =>
    some (.reachable kind target root, rest)
  | .str "branchOnly" :: .str remote :: .str branch :: rest =>
    some (.branchOnly remote branch, rest)
  | _ => none

/-- The order as the arguments a job is started with: the line, the text,
the directory, the time, the buffer's and the view's numbers, then the
scope's location, or `false` for none. -/
def Order.arguments (order : Order) : List Argument :=
  [.str order.line, .str order.text, .str order.directory.toString, .nat order.time,
      .nat order.buffer.index, .nat order.view.index] ++
    match order.scope with
    | some location => locationArguments location
    | none => [.bool false]

/-- The order `arguments` are, if they are one (`Order.arguments`). -/
def Order.ofArguments? : List Argument → Option Order
  | .str line :: .str text :: .str directory :: .nat time :: .nat buffer :: .nat view :: rest =>
    let order : Order := { line, text, directory, time, buffer := ⟨buffer⟩, view := ⟨view⟩ }
    match rest with
    | [.bool false] => some order
    | rest =>
      match locationOf? rest with
      | some (location, []) => some { order with scope := some location }
      | _ => none
  | _ => none

/-- The child an order runs: `/bin/sh -c <text>` in its directory. -/
def Order.command (order : Order) : Process.Command :=
  { program := "/bin/sh", arguments := #["-c", order.text], directory := order.directory }

/-! ## What is said -/

/-- What the echo area says for `:!` with nothing after it. -/
def noCommand : String :=
  "!: no command"

/-- What the echo area says when the workspace `workspace`'s location cannot
run commands. -/
def cannotRun (workspace : Workspace) : String :=
  s!"!: {workspace.label} is {workspace.location.describe}, where commands cannot run"

/-- What the echo area says when the run of `line` could not be started. -/
def notStarted (line : String) (refusal : JobRefusal) : String :=
  s!"{line}: {refusal.describe}"

/-- What the echo area says of a run of `line` that was refused or did not
end with its output. -/
def refused (line : String) (error : ProcessError) : String :=
  s!"{line}: {error.describe}"

/-- How a child ended, as the output buffer's last line and the echo's
suffix say it. -/
def exitText : Process.Exit → String
  | .code n => s!"exit {n}"
  | .signal n => s!"killed by signal {n}"

/-- `text` without one line ending at its end: a `\r\n` or a `\n`. -/
def withoutLastBreak (text : String) : String :=
  if text.endsWith "\r\n" then String.ofList (text.toList.take (text.length - 2))
  else if text.endsWith "\n" then String.ofList (text.toList.take (text.length - 1)) else text

/-- What the echo area says of a run of `line` that ended as `ran`, when it
is one line or none ("What comes of it", in the module docs); `none` when
it is more, or wrote to standard error, and goes to the output buffer. -/
def echoText (line : String) (ran : Process.Ran) : Option String :=
  let body := withoutLastBreak (File.decodeBytes ran.stdout)
  if !ran.stderr.isEmpty || body.contains '\n' then none
  else
    let suffix :=
      match ran.exit with
      | .code 0 => ""
      | exit => s!" [{exitText exit}]"
    some (if body.isEmpty then s!"{line}: no output{suffix}" else body ++ suffix)

/-- `text` ended with a line feed when it is not empty and has none. -/
def ended (text : String) : String :=
  if text.isEmpty || text.endsWith "\n" then text else text ++ "\n"

/-- What the output buffer holds of a run that ended as `ran`: its standard
output, then its standard error, each ended with a line feed, then how it
ended ("What comes of it", in the module docs). -/
def outputText (ran : Process.Ran) : String :=
  ended (File.decodeBytes ran.stdout) ++ ended (File.decodeBytes ran.stderr) ++
    s!"[{exitText ran.exit}]\n"

/-- The name of the output buffer of a scope whose workspace is labelled
`label`, or of the one outside any. -/
def outputName : Option String → String
  | some label => s!"*shell output: {label}*"
  | none => "*shell output*"

/-! ## The command, the job and its command -/

/-- Starts the run of `text`, the ex line `line`, for `target`'s buffer
("The command", in the module docs). -/
def start (target : Target) (line text : String) : EditorM Unit := do
  let buffer := target.window.buffer
  let state ← editorState
  let scope := Scope.of state buffer
  if let .workspace found _ := scope then
    unless found.location.can.runCommands do
      message (cannotRun found)
      return
  let directory :=
    match ← buffer.workingDirectory with
    | .workspace root => root
    | .fileDirectory directory => directory
    | .elsewhere _ | .none => state.workingDirectory
  let time := (← EditorState.ask .shellTimeLimit).getD defaultTimeLimit
  let order : Order :=
    { line, text, directory, time, buffer, view := target.window.id, scope := scope.location? }
  match ← startJob runJob order.arguments (key := some scope.jobKey) with
  | .error refusal =>
    message (notStarted line refusal)
  | .ok () =>
    record scope line
    setScoped runningStore (some line) scope.location?

/-- `shell-command`: runs the shell text that is its first argument, the ex
line that is its second, for the buffer of the window it was called with
("The command", in the module docs). With no text it says so. -/
def command (call : Call) : EditorM Unit := do
  match call.arguments with
  | .str text :: .str line :: _ =>
    start call.target line text
  | _ =>
    message noCommand

/-- Shows the scope's output buffer holding `content` ("What comes of it",
in the module docs): the kept buffer's text replaced, or a buffer made with
the scope's workspace, and shown in the order's view, or the focused view
when that one was closed. -/
def showOutput (order : Order) (content : String) : EditorM Unit := do
  let state ← editorState
  let kept :=
    (scopedValue state outputStore order.scope).filter fun index => (state.buffer? ⟨index⟩).isSome
  let shown ←
    match kept with
    | some index =>
      let id : BufferId := ⟨index⟩
      let .ok text ← id.text | return
      text.replaceRange 0 (← text.byteLength) content
      pure id
    | none =>
      let label :=
        order.scope.bind fun location => (state.workspaces.workspace? location).map (·.label)
      let .ok id ← createBuffer (state.freeName (outputName label)) content | return
      if let some location := order.scope then
        Workspace.setBufferWorkspace id location
      setScoped outputStore (some id.index) order.scope
      pure id
  let state ← editorState
  let view := if (state.window? order.view).isSome then order.view else state.frame.focused
  discard <| (Files.shownIn state view).show shown

/-- The command a finished run hands the loop ("What comes of it", in the
module docs): what the scope runs is cleared, and the reply is said, or its
output shown. -/
def finished (order : Order) (reply : Except ProcessError Process.Ran) : EditorM Unit := do
  setScoped runningStore none order.scope
  match reply with
  | .error error =>
    message (refused order.line error)
  | .ok ran =>
    match echoText order.line ran with
    | some text =>
      message text
    | none =>
      showOutput order (outputText ran)

/-- The run job ("The run", in the module docs): runs its order's child and
finishes with what came of it (`finished`). It fails only for arguments that
are not an order. -/
def runWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    Order.ofArguments? arguments | throw s!"{runJob}: its arguments are not a shell order"
  return finished order (← Process.runWithin order.command outputLimit order.time)

end Editor.Shell
