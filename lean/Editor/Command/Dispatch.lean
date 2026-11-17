import Editor.Command
import Editor.Highlight
import Editor.Mode

/-!
# A dispatched command

How the command loop runs a command: `EditorM.dispatched`. It is one
transformation of the command's program that does two things. It guards the
command, so that the user can stop it: the watch port's interrupt flag
(`Editor/Watch.lean`) is asked before each of the command's requests that
reaches the library, and once the flag is up the command makes no further
request. And it answers the command's state requests
(`Editor/State/Request.lean`), from the editor state the loop hands in.
What comes back is how the command ended (`Guarded`) and the state it left.

## The guard

The rule has one definition, the last case of `Program.dispatched`: nothing
else guards a program, and every command a host runs goes through it.

- **A command stops at its next request.** One question, whether the flag
  is up, is put before each request of the program that is not a state
  request. When the answer is yes the program is finished there: the
  request is not made, and the continuation is not applied.
- **A command cannot catch an interrupt.** Being interrupted is not a reply
  to the command's request and nothing is thrown: the rest of the command is
  dropped, as the job runner drops a cancelled job's
  (`docs/design/concurrency.md`, "Cancellation"). So a `try`/`catch` round a
  request does not go on. What a command made before it stopped is the
  loop's to roll back.
- **A dispatched command is not refused.** How it ended is its value
  (`Guarded`): it finished, it was refused, it was interrupted, it gave up
  ("A command that gives up"), or it broke off ("A command that breaks
  off"). So the loop that runs it goes on to roll back, where it does, and
  to publish whichever it was.
- **A state request is not guarded.** It is pure Lean, not a call into the
  library, and what the guard bounds is the requests that reach the library
  (`docs/design/concurrency.md`, "When it is asked"). It also keeps a move
  in the history whole towards the guard: the last text request of an undo
  drops the inverses it crossed, and the request after it is the state
  request that records the moved tree. A check between the two could stop a
  command with the inverses dropped and the move unrecorded, which no
  rollback could then take back. A check before the drop stops it with
  nothing dropped.
- **A command that makes no request is not interruptible**, nor is one that
  makes state requests alone: there is no request to stop it at. That is
  accepted (`docs/design/concurrency.md`, "Runaway code is not a design
  driver").
- **The flag is only asked, never lowered, here.** It comes down when the
  loop takes the interrupt key off the queue (`Loop.take`).
- **What it costs**: one request of the watch port, a call into the
  library, for each request of the command that reaches the library.

## The state requests

- **A state request is answered in place.** The transformation holds the
  editor state, answers each state request of the command with the
  requests' pure handler (`EditorState.handle`) and goes on with the state
  after it. No state request is left in the program it returns, so none
  reaches a runner, and the handler is the same function on the models and
  against the library by construction.
- **The state comes back however the command ended**: finished, refused,
  interrupted, having given up or having broken off. A rollback needs the undo trees the
  command left (`Editor/Loop.lean`, "Rollback"), so the state a command
  that did not run to its end had reached is handed back with how it
  ended, and the loop decides what to keep of it.
- **Only the command is dispatched.** The transformation is applied to the
  command alone. The loop's own requests round it are neither guarded nor
  answered here, so a flag that is up never stops a rollback or a scene.

## A command that gives up

A command ends itself, with a reason, by one state request
(`StateRequest.giveUp`, made by `giveUp`, `Editor/Api.lean`): it found that
what it was asked cannot be done, and what it did so far is to be taken
back (`docs/design/concurrency.md`, "Foreground: commands").

- **The program is finished at that request**, with `Guarded.gaveUp` of
  the reason and the state the command had reached. The continuation is
  not applied, as an interrupted command's is not: nothing is thrown, so a
  `try`/`catch` round the call does not go on.
- **It is not a refusal.** The store refused nothing, so the loop says the
  reason alone, with no `refused:` (`Editor/Loop.lean`, "Running an
  invocation"). A command that threw a `TextError` to end itself would be
  said in the store's words for something the store did not refuse.
- **It is not a message and a return.** A command that only said its
  reason would have run to its end: the scheme would keep the state its
  key entered, and what the command did so far would stay.
- **The case recurses nowhere**: it ends the program.

## A command that breaks off

A command also ends itself, with a reason, by a second state request
(`StateRequest.breakOff`, made by `breakOff`, `Editor/Api.lean`): it found
that what its key stands for cannot be done, and what it did so far is to
stay. Evil's operate command breaks off when its motion failed after it
moved the cursor, as Vim cancels the operator and leaves the cursor where
the motion got to (`Editor/Evil/Operators.lean`).

- **The program is finished at that request**, with `Guarded.brokeOff` of
  the reason and the state the command had reached, as one that gives up
  is: the continuation is not applied, and nothing is thrown.
- **It is not a give-up.** The loop rolls nothing back: the state the
  command reached is the loop's, as a finished command's is. It is not a
  command that ran to its end either: the loop says the reason, and puts
  the input scheme back in its state at rest, so the key that ran the
  command has entered no state and is no last change
  (`Editor/Loop.lean`, "Running an invocation").

## Requests that name something registered

A request holds plain data, so it names a mode where it means one, and what
the name stands for is the registry's. `Loop.Registered` is what the
transformation is told of the registry. It is rebuilt by the loop's caller
for each step, with the keymaps (`Loop.Keys`), so a reload's modes hold
from the next command.

- **Setting a major mode** (`StateRequest.setMajorMode`) is refused with
  `noSuchWindow` for a view with no window, and then with `noSuchMode` for
  a name no mode is registered under (`Loop.Registered.entering`), each
  with the state as it was and nothing run. Otherwise the mode is set in
  the state, and, when it became the buffer's major mode, the on-enter
  action of each mode of its lineage runs, root first, each once, with the
  view, before the command goes on with its reply. Setting the major mode
  the buffer already has runs nothing.
- **Setting a buffer's major mode by its id**
  (`StateRequest.setBufferMajorMode`) needs no window: it is refused with
  `noSuchBuffer` for a buffer there is none of, and then with `noSuchMode`,
  each with the state as it was and nothing run. Otherwise it is set as
  above, and the lineage's on-enter actions run once with each view that
  shows the buffer, in the order of the state's windows, and with none for
  a buffer no window shows. The compilation buffer is given its mode this
  way before it is displayed, so a display rule can match the mode
  (`Editor/Compile.lean`).
- **A major mode with a syntax tree is highlighted first.** When the new
  lineage says how its text is parsed and drawn (`Mode.syntaxTreeOf`), the
  loop runs `Highlight.enter` for the buffer's text before the on-enter
  actions: it attaches the text and has it highlighted, and says a refusal
  in the echo area without refusing the command (`Editor/Highlight.lean`).
  When it says nothing and the old major mode's lineage did, the text is
  detached (`Highlight.leave`). When neither says, the syntax tree port is
  asked nothing. It runs inside the command as an on-enter action does, so
  its requests are guarded.
- **An on-enter action runs inside the command.** Its program is put before
  the rest of the command's and goes through this same transformation: its
  state requests are answered from the state the command had reached, its
  other requests are guarded, and what it did is rolled back with the
  command if the command does not run to its end.
- **An on-enter action that is refused refuses the command**, at the
  request that set the mode: the command cannot catch it, since it is no
  reply to that request.
- **Starting a job** (`StateRequest.startJob`) is refused with `noSuchJob`
  for a name no job is registered under (`Loop.Registered.jobs`), with the
  state as it was. Otherwise the start is kept in the state, with its key
  if it has one, for the loop to hand to its host once the command has run
  to its end (`Editor/Loop.lean`, "Jobs from commands"). A cancel
  (`StateRequest.cancelJob`) is the handler's: its key is kept the same
  way, whether or not a job of that key is running.
- **Asking for an ex binding** (`StateRequest.ex`) is answered the binding
  the registry has for the ex name (`Loop.Registered.ex`): the command the
  name runs and what it takes, or `none` for a name nobody bound. The
  state is not read and not changed. What the answer is used for, the ex
  line's rules, is the asking command's (`Editor/Ex.lean`).
- **Asking which ex names are bound** (`StateRequest.exNames`) is answered
  the names the loop was told (`Loop.Registered.exNames`): each bound name
  once. The state is not read and not changed. The ex line asks, for the
  candidates of its prompt.
- **Asking which themes are registered** (`StateRequest.themeNames`) is
  answered the names the loop was told (`Loop.Registered.themeNames`), the
  state not read and not changed. The command that loads a theme asks, for
  the candidates of its prompt.
- **Loading a theme** (`StateRequest.loadTheme`) is refused with
  `noSuchTheme` for a name the loop was not told a theme is registered
  under, with the state as it was. Otherwise the name is kept in the state,
  for the loop to hand to its host once the command has run to its end
  (`Editor/Loop.lean`, "A theme switch from a command").
- **Asking for the workspace settings** (`StateRequest.workspaceSettings`)
  is answered config's workspace roots and the config generation the loop
  was told of (`Loop.Registered.workspaceRoots`, `generation`), the state
  not read and not changed. A file's open asks, for its directory's
  workspace (`Editor/Workspace/Attach.lean`).
- **Asking for the display rules** (`StateRequest.displayRules`) is
  answered config's display rules the loop was told of
  (`Loop.Registered.displayRules`), in order, the state not read and not
  changed. `BufferId.display` asks, to decide where a buffer a command
  made goes (`Editor/DisplayRules.lean`, `EditorState.displaying`).
- **Asking for the shell time limit** (`StateRequest.shellTimeLimit`) is
  answered config's limit the loop was told of
  (`Loop.Registered.shellTimeLimit`), or `none`, the state not read and
  not changed. `:!` asks, for its run's limit (`Editor/Shell.lean`).
- **Running a command inside the asking command**
  (`StateRequest.runCommand`) is answered `false` for a name no command is
  registered under (`Loop.Registered.command`), with nothing run.
  Otherwise the command's program, for the call the request hands it, is
  put before the rest of the asking command's, as an on-enter action's
  is, and the reply is `true` once it has run to its end. A reply cannot
  hold the command itself: a command is a program over the port the reply
  is part of.
  - **It is part of the asking command.** Its state requests are answered
    from the state the asking command had reached, its other requests are
    guarded, and what it did is rolled back with the asking command if
    that does not run to its end.
  - **How it ends is how the asking command ends**, when it does not run
    to its end: refused, it refuses the asking command at the request;
    giving up or breaking off, it ends the asking command's program, as
    the request made by the asking command itself would.
  - **Which command a name stands for is the loop's to say.** The loop
    fills `Loop.Registered.command` from the lookup a key's invocation
    goes through (`Editor/Loop.lean`, "A command run inside another"), so
    a name is one command however it comes to run. It is how evil's dot
    repeat replays a change with the command the change's own keys ran
    (`Editor/Evil/Repeat.lean`).

Putting an action's program, or a command's, before the rest of the command
makes the transformation recurse into a program that is no part of the one
it was given, so it is `partial`, and no theorem is about it. On-enter
actions that set each other's major modes for ever, and commands that run
each other inside themselves for ever, are runaway config code, which
nothing here stops (`docs/design/concurrency.md`, "Runaway code is not a
design driver").

It is a pure transformation of the program, so it runs on the models as it
runs against the library.

## The first edit after a change on disk

After the interrupt flag is asked, and before an insert, a delete, a
transaction or an applied inverse of a text (`TextRequest.edited?`), the
transformation looks the text up among the buffers: when its buffer's file
changed on disk and the user was not told (`EditorState.untold?`,
`Editor/State.lean`, "A buffer's file"), the program ends there, with
`Guarded.superseded`, the edit not made. The loop rolls the command back,
marks the change as told, and says so (`Editor/Loop.lean`, "Files that
changed on disk"), so the next edit lands. An edit script
(`TextId.applyScript`) is not looked at: a reload is never refused by it.
Undo is an edit here too; the loop's own rollback is not dispatched.

## Read-only buffers

Before the first-edit check, the same requests (`TextRequest.edited?`) are
looked at for a read-only buffer over the text (`EditorState.readOnly?`,
`Editor/State.lean`, "Buffers"): the program ends there, the edit not made,
as a command that gives up, with `<name> is read-only`
(`EditorState.readOnlyReason`). So the loop rolls the command back and says
`<command>: <name> is read-only` ("A command that gives up"). Undo is an
edit here too, so `u` in a read-only buffer is refused. The command that
owns the buffer writes it inside `BufferId.writing` (`Editor/Api.lean`),
which clears the flag for the edit, as a state request this transformation
answers in place.

Pinned by `ModelTest.guardChecks` (the guard, on commands that make no
state request), `ModelTest.dispatchStateChecks`,
`ModelTest.modeEnterChecks`, for the first edit after a change on disk,
`ModelTest.stalenessChecks`, and, for read-only buffers,
`ModelTest.readOnlyChecks`.
-/

namespace Editor

/-- How a dispatched command ended. -/
inductive Guarded (α : Type) where
  /-- It ran to its end, with `value`. -/
  | finished (value : α)
  /-- It was refused, with `error`. -/
  | refused (error : TextError)
  /-- The interrupt flag was up before one of its requests, which it did not
  make, nor any after. -/
  | interrupted
  /-- It gave up, with `reason`, and made no request after that one. -/
  | gaveUp (reason : String)
  /-- It broke off, with `reason`, and made no request after that one: what
  it did so far is to stay. -/
  | brokeOff (reason : String)
  /-- It was about to edit the text of the buffer `buffer`, whose file at
  `path` changed on disk and the user was not told: the edit was not made,
  nor any request after it. `found` is the file's stamp now, `none` for a
  file that is gone. -/
  | superseded (buffer : BufferId) (path : System.FilePath) (found : Option File.Stamp)
  deriving BEq, Repr

/-- The text a request edits, for the requests the first-edit refusal looks
at: an insert, a delete, a transaction and an applied inverse. An edit
script is not among them, so a reload is never refused by it. -/
def TextRequest.edited? : TextRequest → Option TextId
  | .insert text .. | .delete text .. | .apply text .. | .applyInverse text .. => some text
  | _ => none

/-- What the loop is told of the registry for the state requests that name
something registered. A step is handed one, made from the registry as it
then is. -/
structure Loop.Registered where
  /-- The modes whose on-enter actions run when the mode of this name
  becomes a buffer's major mode: its lineage, root first. `none` for a name
  no mode is registered under. -/
  entering : String → Option (List Mode) := fun _ => none
  /-- Whether a job is registered under this name, for a command to
  start. -/
  jobs : String → Bool := fun _ => false
  /-- The ex binding of an ex name (`Editor/Ex/Line.lean`): the command it
  runs and what it takes. `none` for a name nobody bound. -/
  ex : String → Option Ex.Binding := fun _ => none
  /-- The ex names that are bound, each once. Whoever fills this and `ex`
  fills them from one list of bindings, so that every name here has a
  binding there. -/
  exNames : Array String := #[]
  /-- The names themes are registered under, each once, for the command
  that loads a theme: its candidates, and the names it may load. -/
  themeNames : Array String := #[]
  /-- The command registered under this name, as one run inside another is
  run: given the call, its program. `none` for a name no command is
  registered under. The loop fills it from the lookup a key's invocation
  goes through (`Loop.dispatch`), in place of what it is handed here. -/
  command : String → Option (Call → EditorM Unit) := fun _ => none
  /-- Whether config's setting turns auto-reload on (`autoReload`,
  `Editor/Setup.lean`): what decides while no command has chosen. -/
  autoReload : Bool := false
  /-- The workspace roots config declares (`workspace`, `Editor/Setup.lean`),
  which the finder is handed. -/
  workspaceRoots : Array Workspace.ConfigRoot := #[]
  /-- The config generation: how many configs have been installed. A
  directory's cached workspace is an answer only under the generation it
  was found under (`Editor/Workspace.lean`). -/
  generation : Nat := 0
  /-- Config's display rules (`displayRule`, `Editor/Setup.lean`), in
  order, as the install left them: each rule's target exists under the
  layout config chose. -/
  displayRules : Array DisplayRule := #[]
  /-- How long a `:!` or a filter may run, in milliseconds, as config set it
  (`shellTimeLimit`, `Editor/Setup.lean`); `none` for the shell's
  default. -/
  shellTimeLimit : Option Nat := none

/-- A program that ends at once, interrupted, with no state: what the
compiler is shown for `Program.dispatched`, which is `partial`. -/
instance {α : Type} : Inhabited (Program editorPort (Guarded α × EditorState)) :=
  ⟨.done (.interrupted, EditorState.none)⟩

/-- What runs when the mode `name`, of `lineage` (root first), has become
the major mode of a buffer over `text` whose old major mode said
`before` of how its text is parsed: the text highlighted with the new
lineage's syntax tree, or detached when only the old said one, then the
lineage's on-enter actions, root first, once with each of `views`. -/
def enteringMode (name : String) (text : TextId) (lineage : List Mode)
    (before : Option Mode.SyntaxTree) (views : List ViewId) : EditorM Unit := do
  match Mode.syntaxTreeOf lineage, before with
  | some syntaxTree, _ =>
    Highlight.enter name text syntaxTree
  | none, some _ =>
    Highlight.leave text
  | none, none =>
    pure ()
  for view in views do
    lineage.forM (·.onEnter view)

/-- `program`, a command's, with its state requests answered from `state`,
each from the state the one before left, and the interrupt flag asked
before each of its other requests: how the command ended, and the state it
left, or had reached when it was refused or when the flag was found up,
with that request and everything after it not made. A request to give up
ends the program there, with its reason and the state it had reached ("A
command that gives up", in the module docs), and so does a request to
break off ("A command that breaks off").

A request to set a major mode, of a view's buffer or of a buffer by its id,
is answered with what `registered` says of the mode ("Requests that name
something registered", in the module docs):
the on-enter actions it runs are put before the rest of the program. A
request to start a job and one for an ex binding are answered with what
`registered` says of the name, and for a request to run a command the
command `registered` has of the name is put before the rest of the
program. -/
partial def Program.dispatched {α : Type} (registered : Loop.Registered) :
    EditorState →
      Program editorPort (Except TextError α) → Program editorPort (Guarded α × EditorState)
  | state, .done (.ok value) => .done (.finished value, state)
  | state, .done (.error error) => .done (.refused error, state)
  | state, .step (.state (.setMajorMode view name)) next =>
    match state.target? view, registered.entering name with
    | none, _ => dispatched registered state (next (.error (.noSuchWindow view)))
    | some _, none => dispatched registered state (next (.error (.noSuchMode name)))
    | some target, some lineage =>
      let before := (target.buffer.major.bind registered.entering).bind Mode.syntaxTreeOf
      match state.handle (.setMajorMode view name) with
      | (.ok true, state) =>
        dispatched registered state do
          match ← (enteringMode name target.buffer.text lineage before [view]).run with
          | .ok () =>
            next (.ok true)
          | .error error =>
            pure (.error error)
      | (reply, state) => dispatched registered state (next reply)
  | state, .step (.state (.setBufferMajorMode id name)) next =>
    match state.buffer? id, registered.entering name with
    | none, _ => dispatched registered state (next (.error (.noSuchBuffer id)))
    | some _, none => dispatched registered state (next (.error (.noSuchMode name)))
    | some buffer, some lineage =>
      let before := (buffer.major.bind registered.entering).bind Mode.syntaxTreeOf
      let views := (state.windows.filter (·.buffer == id)).toList.map (·.id)
      match state.handle (.setBufferMajorMode id name) with
      | (.ok true, state) =>
        dispatched registered state do
          match ← (enteringMode name buffer.text lineage before views).run with
          | .ok () =>
            next (.ok true)
          | .error error =>
            pure (.error error)
      | (reply, state) => dispatched registered state (next reply)
  | state, .step (.state (.startJob name arguments key)) next =>
    if registered.jobs name then
      let (reply, state) := state.handle (.startJob name arguments key)
      dispatched registered state (next reply)
    else dispatched registered state (next (.error (.noSuchJob name)))
  | state, .step (.state (.ex name)) next => dispatched registered state (next (registered.ex name))
  | state, .step (.state .exNames) next => dispatched registered state (next registered.exNames)
  | state, .step (.state .themeNames) next =>
    dispatched registered state (next registered.themeNames)
  | state, .step (.state (.loadTheme name)) next =>
    if registered.themeNames.contains name then
      let (reply, state) := state.handle (.loadTheme name)
      dispatched registered state (next reply)
    else dispatched registered state (next (.error (.noSuchTheme name)))
  | state, .step (.state .autoReloadMode) next =>
    dispatched registered state (next (state.autoReload.getD registered.autoReload))
  | state, .step (.state .shellTimeLimit) next =>
    dispatched registered state (next registered.shellTimeLimit)
  | state, .step (.state .workspaceSettings) next =>
    dispatched registered state
      (next ({ roots := registered.workspaceRoots }, registered.generation))
  | state, .step (.state .displayRules) next =>
    dispatched registered state (next registered.displayRules)
  | state, .step (.state (.runCommand name call)) next =>
    match registered.command name with
    | none => dispatched registered state (next false)
    | some command =>
      dispatched registered state do
        match ← (command call).run with
        | .ok () =>
          next true
        | .error error =>
          pure (.error error)
  | state, .step (.state (.giveUp reason)) _ => .done (.gaveUp reason, state)
  | state, .step (.state (.breakOff reason)) _ => .done (.brokeOff reason, state)
  | state, .step (.state request) next =>
    let (reply, state) := state.handle request
    dispatched registered state (next reply)
  | state, .step request next =>
    .step (.watch .interrupted) fun (raised : Bool) =>
      if raised then .done (.interrupted, state)
      else
        -- An edit of a read-only buffer is not made ("Read-only buffers",
        -- in the module docs), and is looked at first.
        let readOnly :=
          match request with
          | .text text => text.edited?.bind state.readOnly?
          | _ => none
        -- The first edit of a buffer whose file changed on disk, which the
        -- user was not told of, is not made ("The first edit after a change
        -- on disk", in the module docs).
        let untold :=
          match request with
          | .text text => text.edited?.bind state.untold?
          | _ => none
        match readOnly, untold with
        | some (_, name), _ => .done (.gaveUp (EditorState.readOnlyReason name), state)
        | none, some (buffer, path, found) => .done (.superseded buffer path found, state)
        | none, none => .step request fun reply => dispatched registered state (next reply)

/-- `command` as the loop runs it from the editor state `state`: its state
requests answered in place, and stopped at its next other request once the
interrupt flag is up. It is not itself refused: how the command ended is
its value, with the editor state it left, or had reached when it was
refused or interrupted, gave up or broke off. -/
def EditorM.dispatched {α : Type} (command : EditorM α) (registered : Loop.Registered)
    (state : EditorState) : EditorM (Guarded α × EditorState) :=
  ExceptT.lift (command.run.dispatched registered state)

end Editor
