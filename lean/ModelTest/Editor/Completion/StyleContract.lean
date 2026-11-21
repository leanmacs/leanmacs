import Editor.Completion.Candidate
import Editor.Completion.Style
import Editor.Completion.StyleContract
import Editor.Fuzzy
import Editor.Program
import Editor.Test.Completion
import ModelTest.Check

/-!
# Model tests: `Editor/Completion/StyleContract.lean`

The model tests of `Editor/Completion/StyleContract.lean`:
`styleContractChecks`. The root module `ModelTest` runs them; its module doc
says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The names of the style contract's properties that do not hold of
`style`, its fuzzy requests answered by the fuzzy model. -/
def styleBroken (style : Completion.Style) : IO (List String) :=
  Completion.StyleContract.failures (fun program => pure (ranked program)) style

/-- The checks of the completion styles' contract
(`Editor/Completion/StyleContract.lean`): it holds of the core's own style
and of the model, and bites on a style written here that answers an index
twice and on one with a range past its candidate's end. The shipped
styles' are `shippedStyleChecks`. -/
def styleContractChecks : List Check :=
  [{  name :=
        "every property of the style contract holds of the core's own style over the fuzzy model and of a style that keeps what its predicate says"
      run := do
        return (← styleBroken Completion.Style.unregistered).isEmpty &&
            (←
                styleBroken
                    (.keeping "starts" fun text candidate => candidate.startsWith text)).isEmpty &&
            !Completion.StyleContract.properties.isEmpty },
    { name :=
        "the style contract reports a style that answers every index twice, by its property of the indices and not by that of the ranges"
      run := do
        let twice : Completion.Style :=
          { name := "twice"
            hits := fun _ candidates =>
              pure
                ((Array.range candidates.size).flatMap fun index =>
                  #[.ofIndex index, .ofIndex index]) }
        let broken ← styleBroken twice
        return broken.contains Completion.StyleContract.indices &&
            !broken.contains Completion.StyleContract.ranges },
    { name :=
        "the style contract reports a style with a range past its candidate's end, by its property of the ranges alone"
      run := do
        let past : Completion.Style :=
          { name := "past"
            hits := fun _ candidates =>
              pure <|
                (Array.range candidates.size).map fun index =>
                  { index, ranges := #[⟨0, ((candidates[index]?).getD "").utf8ByteSize + 1⟩] } }
        return (← styleBroken past) == [Completion.StyleContract.ranges] }]

end ModelTest
