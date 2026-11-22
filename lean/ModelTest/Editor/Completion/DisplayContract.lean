import Editor.Completion.Candidate
import Editor.Completion.Display
import Editor.Completion.DisplayContract
import Editor.Scene
import ModelTest.Check

/-!
# Model tests: `Editor/Completion/DisplayContract.lean`

The model tests of `Editor/Completion/DisplayContract.lean`:
`displayContractChecks`. The root module `ModelTest` runs them; its module doc
says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the completion displays' contract
(`Editor/Completion/DisplayContract.lean`): it holds of the model and of
the core's own display, and bites on a display written here with a
decoration past its row's end. The shipped display's are
`minibufferDisplayChecks`. -/
def displayContractChecks : List Check :=
  [{  name :=
        "every property of the display contract holds of the plain display and of the core's own display, over every showing of its table"
      run :=
        pure <|
          (Completion.DisplayContract.failures (Completion.Display.plain "plain")).isEmpty &&
            (Completion.DisplayContract.failures Completion.Display.unregistered).isEmpty &&
            !Completion.DisplayContract.properties.isEmpty &&
            Completion.DisplayContract.showings.any (·.listed.size == 30) },
    { name :=
        "the display contract reports a display with a decoration past its row's end, by its property of the decorations alone"
      run :=
        let past : Completion.Display :=
          { name := "past"
            sheet := fun showing =>
              {
                rows :=
                  showing.listed.map fun listed =>
                    { text := listed.text
                      decorations :=
                        #[{ start := 0, stop := listed.text.utf8ByteSize + 1
                            face := ⟨"minibuffer.candidate"⟩ }] } } }
        pure <|
          Completion.DisplayContract.failures past == [Completion.DisplayContract.decorations] }]

end ModelTest
