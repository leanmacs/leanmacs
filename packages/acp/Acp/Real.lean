import Acp.Service
import Editor.PackageLibrary

/-!
# The Rust-backed binding of the service `agents`

acp's library (`rust/src/ffi.rs`), through the package's glue
(`ffi/glue.c`), as `Acp.Binding`. This module is a library of its own,
`AcpReal`, whose `moreLinkObjs` is the glue, so every executable that
imports it links the glue. The crate is not linked: it is a library of its
own, which the package-set build stages beside every executable it links,
from the package's `editorLibrary` target, and records in
`<executable>.libraries`; this module's initialiser finds the library
there through the core's edge (`Editor.PackageLibrary.staged "acp" "acp"`)
and asks the glue to load it from there (docs/design/packages.md, "A
package's library, staged and loaded, as built"). So an installed editor
loads it from its own install, never from the package's source directory.
The package's test driver does not import it, so it links no glue and
needs no Rust.

**The load is a `builtin_initialize`.** It runs before `main` in each
executable that links this module natively (the set's editor, its fixture
harness and the package's linked test), and never when a module that
imports it is compiled or imported, as by the config elaborator at run
time, where the glue's symbols do not exist. The glue hands the core the
interface version it was compiled for (`interface`, the glue's
`ACP_INTERFACE`), and the core refuses a library that declares another, or
a newer runtime, before it calls anything of it. A refused load throws its
sentence, read back through the core's `Editor.PackageLibrary.LoadRefusal`
and naming acp (`loadLibrary`); Lean's generated `main` prints an
initialiser's error as `uncaught exception: <text>` and exits 1, which the
package-set build's probe reports in its failure line
(`Editor.Restore.probeFailure`). The linked test pins the load
(`AcpTest.Linked.acpLoadChecks`).

The library's load takes names of its own (`loadLibraryFrom`,
`loadLibraryExpecting`, `loadLibrary`; the glue's `acp_glue_load_library`),
since `load` is the session's load (`session/load`, the glue's
`acp_glue_load`), which forwards through the table's `load` entry.

A request's completion is posted by the library through the package
runtime on the editor's completion queue, with the request's id as its
code, so a request started under an id from the editor's table of waits
(`Editor.Job.Completions`) completes when the editor's pump ends that wait.
`Acp.Real.service` is the binding as the runner's package service
(`Acp.jobService`), which the package registers (`Acp/Packages.lean`).
-/

namespace Acp.Real

/-- The interface version the glue was compiled for, `ACP_INTERFACE`: the
shape of the table it mirrors, which the library declares too
(`package! { interface 1; … }`). -/
@[extern "acp_glue_interface"]
opaque interface : IO UInt32

/-- Asks the core to load the library at `path` for a glue of interface
`interface`, keeping its table in the glue when it loads, and answers the
core's status, 0 or a refusal, with the two numbers it wrote for a newer
runtime or another interface (`Editor.PackageLibrary.LoadRefusal.of?`). -/
@[extern "acp_glue_load_library"]
opaque loadLibraryFrom (path : @& String) (interface : UInt32) : IO (UInt32 × UInt64 × UInt64)

/-- Loads the library at `path` for a glue of interface `interface`, or
throws the refusal's sentence, naming acp: the initialiser's body with the
version a check can vary. -/
def loadLibraryExpecting (path : String) (interface : UInt32) : IO Unit := do
  let (status, first, second) ← loadLibraryFrom path interface
  if let some refusal := Editor.PackageLibrary.LoadRefusal.of? status first second then
    throw (IO.userError (refusal.describe "acp" path))

/-- Loads the library at `path` for the glue's own interface, or throws the
refusal's sentence: the body of the module's initialiser. -/
def loadLibrary (path : String) : IO Unit := do
  loadLibraryExpecting path (← interface)

/- Loads acp's library before `main`, from where the build staged it beside
the executable (the core's edge, `Editor.PackageLibrary.staged`, which
throws its sentence when none is staged), in an executable that links this
module natively, and never at an import (the module docs). -/
builtin_initialize
  loadLibrary (← Editor.PackageLibrary.staged "acp" "acp")

/-- Opens a session on the streaming child `child`, which a job opened in
the core's process service and the library takes over through the package
runtime alone, in `cwd`, with the MCP servers `servers` lists. -/
@[extern "acp_glue_open"]
opaque «open» (request child : UInt64) (cwd servers : @& String) : IO Bool

/-- Waits for the session `session`'s next events. -/
@[extern "acp_glue_next"]
opaque next (request session : UInt64) : IO Bool

/-- Sends the session `session` a prompt of `text`. -/
@[extern "acp_glue_prompt"]
opaque prompt (request session : UInt64) (text : @& String) : IO Bool

/-- Cancels the session `session`'s current turn. -/
@[extern "acp_glue_cancel_turn"]
opaque cancelTurn (request session : UInt64) : IO Bool

/-- Sets the session `session`'s mode to `mode`. -/
@[extern "acp_glue_set_mode"]
opaque setMode (request session : UInt64) (mode : @& String) : IO Bool

/-- Answers the session `session`'s parked permission request `ticket`
with `option`. -/
@[extern "acp_glue_answer"]
opaque answer (request session ticket : UInt64) (option : @& String) : IO Bool

/-- The text of the reply to `request`, once it has completed, taken once. -/
@[extern "acp_glue_take"]
opaque take (request : UInt64) : IO (Option String)

/-- Withdraws `request`: whether it was in use. -/
@[extern "acp_glue_withdraw"]
opaque withdraw (request : UInt64) : IO Bool

/-- Asks the library to complete `request` on the completion queue once every
open and order started before has completed or been withdrawn. -/
@[extern "acp_glue_flush"]
opaque flush (request : UInt64) : IO Unit

/-- Loads the session `sessionId` from the agent's own store on the
streaming child `child`, taken over as `open` takes one, in `cwd`, with the
MCP servers `servers` lists: the agent replays its history first. -/
@[extern "acp_glue_load"]
opaque load (request child : UInt64) (cwd servers sessionId : @& String) : IO Bool

/-- The library's table, through the glue, as the binding. -/
def real : Binding where
  «open» := «open»
  next := next
  prompt := prompt
  cancelTurn := cancelTurn
  setMode := setMode
  answer := answer
  take := take
  withdraw := withdraw
  flush := flush
  load := load

/-- The library's service as the job runner's package service, which the
package registers. -/
def service : Editor.PackageService :=
  Acp.jobService real

end Acp.Real
