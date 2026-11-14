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

Two things, and each property is one case of one of them:

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

## What it does not ask

The order after the candidates that are the pattern. The model's is the
candidates' own and a matching library's is its scores, and the two are not
held to agree on it: nothing above the port may rest on it.

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
    exactCases.map fun (what, pattern, candidates) =>
      { name := s!"{exactFirst}: {what}"
        holds := do
          let ranked ← Fuzzy.rank pattern candidates
          return (ranked[0]?.bind (candidates[·]?)) == some pattern }

/-- The names of `properties` that do not hold. `run` runs one property
against an implementation. -/
def failures (run : Property → IO Bool) (properties : List Property) : IO (List String) :=
  properties.filterMapM fun property => do
    return if ← run property then none else some property.name

end Editor.FuzzyContract
