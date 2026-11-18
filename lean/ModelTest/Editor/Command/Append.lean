import Editor.Command.Append
import Editor.Program
import Editor.Text
import Editor.Text.Contract

/-!
# Model tests: `Editor/Command/Append.lean`

The model tests of `Editor/Command/Append.lean`: `commandProperties`.
`commandProperties` are run with the text port's contract (`textProperties`, in
`ModelTest.Editor.Text.Contract`). The root module `ModelTest` runs them; its
module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- What the editor's commands do, observed against the text model. -/
def commandProperties : List TextContract.Property :=
  [{ name := "append adds to the end of a text, after its last character",
     holds := do
       let text ← createText "héllo"
       append text " wörld"
       return (← text.read) == "héllo wörld" }]

end ModelTest
