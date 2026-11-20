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
- **A located pattern** (`FuzzyModel.locate`): every span whose ends are
  character boundaries, measured by byte-wise Levenshtein distance; of
  those within the errors, the fewest errors, then the start nearest the
  expected offset, then the earliest, then the longest. A start's spans are
  measured in one pass of the distance's table, cut off once no longer
  span can come within the errors, so a text of a few kilobytes is
  answered at once.

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

/-- Whether the byte offset `index` of `bytes` is a character boundary:
its end, or a byte that does not continue a character. -/
def boundary (bytes : ByteArray) (index : Nat) : Bool :=
  index == bytes.size || (index < bytes.size && (bytes.get! index &&& 0xC0) != 0x80)

/-- Of the spans of `text` that start at `start` and end on a character
boundary, the fewest errors `pattern` has against one, at most `maxErrors`,
and the end of the longest span with those errors; none when no span from
there is within the errors. -/
def bestFrom (pattern text : ByteArray) (start maxErrors : Nat) : Option (Nat × Nat) :=
  Id.run do
    let size := pattern.size
    -- The distances of each prefix of the pattern to the span so far.
    let mut row : Array Nat := Array.range (size + 1)
    let mut best : Option (Nat × Nat) := if size ≤ maxErrors then some (size, start) else none
    let mut length := 0
    while length < size + maxErrors && start + length < text.size do
      let byte := text.get! (start + length)
      length := length + 1
      let mut next := Array.replicate (size + 1) length
      for column in [1:size + 1] do
        let substituted := row[column - 1]! + (if pattern.get! (column - 1) == byte then 0 else 1)
        next := next.set! column (min substituted (min (row[column]! + 1) (next[column - 1]! + 1)))
      row := next
      let errors := row[size]!
      if errors ≤ maxErrors && boundary text (start + length) then
        best :=
          match best with
          | some (fewest, stop) =>
            if errors ≤ fewest then some (errors, start + length) else some (fewest, stop)
          | none => some (errors, start + length)
      -- The least of a row never falls in the next, so past the errors no
      -- longer span can come back within them.
      if row.foldl min row[0]! > maxErrors then
        break
    return best

/-- The byte span of `text` that `pattern` is located at, `near` the byte
offset where it is expected: of the spans whose ends are character
boundaries and whose distance to the pattern is at most `maxErrors`, the
fewest errors, then the start nearest `near`, then the earliest, then the
longest. None for the empty pattern, and when no span is within the
errors. -/
def locate (pattern text : String) (near maxErrors : Nat) : Option (Nat × Nat) :=
  Id.run do
    let pattern := pattern.toUTF8
    let text := text.toUTF8
    if pattern.size == 0 then
      return none
    let distance (start : Nat) : Nat := if start ≤ near then near - start else start - near
    let mut best : Option (Nat × Nat × Nat) := none
    for start in [0:text.size + 1] do
      if boundary text start then
        if let some (errors, stop) := bestFrom pattern text start maxErrors then
          best :=
            match best with
            | some (fewest, first, last) =>
              if errors < fewest || (errors == fewest && distance start < distance first) then
                some (errors, start, stop)
              else some (fewest, first, last)
            | none => some (errors, start, stop)
    return best.map fun (_, start, stop) => (start, stop)

/-- Answers `request`. The model has no state, so the state is `Unit`. -/
def handle : (request : FuzzyRequest) → Unit → request.Reply × Unit
  | .rank pattern candidates, state => (rank pattern candidates, state)
  | .locate pattern text near maxErrors, state => (locate pattern text near maxErrors, state)

/-- The model as a handler of the fuzzy port in `IO`: what a job runner is
given where a test needs a matcher and no library (`Job.Services.fuzzy`).
It never throws. -/
def handler : FuzzyHandler := fun request => pure (handle request ()).1

end FuzzyModel

end Editor
