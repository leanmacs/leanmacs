import Acp.Service

/-!
# The Rust-backed binding of the service `agents`

The crate's C functions (`rust/src/ffi.rs`), through the package's glue
(`ffi/glue.c`), as `Acp.Binding`. This module is a library of its own,
`AcpReal`, whose `moreLinkObjs` is the glue, so every executable that
imports it links the glue, and the glue's `acp_ffi_*` symbols must be in
the Rust archive the executable links: the one the package-set build
generates from the set, which holds the crate (docs/design/packages.md,
"Rust in a package"). The package's test driver does not import it, so it
links no glue and needs no Rust.

A request's completion is posted by the crate on the editor's completion
queue, with the request's id as its code, so a request started under an id
from the editor's table of waits (`Editor.Job.Completions`) completes when
the editor's pump ends that wait. `Acp.Real.service` is the binding as the
runner's package service (`Acp.jobService`), which the package registers
(`Acp/Packages.lean`).
-/

namespace Acp.Real

/-- Opens a session on the streaming child `child`, which a job opened in
the core's process service and the crate takes over through
`editor-service` alone, in `cwd`, with the MCP servers `servers` lists. -/
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

/-- Asks the crate to complete `request` on the completion queue once every
open and order started before has completed or been withdrawn. -/
@[extern "acp_glue_flush"]
opaque flush (request : UInt64) : IO Unit

/-- Loads the session `sessionId` from the agent's own store on the
streaming child `child`, taken over as `open` takes one, in `cwd`, with the
MCP servers `servers` lists: the agent replays its history first. -/
@[extern "acp_glue_load"]
opaque load (request child : UInt64) (cwd servers sessionId : @& String) : IO Bool

/-- The crate's C functions as the binding. -/
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

/-- The crate's service as the job runner's package service, which the
package registers. -/
def service : Editor.PackageService :=
  Acp.jobService real

end Acp.Real
