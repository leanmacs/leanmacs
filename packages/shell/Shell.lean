import Editor.Api
import Editor.Command.Call
import Editor.File
import Editor.Job
import ShellApi

/-!
# `:!`, in the buffer's workspace

A shell command typed on the ex line, `:!cmd`, run in the focused buffer's
workspace (`docs/design/keymaps-and-modes.md`, "The ex command line";
`docs/design/projects.md`). Written over the editor API (`Editor/Api.lean`)
and the job port's process requests (`Editor/Job.lean`). A command may not
wait and a job may, so a run is three programs, as opening a file is
(`packages/files/Files.lean`): the command `shell-command`, which starts the job
`shell-run`; the job, which runs the child; and the job's command, which
says what came of it. The ex line hands the command its line
(`Editor/Ex.lean`, "Running a line"). The command and the job as compiled
code registers them are in `Shell/Compiled.lean`.

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
   directory (`EditorState.workingDirectory`), which the host set. The
   state decides it (`EditorState.commandDirectoryOf`), as it does for
   every command that runs something for a buffer.
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

## The interrupt

`keyboard-quit` (`interruptName`, `interruptCommand`), which the Vim scheme
binds to `C-g` in normal state, cancels the run in flight in the focused
buffer's scope, by the scope's key (`cancelJob`, `Editor/Api.lean`): its
job never delivers a command, and its child is killed with its process
group. What the scope runs is cleared, and the echo area says `<line>:
interrupted`. With nothing running it says `Quit`. A run in another
workspace is left alone.

`C-g` is also the interrupt key (`Watch.interruptKey`): it raises the flag
that stops a command looping, and is then stepped like any key. The job is
cancelled by this command, not by the flag, which a job never reads.

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
  shown where config's display rules say for the opener `shell-command`,
  asked from the view the line was asked from, or from the focused view
  when that one was closed (`BufferId.display`,
  `Editor/DisplayRules.lean`): a window that shows it already is used;
  otherwise, with no rule that matches, a new window at the end of the
  tiled list, focused, so the window the line was asked from keeps its
  buffer.
- Bytes become text by the store's escape rule (`File.decodeBytes`), so a
  byte that is not UTF-8 keeps its byte.

## A filter

`:{range}!cmd` filters the range's lines through the command: the ex line
resolves the range against the view it was asked from (`Range.resolve`,
`Editor/Ex/Line.lean`) and hands `shell-filter` (`filterName`,
`filterCommand`) the first and the last line, the text and the line.

- **What the child is fed**: the range's bytes, from its first line's start
  through its last line's line feed, or the text's end, with one line feed
  added when the last line has none (`Filter`). The child is run as a
  `:!`'s is, in the same directory, under the same key and time limit,
  with that as its standard input, then end of file
  (`Process.runWithInput`). The line is recorded in the history as a
  `:!`'s is.
- **Its output replaces the range** as one edit made by the user
  (`TextId.replaceRange`), so one `u` takes it back, and the echo area says
  `<n> lines filtered`. When the range had no line feed at its end, one
  line feed at the end of the output is dropped (`replacement`).
- **A status other than 0, or anything on standard error**, leaves the
  buffer as it was and says `<line>: exit <n>: <first line of standard
  error>` (`filterFailed`).
- **A buffer edited, or closed, while the child ran** is left as it is:
  the text's revision is recorded when the run starts, and a reply for
  another revision is dropped, `<line>: dropped: the buffer changed while
  it ran`.

The names others reach the shell by, and its history (`Scope`,
`historyStore`, `history`, `remember`, `record`), are the interface library
`shell-api`'s (`ShellApi.lean`), in this namespace, so ex and the compile
mode reach them without this module.

Pinned by `ShellTest.shellChecks`, on the loop's driver over the editor's
models, the job model and the process model, and over the real process
service by `ShellTest.Linked.shellChecks`.
-/

namespace Editor.Shell

/-- The name the command that runs a shell command is registered under:
`shell-api`'s (`ShellApi.commandName`). -/
def commandName : String :=
  ShellApi.commandName

/-- The name the job that runs the child is registered under. -/
def runJob : String :=
  "shell-run"

/-- How long a run may take when config sets no limit, in milliseconds. -/
def defaultTimeLimit : Nat :=
  30000

/-- The most bytes of each stream a run may write: 16 MiB. -/
def outputLimit : Nat :=
  16 * 1024 * 1024

/-! ## The scope and its stores -/

/-- The scope's job key (`keyOf`). -/
def Scope.jobKey (scope : Scope) : String :=
  keyOf scope.location?

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

/-! ## The order -/

/-- What a filter's run carries beside a `:!`'s ("A filter", in the module
docs): where the range is in the buffer's text, the revision the text was
at, what the child is fed, and how many lines that is. -/
structure Filter where
  /-- The byte offset where the range starts: its first line's start. -/
  start : Nat
  /-- The byte offset where it stops: after its last line's line feed, or
  the text's end. -/
  stop : Nat
  /-- The text's revision when the run started. -/
  revision : Nat
  /-- What the child is fed: the range, ended with a line feed. -/
  input : String
  /-- Whether the range ended with a line feed of its own. -/
  ended : Bool
  /-- How many lines the range is. -/
  lines : Nat
  deriving DecidableEq, Repr

/-- What the run job is started with: the ex line, the shell text, the
directory and the time limit, the buffer and the view it was asked from,
the location of its scope's workspace, and, for a filter, its part. -/
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
  /-- A filter's part; `none` for a `:!`. -/
  filter : Option Filter := none
  deriving DecidableEq, Repr

/-- A filter's part as arguments: `true` and its fields, or `false` for
none. -/
def filterArguments : Option Filter → List Argument
  | some filter =>
    [.bool true, .nat filter.start, .nat filter.stop, .nat filter.revision, .str filter.input,
      .bool filter.ended, .nat filter.lines]
  | none => [.bool false]

/-- The filter's part `arguments` start with (`filterArguments`), and the
rest. -/
def filterOf? : List Argument → Option (Option Filter × List Argument)
  | .bool false :: rest => some (none, rest)
  |
  .bool true ::
      .nat start :: .nat stop :: .nat revision :: .str input :: .bool ended :: .nat lines :: rest =>
    some (some { start, stop, revision, input, ended, lines }, rest)
  | _ => none

/-- The order as the arguments a job is started with: the line, the text,
the directory, the time, the buffer's and the view's numbers, the filter's
part, then the scope's location, or `false` for none. -/
def Order.arguments (order : Order) : List Argument :=
  [.str order.line, .str order.text, .str order.directory.toString, .nat order.time,
      .nat order.buffer.index, .nat order.view.index] ++
    filterArguments order.filter ++
    match order.scope with
    | some location => location.arguments
    | none => [.bool false]

/-- The order `arguments` are, if they are one (`Order.arguments`). -/
def Order.ofArguments? : List Argument → Option Order
  | .str line :: .str text :: .str directory :: .nat time :: .nat buffer :: .nat view :: rest => do
    let (filter, rest) ← filterOf? rest
    let order : Order := { line, text, directory, time, buffer := ⟨buffer⟩, view := ⟨view⟩, filter }
    match rest with
    | [.bool false] =>
      some order
    | rest =>
      match Location.of? rest with
      | some (location, []) =>
        some { order with scope := some location }
      | _ =>
        none
  | _ => none

/-- The child an order runs: `/bin/sh -c <text>` in its directory. -/
def Order.command (order : Order) : Process.Command :=
  { program := "/bin/sh", arguments := #["-c", order.text], directory := order.directory }

/-! ## What is said -/

/-- What the echo area says for `:!` with nothing after it: `shell-api`'s
(`ShellApi.noCommand`). -/
def noCommand : String :=
  ShellApi.noCommand

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

/-- What the echo area says of a filter of `line` whose child ended as
`ran`, with a status that is not 0 or something on standard error: the
status, and the first line of standard error. -/
def filterFailed (line : String) (ran : Process.Ran) : String :=
  let first := ((File.decodeBytes ran.stderr).splitOn "\n").headD ""
  let first := if first.endsWith "\r" then String.ofList first.toList.dropLast else first
  if first.isEmpty then s!"{line}: {exitText ran.exit}"
  else s!"{line}: {exitText ran.exit}: {first}"

/-- What the echo area says of a filter of `line` whose buffer was edited,
or closed, while its child ran. -/
def dropped (line : String) : String :=
  s!"{line}: dropped: the buffer changed while it ran"

/-- What the echo area says of a filter of `lines` lines that replaced
them. -/
def filteredText (lines : Nat) : String :=
  if lines == 1 then "1 line filtered" else s!"{lines} lines filtered"

/-- What replaces a filter's range: the child's output, as text, without its
last line feed when the range had none of its own. -/
def replacement (filter : Filter) (stdout : ByteArray) : String :=
  let out := File.decodeBytes stdout
  if filter.ended then out else if out.endsWith "\n" then String.ofList out.toList.dropLast else out

/-- The name of the output buffer of a scope whose workspace is labelled
`label`, or of the one outside any. -/
def outputName : Option String → String
  | some label => s!"*shell output: {label}*"
  | none => "*shell output*"

/-! ## The command, the job and its command -/

/-- Starts the run of `text`, the ex line `line`, for `target`'s buffer
("The command", in the module docs), a filter's when `filter` is given. -/
def start (target : Target) (line text : String) (filter : Option Filter := none) : EditorM Unit :=
  do
  let buffer := target.window.buffer
  let state ← editorState
  let scope := Scope.of state buffer
  if let .workspace found _ := scope then
    unless found.location.can.runCommands do
      message (cannotRun found)
      return
  let directory := state.commandDirectoryOf buffer
  let time := (← RegistryRequest.ask .shellTimeLimit).getD defaultTimeLimit
  let order : Order :=
    { line, text, directory, time, buffer, view := target.window.id, scope := scope.location?
      filter }
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

/-- The name the command that filters lines through a shell command is
registered under: `shell-api`'s (`ShellApi.filterName`). -/
def filterName : String :=
  ShellApi.filterName

/-- `shell-filter`: filters the lines from the first of its arguments to the
second, numbers from 1 the ex line resolved, through the shell text that is
its third, the ex line that is its fourth ("A filter", in the module docs),
in the buffer of the window it was called with. -/
def filterCommand (call : Call) : EditorM Unit := do
  match call.arguments with
  | .nat first :: .nat last :: .str text :: .str line :: _ =>
    let content := call.target.buffer.text
    let rows ← content.rowCount
    let start ← content.offsetOf { row := first - 1, column := 0 }
    let stop ←
      if last < rows then
        content.offsetOf { row := last, column := 0 }
      else
        content.byteLength
    let range ← content.slice start stop
    let ended := range.endsWith "\n"
    let revision ← content.revision
    Shell.start call.target line text
        (some
          { start, stop, revision, input := if ended then range else range ++ "\n", ended
            lines := last + 1 - first })
  | _ =>
    message noCommand

/-- Shows the scope's output buffer holding `content` ("What comes of it",
in the module docs): the kept buffer's text replaced, or a buffer made with
the scope's workspace, and shown where the display rules say for
`shell-command` (`commandName`), asked from the order's view, or the
focused view when that one was closed. -/
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
  discard <| shown.display view commandName

/-- The command a finished run hands the loop ("What comes of it", in the
module docs): what the scope runs is cleared, and the reply is said, or its
output shown. -/
def finished (order : Order) (reply : Except ProcessError Process.Ran) : EditorM Unit := do
  setScoped runningStore none order.scope
  match reply, order.filter with
  | .error error, _ =>
    message (refused order.line error)
  | .ok ran, none =>
    match echoText order.line ran with
    | some text =>
      message text
    | none =>
      showOutput order (outputText ran)
  | .ok ran, some filter =>
    if ran.exit != .code 0 || !ran.stderr.isEmpty then
      message (filterFailed order.line ran)
      return
    let some buffer := (← editorState).buffer? order.buffer | message (dropped order.line)
    if (← buffer.text.revision) != filter.revision then
      message (dropped order.line)
      return
    buffer.text.replaceRange filter.start filter.stop (replacement filter ran.stdout)
    message (filteredText filter.lines)

/-- The name the interrupt command is registered under: the Vim scheme binds
`C-g` to it. `shell-api`'s (`ShellApi.interruptName`). -/
def interruptName : String :=
  ShellApi.interruptName

/-- What the interrupt command says with nothing running in the scope. -/
def quitText : String :=
  "Quit"

/-- What the interrupt command says of the run of `line` it cancelled. -/
def interrupted (line : String) : String :=
  s!"{line}: interrupted"

/-- `keyboard-quit` ("The interrupt", in the module docs): cancels the run in
flight in the scope of the buffer of the window it was called with, by the
scope's key, clears what the scope runs and says the line was interrupted;
with nothing running it says `Quit`. It is made of state requests alone. -/
def interruptCommand (call : Call) : EditorM Unit := do
  let state ← editorState
  let scope := Scope.of state call.target.window.buffer
  match scopedValue state runningStore scope.location? with
  | some line =>
    cancelJob scope.jobKey
    setScoped runningStore none scope.location?
    message (interrupted line)
  | none =>
    message quitText

/-- The run job ("The run", in the module docs): runs its order's child and
finishes with what came of it (`finished`). It fails only for arguments that
are not an order. -/
def runWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    Order.ofArguments? arguments | throw s!"{runJob}: its arguments are not a shell order"
  match order.filter with
  | none =>
    return finished order (← Process.runWithin order.command outputLimit order.time)
  | some filter =>
    return finished order
        (← Process.runWithInput order.command (File.encodeText filter.input) outputLimit order.time)

end Editor.Shell
