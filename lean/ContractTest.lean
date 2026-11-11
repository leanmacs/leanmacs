import Editor.Text.Contract
import Editor.Text.Real

/-!
# The contract check against the real binding

The `contract-test` executable runs the text port's contract
(`Editor/Text/Contract.lean`) against the port's real binding
(`Editor/Text/Real.lean`), so against the Rust library: it is linked like
`editor`, with the glue object and the Rust archive. `model-test` runs the
same list against the pure model. A property that holds of one and not of the
other fails one of the two, which is what keeps the model from drifting from
the library.

`mise run ffi-test` runs it, in the gate. It names the properties that did not
hold and exits non-zero if there are any.
-/

namespace ContractTest

open Editor

/-- What must hold of the binding's table of texts once the contract has run.
It is not a property of the port, which has no way to say it: it is about the
library's objects, which only the real binding has. -/
def tableName : String :=
  "the real binding's table is the only holder of its documents: they are all freed when it is dropped"

/-- Runs `properties` against the real binding, each from a table with no
texts, and returns the names of those that did not hold. Each table is dropped
with its run, so the count of live documents must then be what it was before:
if it is not, `tableName` is among the names. -/
def failures (properties : List TextContract.Property) : IO (List String) := do
  let before ← Ffi.Document.live
  let failed ← TextContract.failures (fun command => return (← command.runReal #[]).1) properties
  let after ← Ffi.Document.live
  return if after == before then failed
    else failed ++ [s!"{tableName} ({before} before, {after} after)"]

end ContractTest

/-- Runs the text port's contract against the real binding: exits 0 when every
property holds, and 1 after naming on stderr the ones that do not. -/
def main : IO UInt32 := do
  let properties := Editor.TextContract.properties
  let failed ← ContractTest.failures properties
  for name in failed do
    IO.eprintln s!"FAILED: the real text binding: {name}"
  unless failed.isEmpty do
    return 1
  IO.println
      s!"contract-test: {properties.length} properties hold of the real text binding, and its documents are freed with its table"
  return 0
