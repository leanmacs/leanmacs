import Editor.Clipboard
import Editor.Ffi

/-!
# The clipboard interface's real binding

The handler of the clipboard interface's requests (`Editor/Clipboard.lean`)
over a clipboard the Rust library holds (`Editor.Ffi.Clipboard`): the
library's memory clipboard, or the desktop's. A read answers the text held,
or `none`; a write replaces it. A failure of the library's clipboard port,
for a read or a write, is answered `unavailable`, which is the interface's
meaning for "the clipboard could not be reached", with nothing changed; the
library's reason is not part of the interface.

Only the window mode opens the desktop's clipboard (`Real.system`). A host
that cannot is handed `Clipboard.unavailable` instead, and says why once.

This module is imported by the window mode and the contract checks, never
by `Editor`, as the other real bindings are kept out of the model tests'
reach.

`contract-test` holds it to the interface's contract
(`Editor/Clipboard/Contract.lean`) over the library's memory clipboard
(`ContractTest.realClipboardFailures`), so the gate reads and writes no
desktop's clipboard. The desktop's own is held to the Rust port's contract
on demand (`mise run clipboard-contract`, `mise run linux-window`).
-/

namespace Editor.Clipboard

/-- A clipboard of the library's, answered through the interface. -/
structure Real where
  /-- The library's clipboard. -/
  clipboard : Ffi.Clipboard

namespace Real

/-- A binding over a new memory clipboard of the library's, which holds
nothing. -/
def memory : IO Real :=
  return { clipboard := ← Ffi.Clipboard.memory }

/-- A binding over the desktop's clipboard, or the library's reason it
cannot be reached. -/
def system : IO (Except String Real) := do
  return (← Ffi.Clipboard.system).map ({ clipboard := · })

/-- Answers `request` through the library: what is read, or that it was
written; a failure either way is `unavailable`. -/
def handle (real : Real) : ClipboardHandler := fun request =>
  match request with
  | .read => do
    return match ← real.clipboard.read with
      | .ok text => .ok text
      | .error _ => .error .unavailable
  | .write text => do
    return match ← real.clipboard.write text with
      | none => .ok ()
      | some _ => .error .unavailable

end Real

end Editor.Clipboard
