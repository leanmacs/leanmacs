import Editor.Fuzzy

/-!
# The fuzzy matching interface's model

A pure model of the fuzzy matching interface (`Editor/Fuzzy.lean`). It has
no state: an answer depends on the request alone.

- **What matches** (`FuzzyModel.matches`): the pattern's scalar values all
  occur in the candidate, in order. A `String` is a list of scalar values,
  so this is a subsequence test and needs no table.
- **The order** (`FuzzyModel.rank`): the candidates that are the pattern
  first, then the other matches, each group in the order the candidates
  came in.

The contract (`Editor/Fuzzy/Contract.lean`) holds it to what every matcher
answers: which candidates match, and that a candidate that is the pattern
is first. The order after those is the model's own, and a real matcher's is
its scores: nothing may rest on it.

Pinned by `ModelTest.fuzzyChecks`.
-/

namespace Editor

namespace FuzzyModel

/-- Whether the characters of `pattern` all occur in `candidate`, in order:
each is looked for after the place the one before it was found. -/
def inOrder : List Char → List Char → Bool
  | [], _ => true
  | _ :: _, [] => false
  | wanted :: pattern, found :: candidate =>
    if wanted == found then inOrder pattern candidate else inOrder (wanted :: pattern) candidate

end FuzzyModel

/-- Whether `pattern` matches `candidate`: its Unicode scalar values all
occur in the candidate, in the pattern's order, adjacent or apart. -/
def FuzzyModel.matches (pattern candidate : String) : Bool :=
  FuzzyModel.inOrder pattern.toList candidate.toList

namespace FuzzyModel

/-- The indices of the `candidates` that `pattern` matches: those of the
candidates that are the pattern first, then the rest, each group in the
order the candidates came in. -/
def rank (pattern : String) (candidates : Array String) : Array Nat :=
  let matched :=
    (Array.range candidates.size).filter fun index =>
      (candidates[index]?).any (FuzzyModel.matches pattern)
  matched.filter (candidates[·]? == some pattern) ++ matched.filter (candidates[·]? != some pattern)

/-- Answers `request`. The model has no state, so the state is `Unit`. -/
def handle : (request : FuzzyRequest) → Unit → request.Reply × Unit
  | .rank pattern candidates, state => (rank pattern candidates, state)

end FuzzyModel

end Editor
