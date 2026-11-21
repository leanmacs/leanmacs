import Editor.Extension

/-!
# The interface library `buffers-api`

The interface library `buffers-api`, staged in the core's Lake package as
its own `lean_lib` with the layout and names it will have as the package
`packages/buffers-api/` (`lean/lakefile.lean`, `lean_lib BuffersApi`): the
contract between the buffer commands (`packages/buffers/Buffers.lean`), which
implement it, and what others ask of closing a buffer. It imports only the
core's API, and its test library (`BuffersApiTest`) only that, this
library and the core's test kit.

## Its extension points

- **`Closing`, a hook**: every value, in order, is run (`runClosing`) when
  a buffer is about to close, after the core's `Jumps.detach` and before any
  window is switched off it and it is removed. The working sets detach the
  ranges it holds and free the drifted quotes of a set's buffer here.
- **`Buffers`, a choice** under `implementationName`, `buffers`, read with
  `buffers?`: what the buffer commands do for others, `close` (every window
  that showed the buffer shows another, and it is removed). The latest value
  of the name wins. With none a caller says so.

## Its names

`switch-buffer`, `list-buffers` and `close-buffer` (`names`), which the ex
names `b`, `ls` and `bd` and the default config reach.

Its test library publishes a fake (`BuffersApiTest.fake`, a close written
over the core's API) and the contract check every implementation runs
(`BuffersApiTest.contractChecks`).
-/

namespace BuffersApi

open Editor

/-- What is run when a buffer is about to close: a hook. -/
structure Closing where
  /-- The value's name. -/
  name : String
  /-- Run with the buffer, while it is still there. -/
  closing : BufferId → EditorM Unit
  deriving TypeName

/-- What the buffer commands do for others: a choice, under
`implementationName`. -/
structure Buffers where
  /-- The value's name. -/
  name : String
  /-- Closes the buffer, whatever it holds: every window that showed it
  shows another, and it is removed. -/
  close : BufferId → EditorM Unit
  deriving TypeName

/-- The name the buffer commands register their `Buffers` value under. -/
def implementationName : String :=
  "buffers"

/-- Runs every `Closing` value, in registration order, with `id`. -/
def runClosing (id : BufferId) : EditorM Unit := do
  for value in ← Extension.values Closing do
    value.closing id

/-- The `Buffers` value of the implementation's name, the latest registered;
`none` when there is none. -/
def buffers? : EditorM (Option Buffers) :=
  Extension.named Buffers (·.name) implementationName

/-- What a caller named `name` says when there is no `Buffers` value. -/
def noImplementation (name : String) : String :=
  s!"{name}: no buffers implementation"

/-- The name of the command that shows another buffer in a window. -/
def switchName : String :=
  "switch-buffer"

/-- The name of the command that lists the open buffers. -/
def listName : String :=
  "list-buffers"

/-- The name of the command that closes a buffer. -/
def closeName : String :=
  "close-buffer"

/-- Every command name this interface declares, in the order the buffer
commands register them. -/
def names : Array String :=
  #[switchName, listName, closeName]

end BuffersApi
