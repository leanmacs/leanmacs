import Editor.Completion.Style

/-!
# The contract of completion styles

What every completion style (`Editor/Completion/Style.lean`) answers, as one
list of properties. `model-test` runs it against the fuzzy style over the
fuzzy model, the orderless style and the model, `Style.keeping`
(`ModelTest.styleContractChecks`); `contract-test` runs it against the fuzzy
style over the real matcher (`ContractTest.styleFailures`). Together that is
the one contract check of the interface's model and its real
implementation. This module imports only the interface, so the contract
never depends on a style.

## What it asks

Each property runs over a table of texts and arrays of candidates
(`texts`, `candidateSets`): a letter, two components, a space alone, a
character of two bytes, a candidate repeated, a composed and a decomposed
character, no candidates at all, and paths with a `/`, so a style that
shifts its ranges, as the path style does, is held to them.

- **The indices** (`indices`): each index a style answers is one of the
  candidates', and none is answered twice.
- **The ranges** (`ranges`): each is not empty, lies within its
  candidate's text on character boundaries, and a candidate's ranges are
  ascending and apart, so a display can draw them one after another.
- **The empty text** (`emptyText`): it lists every candidate.

It does not ask which candidates match, nor in what order: that is each
style's own rule, pinned on the style.

## How it is run

A property is a program over the fuzzy port, handed the style. `failures`
is handed what runs such a program: against the fuzzy model, or against
the real binding.
-/

namespace Editor.Completion.StyleContract

/-- One property of completion styles. -/
structure Property where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Whether it holds of `style`. -/
  holds : Style → FuzzyM Bool

/-- The texts each property asks with. -/
def texts : List String :=
  ["", "w", "a b", " ", "é", "ab", "s/a"]

/-- The candidates each property asks among: `é` is U+00E9, and `é` its
decomposed form. -/
def candidateSets : List (Array String) :=
  [#["wq", "edit", "rewrite", "w"], #["é", "é", "a b", "b a", ""], #[], #["ab", "ab"],
    #["src/", "src/a.lean", "a/b"]]

/-- The byte offsets of the character boundaries of `text`: 0, then the
end of each character. -/
def boundaries (text : String) : Array Nat :=
  (text.toList.foldl
      (fun (offsets, offset) char =>
        (offsets.push (offset + char.utf8Size), offset + char.utf8Size))
      (#[0], 0)).1

/-- Whether each of `hits`' indices is one of `candidates`', and none is
answered twice. -/
def indicesHold (candidates : Array String) (hits : Array Hit) : Bool :=
  let indices := hits.toList.map (·.index)
  indices.all (· < candidates.size) && indices.eraseDups.length == indices.length

/-- Whether each of `hits`' ranges is not empty and lies within its
candidate's text on character boundaries, and each hit's ranges are
ascending and apart. -/
def rangesHold (candidates : Array String) (hits : Array Hit) : Bool :=
  hits.all fun hit =>
    let text := (candidates[hit.index]?).getD ""
    let bounds := boundaries text
    let spans := hit.ranges.toList
    spans.all
        (fun span =>
          span.start < span.stop && bounds.contains span.start && bounds.contains span.stop) &&
      (spans.zip spans.tail).all fun (first, second) => first.stop < second.start

/-- Whether `check` holds of the hits `style` answers for every text of
`texts` among every array of `candidateSets`. -/
def overTable (style : Style) (check : Array String → Array Hit → Bool) : FuzzyM Bool :=
  texts.allM fun text =>
    candidateSets.allM fun candidates => do
      return check candidates (← style.hits text candidates)

/-- The name of the property of the indices. -/
def indices : String :=
  "each index a style answers is one of the candidates', and none is answered twice"

/-- The name of the property of the ranges. -/
def ranges : String :=
  "each range is not empty, lies within its candidate's text on character boundaries, and a candidate's ranges are ascending and apart"

/-- The name of the property of the empty text. -/
def emptyText : String :=
  "the empty text lists every candidate"

/-- The properties every style keeps. -/
def properties : List Property :=
  [{ name := indices, holds := fun style => overTable style indicesHold },
    { name := ranges, holds := fun style => overTable style rangesHold },
    { name := emptyText
      holds := fun style =>
        candidateSets.allM fun candidates => do
          let hits ← style.hits "" candidates
          return (hits.map (·.index)).qsort (· < ·) == Array.range candidates.size }]

/-- The names of `properties` that do not hold of `style`. `run` runs a
program over the fuzzy port against an implementation. -/
def failures (run : FuzzyM Bool → IO Bool) (style : Style)
    (properties : List Property := properties) : IO (List String) :=
  properties.filterMapM fun property => do
    return if ← run (property.holds style) then none else some property.name

end Editor.Completion.StyleContract
