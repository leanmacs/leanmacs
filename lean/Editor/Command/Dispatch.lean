import Editor.Command.Guard
import Editor.Mode

/-!
# A dispatched command

How the command loop runs a command: `EditorM.dispatched`. It is the guard
(`Editor/Command/Guard.lean`) and one thing more: the command's state
requests (`Editor/State/Request.lean`) are answered here, from the editor
state the loop hands in, and what comes back is how the command ended and
the state it left.

## The rules

- **A state request is answered in place.** The transformation holds the
  editor state, answers each state request of the command with the
  requests' pure handler (`EditorState.handle`) and goes on with the state
  after it. No state request is left in the program it returns, so none
  reaches a runner, and the handler is the same function on the models and
  against the library by construction.
- **The state comes back however the command ended**: finished, refused or
  interrupted. A rollback needs the undo trees the command left
  (`Editor/Loop.lean`, "Rollback"), so the state a refused or interrupted
  command had reached is handed back with how it ended, and the loop decides
  what to keep of it.
- **Every other request is guarded** as `EditorM.guarded` guards it: the
  interrupt flag is asked before it, and once the flag is up the command
  makes no further request.
- **A state request is not guarded.** It is pure Lean, not a call into the
  library, and what the guard bounds is the requests that reach the library
  (`docs/design/concurrency.md`, "When it is asked"). It also keeps a move
  in the history whole towards the guard: the last text request of an undo
  drops the inverses it crossed, and the request after it is the state
  request that records the moved tree. A check between the two could stop a
  command with the inverses dropped and the move unrecorded, which no
  rollback could then take back. A check before the drop stops it with
  nothing dropped.
- **Only the command is dispatched.** The loop's own requests round it are
  neither guarded nor answered here.

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
  state as it was. Otherwise the start is kept in the state, for the loop
  to hand to its host once the command has run to its end
  (`Editor/Loop.lean`, "Jobs from commands").

Putting an action's program before the rest of the command makes the
transformation recurse into a program that is no part of the one it was
given, so it is `partial`, and no theorem is about it. On-enter actions
that set each other's major modes for ever are runaway config code, which
nothing here stops (`docs/design/concurrency.md`, "Runaway code is not a
design driver").

It is a pure transformation of the program, so it runs on the models as it
runs against the library.

Pinned by `ModelTest.dispatchStateChecks` and `ModelTest.modeEnterChecks`;
`EditorM.guarded` stays, pinned by `ModelTest.guardChecks`.
-/

namespace Editor

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

/-- A program that ends at once, interrupted, with no state: what the
compiler is shown for `Program.dispatched`, which is `partial`. -/
instance {α : Type} : Inhabited (Program editorPort (Guarded α × EditorState)) :=
  ⟨.done (.interrupted, EditorState.none)⟩

/-- `program`, a command's, with its state requests answered from `state`,
each from the state the one before left, and the interrupt flag asked
before each of its other requests: how the command ended, and the state it
left, or had reached when it was refused or when the flag was found up,
with that request and everything after it not made.

A request to set a major mode is answered with what `registered` says of
the mode ("Requests that name something registered", in the module docs):
the on-enter actions it runs are put before the rest of the program. -/
partial def Program.dispatched {α : Type} (registered : Loop.Registered) :
    EditorState →
      Program editorPort (Except TextError α) → Program editorPort (Guarded α × EditorState)
  | state, .done (.ok value) => .done (.finished value, state)
  | state, .done (.error error) => .done (.refused error, state)
  | state, .step (.state (.setMajorMode view name)) next =>
    match state.target? view, registered.entering name with
    | none, _ => dispatched registered state (next (.error (.noSuchWindow view)))
    | some _, none => dispatched registered state (next (.error (.noSuchMode name)))
    | some _, some lineage =>
      match state.handle (.setMajorMode view name) with
      | (.ok true, state) =>
        let entering : EditorM Unit := lineage.forM (·.onEnter view)
        dispatched registered state do
          match ← entering.run with
          | .ok () =>
            next (.ok true)
          | .error error =>
            pure (.error error)
      | (reply, state) => dispatched registered state (next reply)
  | state, .step (.state (.startJob name arguments)) next =>
    if registered.jobs name then
      let (reply, state) := state.handle (.startJob name arguments)
      dispatched registered state (next reply)
    else dispatched registered state (next (.error (.noSuchJob name)))
  | state, .step (.state request) next =>
    let (reply, state) := state.handle request
    dispatched registered state (next reply)
  | state, .step request next =>
    .step (.watch .interrupted) fun (raised : Bool) =>
      if raised then .done (.interrupted, state)
      else .step request fun reply => dispatched registered state (next reply)

/-- `command` as the loop runs it from the editor state `state`: its state
requests answered in place, and stopped at its next other request once the
interrupt flag is up. It is not itself refused: how the command ended is
its value, with the editor state it left, or had reached when it was
refused or interrupted. -/
def EditorM.dispatched {α : Type} (command : EditorM α) (registered : Loop.Registered)
    (state : EditorState) : EditorM (Guarded α × EditorState) :=
  ExceptT.lift (command.run.dispatched registered state)

end Editor
