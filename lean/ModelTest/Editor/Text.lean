import Editor.Program
import Editor.Text
import Editor.Text.Model
import ModelTest.Check
import ModelTest.Support.Models

/-!
# Model tests: `Editor/Text.lean`

The model tests of `Editor/Text.lean`: `originChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the user's origin (`Origin.user`) and of how a refusal is
described to the user (`TextError.describe`). -/
def originChecks : List Check :=
  [{  name :=
        "the user's origin is not the unattributed one, and a transaction applied with it is traced to an entry by the user"
      run := do
        let command : TextM (Array Attribution) := do
          let text ← createText "ab"
          discard <| text.apply (Transaction.replacing 2 1 1 "xyz") Origin.user
          text.trace 0 5
        return Origin.user != Origin.unattributed &&
            resulted (command.runModel {}).1 ==
              .inr
                #[{ start := 0, stop := 1, author := .earlier 0 },
                  { start := 1, stop := 4, author := .entry 1 Origin.user },
                  { start := 4, stop := 5, author := .earlier 0 }] },
    { name := "every refusal of the text port is described in a few words of its own"
      run :=
        pure
          ([TextError.noSuchText, .badRange, .noSuchSnapshot, .badPosition, .badChange,
                  .badSelection, .unknownRevision, .forgotten, .noSuchMarker, .noInverse,
                  .notInState].map
              TextError.describe ==
            ["no such text", "bad range", "no such snapshot", "bad position", "bad change",
              "bad selection", "unknown revision", "forgotten revision", "no such marker",
              "no inverse", "not in state"]) }]

end ModelTest
