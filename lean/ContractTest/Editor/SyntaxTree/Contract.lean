import ContractTest.Support.Syntax
import Editor.Ffi.Document
import Editor.SyntaxTree
import Editor.SyntaxTree.Contract
import Editor.Text
import Editor.Text.Real

/-!
# Contract tests: `Editor/SyntaxTree/Contract.lean`

The tests of `Editor/SyntaxTree/Contract.lean`: `syntaxTreeFailures`, the syntax
tree interface's contract against the real binding. The root module
`ContractTest` runs them; its module doc says what each shows.
-/

namespace ContractTest

open Editor

/-- Runs `property` of the syntax tree interface's contract against the real
binding, over documents of its texts. -/
def runOnRealSyntaxTree (property : SyntaxTreeContract.Property) : IO Bool := do
  let (documents, _, ids, handler) ← syntaxTreeOver property.texts
  let result ← (property.holds ids).runWith handler
  -- The documents are read here, so they are alive for the whole run.
  for document in documents do
    discard document.read
  return result matches .ok true

/-- The names of the syntax tree interface's contract properties that do not
hold of its real binding. -/
def syntaxTreeFailures : IO (List String) := do
  let failed ← SyntaxTreeContract.failures runOnRealSyntaxTree SyntaxTreeContract.properties
  return failed.map (s!"the real syntax tree binding: {·}")

end ContractTest
