import Echo

/-!
# The Rust-backed binding of the echo port

The port (`Echo.lean`) over the package's crate (`rust/`), through the
package's glue (`ffi/glue.c`). This module is a library of its own,
`EchoReal`, whose `moreLinkObjs` is the glue, so every executable that
imports it links the glue, and the glue's `echo_ffi_*` symbols must be in
the Rust archive the executable links: the one the package-set build
generates from the set, which holds the crate (docs/design/packages.md,
"Rust in a package"). The package's test driver does not import it, so it
links no glue and needs no Rust.

A request's completion is posted by the crate's service on the editor's
completion queue, with the request's id as its code, so a request started
under an id from the editor's table of waits (`Editor.Job.Completions`)
completes when the editor's pump ends that wait.
-/

namespace Echo.Real

/-- Starts the request `id` of `text` in the crate's service. -/
@[extern "echo_glue_start"]
opaque start (id : UInt64) (text : @& String) : IO Bool

/-- Cancels the request `id` in the crate's service. -/
@[extern "echo_glue_cancel"]
opaque cancel (id : UInt64) : IO Bool

/-- The text of the reply to the request `id`, taken from the crate's
service. -/
@[extern "echo_glue_take"]
opaque takeText (id : UInt64) : IO (Option String)

/-- The port over the crate's service. -/
def real : Service where
  start := start
  cancel := cancel
  take id := return (← takeText id).map Reply.to

end Echo.Real
