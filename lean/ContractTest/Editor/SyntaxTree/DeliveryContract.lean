import ContractTest.Check
import Editor.Ffi.Document
import Editor.Ffi.Snapshot
import Editor.Ffi.Syntax
import Editor.SyntaxTree.DeliveryContract
import Editor.SyntaxTree.Real
import Editor.Text.Real

/-!
# Contract tests: `Editor/SyntaxTree/DeliveryContract.lean`

The contract of the syntax service's deliveries run over the real binding
(`RealSyntaxTree`) on the library's syntax service: `syntaxDeliveryChecks`,
one check per property, each over documents and a table of snapshots of
its own. A text is a library document, an edit a replace of it and a new
snapshot of it in the table, and `settle` waits on `Ffi.syntaxSettle` of
the check's own snapshot, its own document's delivery. No property
highlights a text, so nothing is posted to the library's editor queue. The
root module `ContractTest` runs them.
-/

namespace ContractTest

open Editor

/-- A rig over the real binding, documents and a table of its own. -/
def deliveryRealRig : IO SyntaxDeliveryContract.DeliveryRig := do
  let table ← Snapshots.new
  -- The documents, kept alive with their texts: a document freed detaches
  -- its text.
  let documents ← IO.mkRef (#[] : Array (SnapshotId × Ffi.Document × String))
  let real ← RealSyntaxTree.new table.reader
  let add (document : Ffi.Document) (contents : String) : IO SnapshotId := do
    let id ← table.add (← document.snapshot)
    documents.modify (·.push (id, document, contents))
    return id
  return {
      name := "the real binding over the library's syntax service"
      -- The handler holds the documents: a document is freed after its last
      -- use, and a document freed detaches its text, so each question keeps
      -- them alive up to its answer.
      handler := fun request => do
        let reply ← real.handle request
        discard <| documents.get
        return reply
      make := fun contents => do add (← Ffi.Document.new contents) contents
      edit := fun snapshot contents => do
        let some (_, document, old) := (← documents.get).find? (·.1 == snapshot) |
          throw <| IO.userError "no such text"
        discard <| document.replace 0 old.utf8ByteSize.toUSize contents
        add document contents
      settle := fun snapshot => do
        let some found ← table.find? snapshot | return false
        Ffi.syntaxSettle found Ffi.treeGuard }

/-- The contract of the deliveries over the real binding. -/
def syntaxDeliveryChecks : List Check :=
  SyntaxDeliveryContract.properties.map fun property =>
    { name := s!"the real syntax tree binding keeps the delivery contract: {property.name}"
      run := do property.holds (← deliveryRealRig) }

end ContractTest
