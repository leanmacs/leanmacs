import Editor.Command.Guard

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

`Loop.Registered` is what the transformation is told of the registry, for
the requests that name something registered. It is rebuilt by the loop's
caller for each step, with the keymaps (`Loop.Keys`).

It is a pure transformation of the program, so it runs on the models as it
runs against the library.

Pinned by `ModelTest.dispatchStateChecks`; `EditorM.guarded` stays, pinned
by `ModelTest.guardChecks`.
-/

namespace Editor

/-- What the loop is told of the registry for the state requests that name
something registered. A step is handed one, made from the registry as it
then is. -/
structure Loop.Registered where

/-- `program` with its state requests answered from `state`, each from the
state the one before left, and the interrupt flag asked before each of its
other requests: the program's value and the state it left, or `none`, with
that request and everything after it not made, and the state it had
reached, once the flag is up. -/
def Program.dispatched {α : Type} (registered : Loop.Registered) :
    EditorState → Program editorPort α → Program editorPort (Option α × EditorState)
  | state, .done value => .done (some value, state)
  | state, .step (.state request) next =>
    let (reply, state) := state.handle request
    dispatched registered state (next reply)
  | state, .step request next =>
    .step (.watch .interrupted) fun (raised : Bool) =>
      if raised then .done (none, state)
      else .step request fun reply => dispatched registered state (next reply)

/-- `command` as the loop runs it from the editor state `state`: its state
requests answered in place, and stopped at its next other request once the
interrupt flag is up. It is not itself refused: how the command ended is
its value, with the editor state it left, or had reached when it was
refused or interrupted. -/
def EditorM.dispatched {α : Type} (command : EditorM α) (registered : Loop.Registered)
    (state : EditorState) : EditorM (Guarded α × EditorState) :=
  ExceptT.lift do
    match ← command.run.dispatched registered state with
    | (none, state) =>
      return (.interrupted, state)
    | (some (.ok value), state) =>
      return (.finished value, state)
    | (some (.error error), state) =>
      return (.refused error, state)

end Editor
