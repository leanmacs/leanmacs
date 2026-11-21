import Editor.Completion.Candidate
import Editor.Completion.Display
import Editor.Completion.Style
import Editor.Fuzzy
import Editor.Scene

/-!
# Model tests: support: Listings

A completion style (`marking`) and a completion display (`windowed`)
written for the core's tests, neither the ones that ship: the core's own
style (`Completion.Style.unregistered`) gives no ranges, and its own
display (`Completion.Display.unregistered`) draws no face and has no
window, and a check of what the loop and the state do with a style's
ranges or a display's rows, faces and window needs one that has them. Each
rule is stated here and is no shipped one's. Shared by several test
modules under `ModelTest/Editor/`; it holds no checks of its own.
-/

namespace ModelTest

open Editor

/-- The byte span of the first occurrence of `text` in `candidate`, as a
run of its characters; none for the empty text and where it does not
occur. -/
def markedSpan (text candidate : String) : Option Completion.Span :=
  if text.isEmpty then none
  else
    match candidate.splitOn text with
    | before :: _ :: _ => some ⟨before.utf8ByteSize, before.utf8ByteSize + text.utf8ByteSize⟩
    | _ => none

/-- The ranges `marking` gives a candidate for `text`: `markedSpan`'s, if
any. -/
def markedSpans (text candidate : String) : Array Completion.Span :=
  (markedSpan text candidate).toArray

/-- A style written for the core's tests, `marking`: the candidates the
fuzzy port ranks (`Fuzzy.rank`), in its order, each with `markedSpans`. -/
def marking : Completion.Style :=
  { name := "marking"
    hits := fun text candidates => do
      return (← Fuzzy.rank text candidates).map fun index =>
          { index, ranges := markedSpans text ((candidates[index]?).getD "") } }

/-- A style written for the core's tests, `containing`: the candidates that
hold the text as a run of their characters, in their order, with no
ranges; the empty text keeps every one. -/
def containing : Completion.Style :=
  .keeping "containing" fun text candidate => (markedSpan text candidate).isSome || text.isEmpty

/-- The matching of the core's tests that read a listing's ranges:
`marking` for every prompt. -/
def markingMatching : Completion.Matching :=
  { default := marking }

/-- How many rows `windowed` shows at most. -/
def windowedRows : Nat :=
  10

/-- The face `windowed` draws a candidate's row in, unless it is the chosen
one. -/
def windowedRow : FaceName :=
  ⟨"test.row"⟩

/-- The face `windowed` draws the chosen candidate's row in. -/
def windowedChosen : FaceName :=
  ⟨"test.chosen"⟩

/-- The face `windowed` draws a matched range in, over its row's. -/
def windowedMatch : FaceName :=
  ⟨"test.match"⟩

/-- Where the window of `windowed` starts for `showing`: where it last did
(the last candidate when that is past the listing's end, 0 for an empty
listing); at the chosen candidate when that is before it; and so that the
chosen one is its last row when that is past its rows. -/
def windowedFirst (showing : Completion.Showing) : Nat :=
  let size := showing.listed.size
  let start := if size == 0 then 0 else min showing.first (size - 1)
  match showing.chosen with
  | some chosen =>
    if chosen < start then chosen
    else if start + windowedRows ≤ chosen then chosen + 1 - windowedRows else start
  | none => start

/-- A display written for the core's tests, `windowed`: a row for each of
at most `windowedRows` candidates from where its window starts
(`windowedFirst`), its label, or its text when it has none, the whole row
in `windowedRow`, or `windowedChosen` for the chosen one, and, for a
candidate with no label, each matched range over it in `windowedMatch`. -/
def windowed : Completion.Display :=
  { name := "windowed"
    sheet := fun showing =>
      let first := windowedFirst showing
      { first
        rows :=
          (showing.listed.extract first (first + windowedRows)).mapIdx fun index listed =>
            let text := Completion.oneLine (listed.candidate.label.getD listed.text)
            let face :=
              if showing.chosen == some (first + index) then windowedChosen else windowedRow
            let ranges :=
              if listed.candidate.label.isSome then #[]
              else
                (listed.ranges.filter (·.stop ≤ text.utf8ByteSize)).map fun range =>
                  { start := range.start, stop := range.stop, face := windowedMatch }
            { text
              decorations :=
                (if text.isEmpty then #[]
                  else #[{ start := 0, stop := text.utf8ByteSize, face }]) ++
                  ranges } } }

/-- The displaying of the core's tests that draw a list: `windowed` for
every listing. -/
def windowedDisplaying : Completion.Displaying :=
  { default := windowed }

end ModelTest
