import Editor.Fuzzy

/-!
# The contract of the fuzzy matching interface

What every implementation of the fuzzy matching interface
(`Editor/Fuzzy.lean`) answers, as one list of properties. The model
(`Editor/Fuzzy/Model.lean`) is held to it by `model-test`, and the real
binding runs the same list in `contract-test`, so neither can drift from
the other. This module imports only the port, so the contract never depends
on an implementation.

## What it asks

Three things, and each property is one case of one of them:

- **Which candidates match** (`whichMatch`): a pattern, candidates, and the
  indices of the candidates the pattern matches. The reply is compared
  **sorted**, so a case says nothing of the order; it does say that each
  index is answered once and that none is answered that does not match.
  The cases are the rule of what matches as data: the pattern's characters
  adjacent and apart, a character the candidate lacks, another order, a
  repeated character, the empty pattern and the empty candidate, case, the
  scalar values of composed and decomposed characters, and the characters a
  matching library may read as syntax.
- **An exact match is first** (`exactFirst`): cases where a candidate is the
  pattern and is not the first candidate, among others that match as well.
  The property reads the first index of the reply only.
- **Where a pattern is located** (`locating`): a pattern, a text, the
  offset where it is expected and the errors allowed. Every answer is a
  span of the text within the errors, with its ends on character
  boundaries; in an ASCII text it has the fewest errors any span has, and
  there is one exactly when some span is within the errors; in any text
  there is none when no span of its bytes is within them; the pattern
  where it is expected is answered there; and the empty pattern is
  answered none. The fewest errors are an oracle's of the contract's own,
  every span of the text measured one by one, so the contract still
  imports nothing but the port.

## What it does not ask

The order after the candidates that are the pattern. The model's is the
candidates' own and a matching library's is its scores, and the two are not
held to agree on it: nothing above the port may rest on it. Nor which of
several equally good spans a located pattern is answered at, nor the fewest
errors in a text that is not ASCII, where a library that counts bytes can
drop a best span that cuts a character (`Editor/Fuzzy.lean`, "What a
located pattern is answered at").

## How the two sides are held together

The cases here are a table. That the model and the library agree beyond the
table rests on the Rust side: the scorer port's contract
(`crates/editor-fuzzy`) sweeps generated texts against the same rule, on
its fake and on the library's adapter, and the real binding is the Rust
ranking rule over that adapter.
-/

namespace Editor.FuzzyContract

/-- One property of the fuzzy matching interface. -/
structure Property where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the property; `true` when it holds. -/
  holds : FuzzyM Bool

/-- What the names of the properties about which candidates match begin
with. -/
def whichMatch : String :=
  "which candidates match"

/-- What the names of the properties about an exact match begin with. -/
def exactFirst : String :=
  "an exact match is first"

/-- What the names of the properties about a located pattern begin
with. -/
def locating : String :=
  "a located pattern"

/-- The byte-wise Levenshtein distance between `a` and `b`: the oracle's
measure, written here so the contract depends on no implementation. -/
def distance (a b : ByteArray) : Nat :=
  Id.run do
    let mut row : Array Nat := Array.range (b.size + 1)
    for i in [0:a.size] do
      let mut next := Array.replicate (b.size + 1) (i + 1)
      for j in [0:b.size] do
        let substituted := row[j]! + (if a.get! i == b.get! j then 0 else 1)
        next := next.set! (j + 1) (min substituted (min (row[j + 1]! + 1) (next[j]! + 1)))
      row := next
    return row[b.size]!

/-- The fewest errors `pattern` has against any span of `text`'s bytes,
each measured: the oracle. -/
def fewest (pattern text : ByteArray) : Nat :=
  Id.run do
    let mut least := pattern.size
    for start in [0:text.size + 1] do
      for stop in [start:text.size + 1] do
        least := min least (distance pattern (text.extract start stop))
    return least

/-- Whether the byte offset `index` of `bytes` is a character boundary. -/
def onBoundary (bytes : ByteArray) (index : Nat) : Bool :=
  index == bytes.size || (index < bytes.size && (bytes.get! index &&& 0xC0) != 0x80)

/-- What every answer for `pattern` in `text` within `maxErrors` keeps: a
span of the text within the errors, its ends on character boundaries; in an
ASCII text the fewest errors, and an answer exactly when some span is
within the errors; in any text none when no span of its bytes is. -/
def keeps (pattern text : String) (maxErrors : Nat) (answer : Option (Nat × Nat)) : Bool :=
  let patternBytes := pattern.toUTF8
  let bytes := text.toUTF8
  let least := fewest patternBytes bytes
  let ascii := patternBytes.data.all (· < 128) && bytes.data.all (· < 128)
  match answer with
  | none => least > maxErrors || (!ascii && least ≤ maxErrors)
  | some (start, stop) =>
    let errors := distance patternBytes (bytes.extract start stop)
    start ≤ stop && stop ≤ bytes.size && onBoundary bytes start && onBoundary bytes stop &&
      errors ≤ maxErrors &&
      (!ascii || errors == least)

/-- The cases every answer is held to (`keeps`): what the case is, a
pattern, a text, the offset where it is expected and the errors allowed. -/
def locateCases : List (String × String × String × Nat × Nat) :=
  [("it is where it is expected", "needle", "a needle in a haystack", 2, 1),
    ("one byte substituted", "needle", "a neddle in a haystack", 0, 1),
    ("one byte inserted", "needle", "a neeedle in a haystack", 0, 2),
    ("one byte deleted", "needle", "a nedle in a haystack", 0, 1),
    ("no span is near enough", "needle", "nothing like it", 0, 1),
    ("the text is empty", "needle", "", 0, 2),
    ("only a shorter span is within the errors", "abc", "ab", 0, 1),
    ("two spans, each one error away", "abcd", "xx abxd yy abcx zz", 0, 1),
    ("two-byte characters against one-byte ones", "café", "un cafe noir", 0, 2),
    ("wide characters, one of them changed", "漢字です", "これは漢字だす", 0, 3),
    ("an accented letter against its base letter", "e", "é", 0, 2),
    ("an expected offset past the text", "needle", "a needle", 100, 1)]

/-- The cases where the pattern is exactly where it is expected: what the
case is, a pattern, a text, and the offset where the pattern is. -/
def placedCases : List (String × String × String × Nat) :=
  [("alone", "needle", "a needle", 2),
    ("among copies of itself", "needle", "needle needle needle", 7),
    ("overlapping a copy of itself", "aa", "aaaa", 1), ("after wide characters", "字", "漢字漢字", 9)]

/-- The cases of which candidates match: what the case is, a pattern,
candidates, and the indices of the candidates the pattern matches, in
ascending order. `é` is U+00E9, and `é` its decomposed form. -/
def matchCases : List (String × String × Array String × Array Nat) :=
  [("a pattern whose characters are in a candidate in order, together or apart, matches it", "ace",
      #["ace", "abcde", "a-c-e", "xxaxxcxxexx"], #[0, 1, 2, 3]),
    ("a pattern with a character the candidate lacks does not match it", "axe",
      #["abcde", "axe", "ae", "ax", "xe"], #[1]),
    ("a pattern whose characters are in a candidate in another order does not match it", "ba",
      #["ab", "aab", "bxa"], #[2]),
    ("a character the pattern repeats is needed as often in the candidate", "aa",
      #["a", "ba", "aba"], #[2]),
    ("the empty pattern matches every candidate, the empty one too", "", #["abc", "", " "],
      #[0, 1, 2]),
    ("a pattern that is not empty does not match the empty candidate", "a", #["", "a"], #[1]),
    ("a pattern that is one space does not match the empty candidate", " ", #[""], #[]),
    ("a small letter does not match its capital", "a", #["A", "a"], #[1]),
    ("a capital letter does not match its small letter", "Re", #["reload", "Reload"], #[1]),
    ("an accented letter matches itself, and neither its base letter nor its decomposed form", "é",
      #["e", "é", "é"], #[1]),
    ("a base letter matches a decomposed character, which holds it, and not the composed one", "e",
      #["é", "é"], #[1]),
    ("a combining mark is a character of the candidate like any other", "́", #["é", "é"], #[0]),
    ("wide characters match in order", "漢字", #["漢x字", "字漢"], #[0]),
    ("a character outside the basic plane matches", "🙂", #["a🙂b", "ab"], #[0]),
    ("a caret is a character to find, not an anchor at the start", "^a", #["a", "^a", "x^xa"],
      #[1, 2]),
    ("a dollar sign is a character to find, not an anchor at the end", "a$", #["a", "a$"], #[1]),
    ("an exclamation mark is a character to find, not a negation", "!a", #["a", "b", "!a"], #[2]),
    ("an apostrophe is a character to find, not a quote", "'a", #["a", "'a"], #[1]),
    ("a space is a character to find, not a separator of two patterns", "a b",
      #["ab", "a b", "b a", "a-b"], #[1]),
    ("a backslash is a character to find, not an escape", "\\ ", #[" ", "\\ "], #[1]),
    ("two candidates that are the same string are two indices", "w", #["w", "x", "w"], #[0, 2]),
    ("no candidates answer no index", "a", #[], #[])]

/-- The cases of an exact match: what the case is, a pattern, and
candidates of which one or more are the pattern, the first candidate is
not, and others match too. -/
def exactCases : List (String × String × Array String) :=
  [("a one-letter name among longer names that hold it", "w", #["wq", "rewrite", "w"]),
    ("a name among names it begins", "reload", #["reload-config", "reload"]),
    ("a pattern that is not ASCII", "é", #["éé", "xé", "é"]),
    ("the empty pattern, among a candidate that is not empty and the empty one", "", #["a", ""]),
    ("two candidates that are the pattern, after one that is not", "w", #["wq", "w", "w"])]

/-- The properties of the fuzzy matching interface. -/
def properties : List Property :=
  (matchCases.map fun (what, pattern, candidates, expected) =>
      { name := s!"{whichMatch}: {what}"
        holds := do
          let ranked ← Fuzzy.rank pattern candidates
          return ranked.qsort (· < ·) == expected }) ++
    (exactCases.map fun (what, pattern, candidates) =>
      { name := s!"{exactFirst}: {what}"
        holds := do
          let ranked ← Fuzzy.rank pattern candidates
          return (ranked[0]?.bind (candidates[·]?)) == some pattern }) ++
    (locateCases.map fun (what, pattern, text, near, maxErrors) =>
      { name := s!"{locating}: is within the errors, on character boundaries, and the fewest errors in ASCII text, when {what}"
        holds := return keeps pattern text maxErrors (← Fuzzy.locate pattern text near maxErrors) }) ++
    (placedCases.map fun (what, pattern, text, near) =>
      { name := s!"{locating}: where it is expected is answered there, {what}"
        holds := return (← Fuzzy.locate pattern text near 1) == some (near, near + pattern.utf8ByteSize) }) ++
    [{ name := s!"{locating}: the empty pattern is answered none"
       holds := return (← Fuzzy.locate "" "text" 0 3) == none }]

/-- The names of `properties` that do not hold. `run` runs one property
against an implementation. -/
def failures (run : Property → IO Bool) (properties : List Property) : IO (List String) :=
  properties.filterMapM fun property => do
    return if ← run property then none else some property.name

end Editor.FuzzyContract
