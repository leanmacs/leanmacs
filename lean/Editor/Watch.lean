import Editor.Event
import Editor.Program

/-!
# The watch port

What the command loop watches while a command runs: whether the user has
asked for it to stop, and how long it has taken. It is a port like the
others (`Editor/Program.lean`): requests, a pure model
(`Editor/Watch/Model.lean`), a real binding (`Editor/Watch/Real.lean`) and a
contract both are held to (`Editor/Watch/Contract.lean`). It is the third
sub-port of the editor's port (`Editor/Command.lean`), so the loop asks it
from inside a pure program, and the same loop runs on the models and
against the library.

## The interrupt flag

The Rust library raises a flag as the interrupt key arrives, before the key
is queued (`crates/editor-ffi/src/interrupt.rs`). The flag is up while an
interrupt key that arrived has not been taken off the queue. The primitive
is the library's and the policy is here:

- **`interrupted`** asks whether the flag is up. The loop asks before each
  request of a command it dispatched that reaches the library
  (`Editor/Command/Dispatch.lean`, "The guard").
- **`lower`** says that an interrupt key was taken off the queue. The loop
  makes it for the events the library marked as interrupt keys, and for no
  other (`Loop.take`, `Editor/Loop.lean`). The flag is a count of such keys,
  so with two arrived it stays up through the first `lower`: a command for
  a key queued between them is still ahead of an interrupt key.
- **Which key** is `interruptKey`, `C-g`. A host tells the library when its
  loop starts.

Nothing here is refused, so a watch program is a `Program` with no error
(`WatchM`).

## The clock

`now` reads the job port's clock, in milliseconds, so that a test moves one
clock for the jobs and for the loop. The loop reads it round a command to
log a slow one. It is here, and not a sub-port of its own, because a
sub-port costs a constructor, an embedding and two runner cases.

## Where an addition goes

| Addition | Where |
|---|---|
| Something else the loop watches while a command runs | A constructor of `WatchRequest`, its case in `WatchRequest.Reply`, an operation here, its case in the model and in the real binding, and a property of the contract |
| What the loop does with an answer | `Editor/Loop.lean`; nothing here |
| Another interrupt key | `interruptKey`; changing it from config is not built |

Pinned by the contract, which `model-test` runs against the model and
`contract-test` against the real binding.
-/

namespace Editor

/-- What the loop may ask of what it watches. -/
inductive WatchRequest where
  /-- Whether the interrupt flag is up: an interrupt key has arrived and
  has not been taken off the queue. -/
  | interrupted
  /-- An interrupt key was taken off the queue: one fewer holds the flag
  up. With none arrived, nothing. -/
  | lower
  /-- The clock's reading, in milliseconds: the job port's clock. -/
  | now
  deriving DecidableEq, Repr

/-- The type of the reply to each request. -/
def WatchRequest.Reply : WatchRequest → Type
  | .interrupted => Bool
  | .lower => Unit
  | .now => Nat

/-- The watch port: `WatchRequest` and the reply to each request. -/
abbrev watchPort : Port :=
  { Request := WatchRequest, Reply := WatchRequest.Reply }

/-- A program over the watch port. None of its requests is refused. -/
abbrev WatchM :=
  Program watchPort

/-- An answerer of the watch port's requests in `IO`: the real binding, or
`Watch.idle` where nothing is watched. A runner of commands is handed one. -/
abbrev WatchHandler :=
  (request : WatchRequest) → IO request.Reply

namespace Watch

/-- Whether the interrupt flag is up. Asking does not lower it. -/
def interrupted : WatchM Bool :=
  Program.request (port := watchPort) .interrupted

/-- Says that an interrupt key was taken off the queue: one fewer holds the
flag up. -/
def lower : WatchM Unit :=
  Program.request (port := watchPort) .lower

/-- The clock's reading, in milliseconds. -/
def now : WatchM Nat :=
  Program.request (port := watchPort) .now

/-- The handler that watches nothing: the flag is never up, lowering does
nothing and the clock reads 0. It is what a command is run against where no
loop dispatched it. -/
def idle : WatchHandler
  | .interrupted => pure false
  | .lower => pure ()
  | .now => pure (0 : Nat)

/-- The interrupt key: `C-g`, as a chord. -/
def interruptKey : Key :=
  { logical := .character "g", modifiers := { control := true } }

end Watch

end Editor
