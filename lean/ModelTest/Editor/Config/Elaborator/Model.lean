import Editor.Config.Elaborator.Contract
import Editor.Config.Elaborator.Model
import Editor.Config.Session
import ModelTest.Check
import ModelTest.Support.Elaborator

/-!
# Model tests: `Editor/Config/Elaborator/Model.lean`

The model tests of `Editor/Config/Elaborator/Model.lean`:
`elaboratorContractChecks`, the port's contract held of the model, and
`elaboratorModelChecks`, what only the model has. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Config

/-- The elaborator port's contract (`Editor/Config/Elaborator/Contract.lean`)
held of the model (`modelSubject`): each property as a check. -/
def elaboratorContractChecks : List Check :=
  (Elaborator.Contract.properties modelSubject).map fun property =>
    { name := s!"the elaborator's model: {property.name}", run := property.holds }

/-- The checks of what only the elaborator's model has
(`Editor/Config/Elaborator/Model.lean`): the edges of its language, and a
base that is asked to hold a module that is not linked. -/
def elaboratorModelChecks : List Check :=
  let model := Elaborator.Model.elaborator
  let file (text : String) : SourceFile := { module := "Config.A", path := "Config/A.lean", text }
  [{  name :=
        "an import after another line is no part of the header, and is an error at its line when the file is elaborated"
      run := do
        let source := file "import Lean\ndefine made\nimport Std"
        let found ← model.imports source
        let result ← model.file (← model.base none #[]) #[] source
        return (found.toOption.map (·.map (·.module))) == some #["Lean"] && result.handle.isNone &&
            result.diagnostics.map (fun diagnostic => (diagnostic.line, diagnostic.severity)) ==
              #[(3, .error)] },
    { name := "a blank line is nothing, before the header's imports and after them"
      run := do
        let source := file "\nimport Lean\n\ndefine made\n"
        let found ← model.imports source
        let result ← model.file (← model.base none #[]) #[] source
        return (found.toOption.map (·.map fun wanted => (wanted.module, wanted.line))) ==
              some #[("Lean", 2)] &&
            result.handle == some { module := "Config.A", defines := #["made"] } },
    { name := "a line the language does not have is an error at its line"
      run := do
        let result ← model.file (← model.base none #[]) #[] (file "define made\nwhatever this is")
        return result.handle.isNone && result.diagnostics.map (·.line) == #[2] },
    { name :=
        "a base holds the modules it is asked for after the ones it held, each once, and one asked to hold a module that is not linked throws"
      run := do
        let base ← model.base none #[]
        let grown ← model.base (some base) #["Lean", "Editor", "Std.Data", "Lean"]
        let refused ←
          try
            discard <| model.base (some base) #["Lake"]
            pure false
          catch _ =>
            pure true
        return base.modules == #["Editor"] && grown.modules == #["Editor", "Lean", "Std.Data"] &&
            refused }]

end ModelTest
