import Editor.Command
import Editor.Completion.AtPoint
import Editor.Completion.AtPointContract
import Editor.Completion.Candidate
import Editor.Completion.Fake
import Editor.Program
import Editor.Text
import ModelTest.Check
import ModelTest.Support.AtPoint

/-!
# Model tests: `Editor/Completion/AtPointContract.lean`

The model tests of `Editor/Completion/AtPointContract.lean`:
`atPointContractChecks`. The root module `ModelTest` runs them; its module doc
says what each shows.
-/

namespace ModelTest

open Editor

/-- The model at-point source of the contract checks: the region from the
start of the cursor's line to the cursor, read from no text, so it answers
`[offset, offset]` and names the source `say`. -/
def atPointModel : Completion.AtPoint :=
  .fixed "fixed" fun spot =>
    some { start := spot.offset, stop := spot.offset, sources := [.source "say"] }

/-- The at-point sources the contract is run on: the model and one that
never answers. The shipped ones are run on it by their own checks, the
default package `at-point`'s (`AtPointTest.wordsChecks`). -/
def atPointSubjects : List Completion.AtPoint :=
  [atPointModel, Completion.AtPoint.silent "silent"]

/-- The checks of the at-point sources' contract
(`Editor/Completion/AtPointContract.lean`): it holds of the model and of one
that never answers, and it reports one whose region ends past the text, one
that makes a text and one that is refused. -/
def atPointContractChecks : List Check :=
  let broken : Completion.AtPoint :=
    .fixed "broken" fun spot =>
      some { start := spot.offset, stop := spot.offset + 100, sources := [] }
  let writes : Completion.AtPoint :=
    { name := "writes"
      ask := fun _ => do
        discard <| createText "made"
        return none }
  let holds (atPoint : Completion.AtPoint) : Bool :=
    Completion.AtPointContract.properties.all (·.holds atPointRunner atPoint)
  (atPointSubjects.flatMap fun atPoint =>
      Completion.AtPointContract.properties.map fun property =>
        { name := s!"the at-point source {atPoint.name}: {property.name}"
          run := pure (property.holds atPointRunner atPoint) }) ++
    [{  name :=
          "the at-point contract reports a source whose region ends past the text, one that makes a text and one that is refused; it asks at every position of a text with a two-byte character, its end included"
        run :=
          pure <|
            !holds broken && !holds writes && !holds (Completion.Fake.AtPoint.refusing "no") &&
              Completion.AtPointContract.positions "café" == [0, 1, 2, 3, 5] },
      { name :=
          "an at-point source asks on a key always, on a trigger only of its own, and on a pause only of its own length"
        run :=
          pure <|
            let dots : Completion.AtPoint :=
              { atPointModel with
                triggers := ['.'], pause := some 240 }
            dots.asksOn .key && dots.asksOn (.trigger '.') && !dots.asksOn (.trigger 'a') &&
              dots.asksOn (.pause 240) &&
              !dots.asksOn (.pause 100) &&
              !atPointModel.asksOn (.pause 240) &&
              !atPointModel.asksOn (.trigger '.') }]

end ModelTest
