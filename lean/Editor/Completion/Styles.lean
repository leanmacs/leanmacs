import Editor.Completion.Style
import Editor.TypedPath

/-!
# The completion styles that ship

Three styles (`Editor/Completion/Style.lean`): the fuzzy matcher's, the
default, orderless's, which proves the interface holds a second rule, and
the path style, which matches a path's last component.

## Fuzzy

`Styles.fuzzy` asks the fuzzy port (`Fuzzy.rank`, `Editor/Fuzzy.lean`)
and answers its indices in its order. So **the order rule is the fuzzy
style's**: a candidate that is the text comes first, then the matcher's
scores. The rule stays implemented where it is, in the Rust ranking
(`editor_fuzzy::rank`) and the model (`FuzzyModel.rank`).

Its ranges are computed here, not asked of the matching library
(`inOrderSpans`): the leftmost in-order occurrence of the text's scalar
values, the port's own rule, adjacent positions merged into one span. They
are a true account of why the candidate matched. The library's own
alignment may pick other positions for a repeated character; asking it
would need a new request of the port, a new result shape across the FFI
and its decoder, and a later phase decides whether the library's worker
replaces the port off the editor thread. Revisit this when a mismatch a
user sees is measured, once a display draws the ranges.

## Orderless

`Styles.orderless` splits the text at spaces into components, the empty
ones dropped (`components`). A candidate matches when every component
occurs in it as a substring, case kept, in any order; no other candidate
matches. A text with no component (empty, or spaces alone) matches every
candidate. The order is the candidates' own: orderless does not sort. The
ranges are each component's first occurrence (`occurrence?`), sorted, with
overlapping or touching ones merged. It asks the port nothing.

## Path

`Styles.path` matches a path by its last component, with the fuzzy style:
the text's last component (after its last `/`, `TypedPath.split`) is
matched against each candidate's (`lastComponent`, where a trailing `/` is
not part of it, so a directory `notes/` is matched as `notes`), and each
span is shifted by its candidate's offset. **The directory part is never
matched**, so it never ranks a candidate. A text that ends in `/` has an
empty last component, and lists every candidate in order. It is the style
the `files` package gives the category `file` (`Editor/Files/Compiled.lean`).

Pinned by `ModelTest.styleChecks` and `styleContractChecks`.
-/

namespace Editor.Completion

namespace Styles

/-- `spans` with `span` added after them: merged into the last when the two
overlap or touch, and otherwise appended. `spans` are ascending, and `span`
starts at or after the last's start. -/
def mergeInto (spans : Array Span) (span : Span) : Array Span :=
  match spans.back? with
  | some last =>
    if span.start ≤ last.stop then
      spans.pop.push { start := last.start, stop := max last.stop span.stop }
    else spans.push span
  | none => spans.push span

/-- The spans of the leftmost in-order occurrence of `pattern`'s characters
in `candidate`, each character's bytes found after the one before it, from
`offset`, added to `spans`; `none` when one is not found. -/
def inOrderWalk : List Char → List Char → Nat → Array Span → Option (Array Span)
  | [], _, _, spans => some spans
  | _ :: _, [], _, _ => none
  | wanted :: pattern, found :: candidate, offset, spans =>
    let next := offset + found.utf8Size
    if wanted == found then inOrderWalk pattern candidate next (mergeInto spans ⟨offset, next⟩)
    else inOrderWalk (wanted :: pattern) candidate next spans

/-- The byte spans of `candidate` where `pattern` matches it by the fuzzy
port's rule: the leftmost in-order occurrence of its scalar values,
adjacent ones merged into one span. None for the empty pattern, and none
for a pattern that does not match. -/
def inOrderSpans (pattern candidate : String) : Array Span :=
  (inOrderWalk pattern.toList candidate.toList 0 #[]).getD #[]

/-- The fuzzy matcher's style, the default: the indices the fuzzy port
ranks, in its order (a candidate that is the text first, then the
matcher's scores), each with its `inOrderSpans`. -/
def fuzzy : Style :=
  { name := "fuzzy"
    hits := fun text candidates => do
      let ranked ← Fuzzy.rank text candidates
      return ranked.map fun index =>
          { index, ranges := inOrderSpans text ((candidates[index]?).getD "") } }

/-- `text` split at its spaces, the empty pieces dropped: the components
orderless matches. -/
def components (text : String) : List String :=
  (text.splitOn " ").filter (!·.isEmpty)

/-- The first byte span of `candidate` where `component` occurs as a
substring, case kept, from `offset`; `none` where it does not occur. -/
def occurrenceFrom (component : List Char) (size : Nat) : List Char → Nat → Option Span
  | chars, offset =>
    if component.isPrefixOf chars then some ⟨offset, offset + size⟩
    else
      match chars with
      | [] => none
      | char :: rest => occurrenceFrom component size rest (offset + char.utf8Size)

/-- The first byte span of `candidate` where `component` occurs as a
substring, case kept; `none` where it does not occur. -/
def occurrence? (component candidate : String) : Option Span :=
  occurrenceFrom component.toList component.utf8ByteSize candidate.toList 0

/-- Orderless's style: a candidate matches when every space-separated
component of the text occurs in it, in any order, and the text with none
matches every candidate. The candidates' own order; each match's ranges
are its components' first occurrences, sorted and merged. -/
def orderless : Style :=
  { name := "orderless"
    hits := fun text candidates =>
      pure <|
        let parts := components text
        (Array.range candidates.size).filterMap fun index => do
          let candidate ← candidates[index]?
          let spans ← parts.mapM (occurrence? · candidate)
          let sorted :=
            spans.toArray.qsort fun a b =>
              a.start < b.start || (a.start == b.start && a.stop < b.stop)
          some { index, ranges := sorted.foldl mergeInto #[] } }

/-- The byte offset and the text of the last component of `text`, a path:
what follows its last `/`, a trailing `/` not counted, so `notes/` is
`notes` at 0 and `~/src/main.lean` is `main.lean` at 6. -/
def lastComponent (text : String) : Nat × String :=
  let trimmed := if text.endsWith "/" then String.ofList text.toList.dropLast else text
  let (directory, last) := TypedPath.split trimmed
  (directory.utf8ByteSize, last)

/-- The path style: the fuzzy style over the last components, the text's
against the candidates', each span shifted to its candidate's text. The
directory part is never matched. -/
def path : Style :=
  { name := "path"
    hits := fun text candidates => do
      let lasts := candidates.map lastComponent
      let hits ← fuzzy.hits (TypedPath.split text).2 (lasts.map (·.2))
      return hits.map fun hit =>
          let offset := ((lasts[hit.index]?).map (·.1)).getD 0
          { hit with
            ranges :=
              hit.ranges.map fun range =>
                { start := range.start + offset, stop := range.stop + offset } } }

/-- The styles that ship, which the `completion` package registers
(`Editor/Completion/Compiled.lean`). -/
def shipped : Array Style :=
  #[fuzzy, orderless, path]

/-- What the report says of a style chosen under `name` that no style is
registered under. -/
def unknown (name : String) : String :=
  s!"no completion style is registered under `{name}`"

end Styles

/-- The matching a host hands when config chooses nothing: the fuzzy style
for every prompt. -/
def Matching.standard : Matching :=
  { default := Styles.fuzzy }

end Editor.Completion
