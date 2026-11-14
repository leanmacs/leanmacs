import Editor.Command

/-!
# A guarded command

How the command loop runs a command it dispatched, so that the user can
stop it: `EditorM.guarded`. A guarded command asks the watch port's
interrupt flag (`Editor/Watch.lean`) before each of its requests, and once
the flag is up it makes no further request.

## The rules

- **A command stops at its next request.** `Program.interruptible` puts one
  question, whether the flag is up, before each request of a program. When
  the answer is yes the program is finished there: the request is not made,
  and the continuation is not applied.
- **A command cannot catch an interrupt.** Being interrupted is not a reply
  to the command's request and nothing is thrown: the rest of the command is
  dropped, as the job runner drops a cancelled job's
  (`docs/design/concurrency.md`, "Cancellation"). So a `try`/`catch` round a
  request does not go on. What a command made before it stopped is the
  loop's to roll back.
- **A guarded command is not refused.** How it ended is its value
  (`Guarded`): it finished, it was refused, or it was interrupted. So the
  loop that runs it goes on to roll back and to publish whichever it was.
- **Only the command is guarded.** The transformation is applied to the
  command alone. The loop's own requests round it are not checked, so a flag
  that is up never stops a rollback or a scene.
- **A command that makes no request is not interruptible**: there is no
  request to stop it at. That is accepted (`docs/design/concurrency.md`,
  "Runaway code is not a design driver").
- **The flag is only asked, never lowered, here.** It comes down when the
  loop takes the interrupt key off the queue (`Loop.take`).

It is a pure transformation of the program, so it runs on the models as it
runs against the library. It costs one request of the watch port, a call
into the library, for each request of the command.

Pinned by `ModelTest.guardChecks`.
-/

namespace Editor

/-- How a guarded command ended. -/
inductive Guarded (α : Type) where
  /-- It ran to its end, with `value`. -/
  | finished (value : α)
  /-- It was refused, with `error`. -/
  | refused (error : TextError)
  /-- The interrupt flag was up before one of its requests, which it did not
  make, nor any after. -/
  | interrupted
  deriving BEq, Repr

/-- `program` with the interrupt flag asked before each of its requests:
`none`, with the request and everything after it not made, once the flag is
up, and the program's value otherwise. -/
def Program.interruptible {α : Type} : Program editorPort α → Program editorPort (Option α)
  | .done value => .done (some value)
  | .step request next =>
    .step (.watch .interrupted) fun (raised : Bool) =>
      if raised then .done none else .step request fun reply => interruptible (next reply)

/-- `command`, stopped at its next request once the interrupt flag is up. It
is not itself refused: how the command ended is its value. -/
def EditorM.guarded {α : Type} (command : EditorM α) : EditorM (Guarded α) :=
  ExceptT.lift do
    match ← command.run.interruptible with
    | none =>
      return .interrupted
    | some (.ok value) =>
      return .finished value
    | some (.error error) =>
      return .refused error

end Editor
