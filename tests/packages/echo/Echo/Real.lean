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

/-- The text of the reply to the request `id`, and the checksum the crate
took of it from the system's zlib, taken from the crate's service. -/
@[extern "echo_glue_take"]
opaque takeRaw (id : UInt64) : IO (Option (String × UInt32))

/-- Hands the streaming child `child`, which a job opened in the core's
process service, to the crate, which takes it over through `editor-service`
alone, reads it in Rust as the request `request` of its service, and
completes `request` once the child has ended or was cancelled. False when
the take-over is refused or `request` is in use. -/
@[extern "echo_glue_attach"]
opaque attach (request child : UInt64) : IO Bool

/-- What the attached request `request` read, once: the child's lines and a
last line that says how it ended or that it was cancelled, joined by line
feeds, and how many pulls it took. -/
@[extern "echo_glue_attach_take"]
opaque attachTake (request : UInt64) : IO (Option (String × UInt32))

/-- The port over the crate's service. Its replies' checksums are the
crate's, so the contract holds zlib's CRC-32 to the pure one
(`Echo.checksum`). -/
def real : Service where
  start := start
  cancel := cancel
  take id := return (← takeRaw id).map fun (text, checksum) => { text, checksum }

end Echo.Real
