import Editor.Completion.Candidate
import Editor.Completion.Style
import Editor.Config.Owner
import Editor.Fuzzy
import Editor.Fuzzy.Model
import Editor.Program
import Editor.Test.Completion
import ModelTest.Check

/-!
# Model tests: `Editor/Completion/Style.lean`

The model tests of `Editor/Completion/Style.lean`: `styleChecks`, the model,
the core's own style and the choice. The shipped styles' are in
`ModelTest/Editor/Completion/Styles.lean`. The root module `ModelTest` runs
them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The checks of the completion style interface (`Editor/Completion/Style.lean`):
the model, the core's own style and the choice, over the fuzzy model, with
styles written here. -/
def styleChecks : List Check :=
  [{  name :=
        "the core's own style, ranked, answers for each text and candidates of a table the indices the fuzzy model ranks, in that order, with no ranges; a host told of no style matches every category with it"
      run :=
        pure <|
          let table : List (String × Array String) :=
            [("", #["wq", "edit", "w"]), ("w", #["wq", "edit", "rewrite", "w", "xw"]),
              ("wq", #["wq", "w", "qw", "wxq"]), ("z", #["a", "b"])]
          table.all
              (fun (text, candidates) =>
                styled Completion.Style.unregistered text candidates ==
                  (FuzzyModel.rank text candidates).map Completion.Hit.ofIndex) &&
            Completion.Style.unregistered.name == "ranked" &&
            (Completion.Matching.unregistered.styleFor (some "pick")).name == "ranked" &&
            (Completion.Matching.unregistered.styleFor none).name == "ranked" },
    { name :=
        "a style that keeps what its predicate says answers the candidates it holds of, in their order, with no ranges, and asks the matcher nothing"
      run :=
        pure <|
          let starts :=
            Completion.Style.keeping "starts" fun text candidate => candidate.startsWith text
          let (hits, asked) :=
            Program.run (port := fuzzyPort)
              (fun request count => (FuzzyModel.handle request ()).1 |> (·, count + 1))
              (starts.hits "w" #["wq", "edit", "w", "aw"]) 0
          starts.name == "starts" && hits == #[.ofIndex 0, .ofIndex 2] && asked == 0 },
    { name :=
        "matching picks a category's style when it has one and the default otherwise, and with no category the default; the report says a style chosen under a name nobody registered"
      run :=
        pure <|
          let matching : Completion.Matching :=
            { default := .keeping "first" fun _ _ => true
              byCategory := fun category =>
                if category == "pick" then some (.keeping "second" fun _ _ => true) else none }
          (matching.styleFor (some "pick")).name == "second" &&
            (matching.styleFor (some "other")).name == "first" &&
            (matching.styleFor none).name == "first" &&
            Completion.Style.unknown "nope" == "no completion style is registered under `nope`" }]

end ModelTest
