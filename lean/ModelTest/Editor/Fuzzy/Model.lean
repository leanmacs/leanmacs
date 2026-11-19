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
  | .locate pattern text near maxErrors, state =>
    (FuzzyModel.locate pattern text near maxErrors, state)

/-- A matcher written for the tests that break the contract's properties of
a located pattern: it ranks as the model does, and answers `answer` of each
located pattern. -/
def locatorBy (answer : String → String → Nat → Nat → Option (Nat × Nat)) :
    (request : FuzzyRequest) → Unit → request.Reply × Unit
  | .rank pattern candidates, state => (FuzzyModel.rank pattern candidates, state)
  | .locate pattern text near maxErrors, state => (answer pattern text near maxErrors, state)

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
        "every property of the fuzzy contract holds of the model and of a matcher written to its rule, and the contract has properties of which candidates match, of an exact match and of a located pattern"
      run := do
        let names := FuzzyContract.properties.map (·.name)
        return (← fuzzyBroken FuzzyModel.handle).isEmpty &&
            (← fuzzyBroken (matcherBy FuzzyModel.matches true)).isEmpty &&
            names.any (·.startsWith FuzzyContract.whichMatch) &&
            names.any (·.startsWith FuzzyContract.exactFirst) &&
            names.any (·.startsWith FuzzyContract.locating) },
    { name :=
        "the fuzzy model locates a pattern with the fewest errors first, then nearest where it is expected, then earliest, then longest, and a request through the port is answered so"
      run :=
        pure <|
          let text := "needle .......... needle"
          -- Two exact places: the nearer is answered.
          FuzzyModel.locate "needle" text 0 1 == some (0, 6) &&
            FuzzyModel.locate "needle" text 16 1 == some (18, 24) &&
            -- Equally near, the earlier.
            FuzzyModel.locate "ab" "ab..ab" 2 0 == some (0, 2) &&
            -- Fewer errors win over nearness.
            FuzzyModel.locate "needle" "neddle .......... needle" 0 2 == some (18, 24) &&
            -- One substitution, one insertion: the span, the longer one.
            FuzzyModel.locate "needle" "xx neddle yy" 0 1 == some (3, 9) &&
            FuzzyModel.locate "needle" "xx neeedle yy" 0 1 == some (3, 10) &&
            ranked (Fuzzy.locate "needle" text 16 1) == some (18, 24) },
    { name :=
        "the fuzzy model locates nothing for the empty pattern, nor when no span is within the errors, and answers only spans whose ends are character boundaries"
      run :=
        pure <|
          FuzzyModel.locate "" "text" 0 3 == none &&
            FuzzyModel.locate "needle" "haystack" 0 1 == none &&
            FuzzyModel.locate "needle" "" 0 5 == none &&
            -- `é` against `e` is two byte errors, so `caf`, one deletion.
            FuzzyModel.locate "cafe" "un café noir" 0 2 == some (3, 6) &&
            -- `で` and `だ` differ in their last byte.
            FuzzyModel.locate "漢字です" "これは漢字だす" 0 3 == some (9, 21) &&
            -- The empty span before `é` is one error, and the `é` itself
            -- two; no span of one byte of it is answered.
            FuzzyModel.locate "e" "é" 0 2 == some (0, 0) &&
            FuzzyModel.locate "ée" "é" 0 2 == some (0, 2) },
    { name :=
        "the fuzzy contract reports a matcher that locates nothing, and one that answers a span with more errors than the fewest, by its properties of a located pattern alone"
      run := do
        let nothing ← fuzzyBroken (locatorBy fun _ _ _ _ => none)
        let longer ←
          fuzzyBroken
              (locatorBy fun pattern text near maxErrors =>
                (FuzzyModel.locate pattern text near maxErrors).map fun (start, stop) =>
                  (start, min (stop + 1) text.utf8ByteSize))
        return !nothing.isEmpty && nothing.all (·.startsWith FuzzyContract.locating) &&
            !longer.isEmpty &&
            longer.all (·.startsWith FuzzyContract.locating) }]

end ModelTest
