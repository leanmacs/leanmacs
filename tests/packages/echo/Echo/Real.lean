import Echo
import Echo.Job
import Editor.PackageLibrary

/-!
# The Rust-backed binding of the echo port

The port (`Echo.lean`) over the package's crate (`rust/`), through the
package's glue (`ffi/glue.c`). This module is a library of its own,
`EchoReal`, whose `moreLinkObjs` is the glue, so every executable that
imports it links the glue. The crate is not linked: it is a library of its
own, which the package-set build stages beside every executable it links,
from the package's `editorLibrary` target, and records in
`<executable>.libraries`; this module's initialiser finds the library
there through the core's edge (`Editor.PackageLibrary.staged "echo"
"echo"`) and asks the glue to load it from there (docs/design/packages.md, "A
package's library, staged and loaded, as built"). So an installed editor
loads it from its own install, never from the package's source
directory. The package's test driver does not import it, so it links no
glue and needs no Rust.

**The load is a `builtin_initialize`.** It runs before `main` in each
executable that links this module natively (the set's editor, its fixture
harness and the package's linked test), and never when a module that
imports it is compiled or imported, as by the config elaborator at run
time, where the glue's symbols do not exist: a plain `initialize` would
run there. The glue hands the core the interface version it was compiled
for (`interface`, the glue's `ECHO_INTERFACE`), and the core refuses a
library that declares another, or a newer runtime, before it calls
anything of it. A refused load throws its sentence, read back through the
core's `Editor.PackageLibrary.LoadRefusal` and naming echo (`load`); Lean's generated `main` prints an initialiser's error as
`uncaught exception: <text>` and exits 1, which the package-set build's
probe reports in its failure line (`Editor.Restore.probeFailure`). That an
initialiser's error ends the program so is Lean's own `main`; the linked
test pins the rest (`EchoTest.Linked.echoLoadChecks`).

A request's completion is posted by the crate's service on the editor's
completion queue, with the request's id as its code, so a request started
under an id from the editor's table of waits (`Editor.Job.Completions`)
completes when the editor's pump ends that wait. `Echo.Real.service` is
that port as the job runner's package service (`Echo.jobService`), which
the package registers (`Echo/Packages.lean`).
-/

namespace Echo.Real

/-- The interface version the glue was compiled for, `ECHO_INTERFACE`: the
shape of the table it mirrors, which the library declares too
(`package! { interface 1; … }`). -/
@[extern "echo_glue_interface"]
opaque interface : IO UInt32

/-- Asks the core to load the library at `path` for a glue of interface
`interface`, keeping its table in the glue when it loads, and answers the
core's status, 0 or a refusal, with the two numbers it wrote for a newer
runtime or another interface (`Editor.PackageLibrary.LoadRefusal.of?`). -/
@[extern "echo_glue_load"]
opaque loadFrom (path : @& String) (interface : UInt32) : IO (UInt32 × UInt64 × UInt64)

/-- Loads the library at `path` for a glue of interface `interface`, or
throws the refusal's sentence, naming echo: the initialiser's body with the
version a check can vary. -/
def loadExpecting (path : String) (interface : UInt32) : IO Unit := do
  let (status, first, second) ← loadFrom path interface
  if let some refusal := Editor.PackageLibrary.LoadRefusal.of? status first second then
    throw (IO.userError (refusal.describe "echo" path))

/-- Loads the library at `path` for the glue's own interface, or throws the
refusal's sentence: the body of the module's initialiser. -/
def load (path : String) : IO Unit := do
  loadExpecting path (← interface)

/- Loads echo's library before `main`, from where the build staged it
beside the executable (the core's edge, `Editor.PackageLibrary.staged`,
which throws its sentence when none is staged), in an executable that
links this module natively, and never at an import (the module docs). -/
builtin_initialize
  load (← Editor.PackageLibrary.staged "echo" "echo")

/-- Starts the request `id` of `text` in the crate's service. -/
@[extern "echo_glue_start"]
opaque start (id : UInt64) (text : @& String) : IO Bool

/-- Cancels the request `id` in the crate's service. -/
@[extern "echo_glue_cancel"]
opaque cancel (id : UInt64) : IO Bool

/-- The text of the reply to the request `id`, and the CRC-32 the crate
took of it, taken from the crate's service. -/
@[extern "echo_glue_take"]
opaque takeRaw (id : UInt64) : IO (Option (String × UInt32))

/-- Hands the streaming child `child`, which a job opened in the core's
process service, to the library, which takes it over through the package
runtime alone, reads it in Rust as the request `request` of its service, and
completes `request` once the child has ended or was cancelled. False when
the take-over is refused or `request` is in use. -/
@[extern "echo_glue_attach"]
opaque attach (request child : UInt64) : IO Bool

/-- What the attached request `request` read, once: the child's lines and a
last line that says how it ended or that it was cancelled, joined by line
feeds, and how many pulls it took. -/
@[extern "echo_glue_attach_take"]
opaque attachTakeRaw (request : UInt64) : IO (Option (String × UInt32))

/-- Asks the crate's service to complete `id` on the completion queue once
every echo request started before has completed or been cancelled. -/
@[extern "echo_glue_flush"]
opaque flush (id : UInt64) : IO Unit

/-- The port over the crate's service. Its replies' checksums are the
crate's, so the contract holds the crate's CRC-32 to the pure one
(`Echo.checksum`). -/
def real : Service where
  start := start
  cancel := cancel
  take id := return (← takeRaw id).map fun (text, checksum) => { text, checksum }
  attach := attach
  attachTake id := return (← attachTakeRaw id).map fun (text, pulls) => { text, pulls }
  flush := flush

/-- The crate's service as the job runner's package service, which the
package registers: echo's port over the binding (`Echo.jobService`). -/
def service : Editor.PackageService :=
  Echo.jobService real

end Echo.Real
