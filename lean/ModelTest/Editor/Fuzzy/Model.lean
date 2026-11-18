import Editor.Fuzzy
import Editor.Fuzzy.Contract
import Editor.Fuzzy.Model
import ModelTest.Check
import ModelTest.Support.Completion
import ModelTest.Support.Models

/-!
# Model tests: `Editor/Fuzzy/Model.lean`

The model tests of `Editor/Fuzzy/Model.lean`: `fuzzyChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- A matcher written for the tests that break the contract: a candidate
matches when `matched` says so of the pattern and the candidate, and the
candidates that are the pattern come first only with `exactFirst`; the rest
are in the candidates' order. -/
def matcherBy (matched : String → String → Bool) (exactFirst : Bool) :
    (request : FuzzyRequest) → Unit → request.Reply × Unit
  | .rank pattern candidates, state =>
    let indices :=
      (Array.range candidates.size).filter fun index => (candidates[index]?).any (matched pattern)
    if exactFirst then
      (indices.filter (candidates[·]? == some pattern) ++
          indices.filter (candidates[·]? != some pattern),
        state)
    else (indices, state)

/-- The checks of the fuzzy matching interface's model
(`Editor/Fuzzy/Model.lean`): what only the model shows, its rule of what
matches and its order after the candidates that are the pattern, and the
contract (`Editor/Fuzzy/Contract.lean`) seen to report a matcher that
breaks each of the two things it asks. -/
def fuzzyChecks : List Check :=
  [{  name :=
        "the fuzzy model matches a pattern whose characters are in a candidate in order, together or apart, and not one with a character the candidate lacks or with its characters in another order; the empty pattern matches everything and nothing else matches the empty candidate"
      run :=
        pure <|
          FuzzyModel.matches "ace" "ace" && FuzzyModel.matches "ace" "abcde" &&
            !FuzzyModel.matches "axe" "abcde" &&
            !FuzzyModel.matches "eca" "abcde" &&
            !FuzzyModel.matches "aa" "a" &&
            FuzzyModel.matches "aa" "aba" &&
            FuzzyModel.matches "" "" &&
            FuzzyModel.matches "" "a" &&
            !FuzzyModel.matches "a" "" &&
            !FuzzyModel.matches "a" "A" },
    { name :=
        "the fuzzy model ranks the candidates that are the pattern first and the other matches after them, each group in the order the candidates came in, and a request through the port is answered so"
      run :=
        pure <|
          let candidates := #["wq", "edit", "rewrite", "w", "w", "xw"]
          FuzzyModel.rank "w" candidates == #[3, 4, 0, 2, 5] &&
            ranked (Fuzzy.rank "w" candidates) == #[3, 4, 0, 2, 5] &&
            FuzzyModel.rank "z" candidates == #[] &&
            FuzzyModel.rank "w" #[] == #[] },
    { name :=
        "the fuzzy contract reports a matcher that ignores case, by its properties of which candidates match and by none of an exact match"
      run := do
        let folded (pattern candidate : String) : Bool :=
          FuzzyModel.matches pattern.toLower candidate.toLower
        let broken ← fuzzyBroken (matcherBy folded true)
        return !broken.isEmpty && broken.all (·.startsWith FuzzyContract.whichMatch) },
    { name :=
        "the fuzzy contract reports a matcher that answers the matches in the candidates' order, by its properties of an exact match and by none of which candidates match"
      run := do
        let broken ← fuzzyBroken (matcherBy FuzzyModel.matches false)
        return !broken.isEmpty && broken.all (·.startsWith FuzzyContract.exactFirst) },
    { name :=
        "every property of the fuzzy contract holds of the model and of a matcher written to its rule, and the contract has properties of which candidates match and of an exact match"
      run := do
        let names := FuzzyContract.properties.map (·.name)
        return (← fuzzyBroken FuzzyModel.handle).isEmpty &&
            (← fuzzyBroken (matcherBy FuzzyModel.matches true)).isEmpty &&
            names.any (·.startsWith FuzzyContract.whichMatch) &&
            names.any (·.startsWith FuzzyContract.exactFirst) }]

end ModelTest
