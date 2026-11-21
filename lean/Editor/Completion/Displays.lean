import Editor.Completion.Display

/-!
# The completion displays that ship

One display (`Editor/Completion/Display.lean`): the minibuffer's,
`Displays.minibuffer`, the default. It is drawn in a view of its own over
generated text, at the top of the minibuffer's place, directly above the
input (`Loop.candidateListView`, `Editor/Loop.lean`; `EditorState`'s
"The minibuffer's place", `Editor/State.lean`). Its rule is pure.

## The minibuffer display

- **Rows.** At most `rows` rows (`Displays.rows`, 10 unless config sets
  another with `defineDisplay (Completion.Displays.minibuffer (rows := n))`,
  as vertico's `vertico-count`), the best match at the top, one candidate a
  row in the listing's order. The listing is the whole listing: the
  display shows a window of it.
- **Faces.** A row starts with the candidate's label, or its text when it
  has none, and the whole row is in `candidateFace`
  (`minibuffer.candidate`), or in `chosenFace` (`minibuffer.chosen`) for
  the chosen one. Then each matched range of its text (`Listed.ranges`) is
  in `matchFace` (`minibuffer.match`), drawn over it: when it has no label;
  and when its label ends its text, as a path's last component ends the
  path, the ranges within that end, shifted onto the label, a range that
  crosses into it cut at its start (`labelRanges`). Any other label has
  none drawn.
- **Annotations in an aligned column.** A row with an annotation is its
  shown text, then spaces up to the column the longest shown text among
  the rows shown reaches plus `gap` (2), counted in characters, then the
  annotation in `annotationFace` (`minibuffer.annotation`). A row with none
  has no trailing spaces. The column is counted in characters, which is
  exact under the shipped monospace default face; align-to stops in pixels
  are not built (`docs/design/text-and-display.md`, "Text is the only
  layout engine").
- **Group headers.** Only when the listing holds two groups or more
  (`Showing.grouped`) and `rows` is 2 or more: a header row, the group's
  name in `groupFace` (`minibuffer.group`), before the first candidate shown
  and before each candidate whose group differs from the one above it.
  Headers count toward `rows`, a header is never the last row, and the
  listing's order is never changed: a group that comes back gets its header
  again.
- **The window round the choice** (`window`). It starts where it last did
  (`Showing.first`, the last one when that is past the listing's end); at
  the chosen candidate when that is above it; and later, one at a time,
  headers counted, while the chosen candidate is at or past the end of the
  rows laid out from it (`lines`). With nothing chosen it is kept. So
  moving the choice past the last row shown scrolls the list by one.
- **Nothing.** Zero rows show nothing, and an empty listing shows no rows,
  its window at 0.

## Where an addition goes

| Addition | Where |
|---|---|
| A new display | A value here, in `shipped`, and run by `ModelTest.minibufferDisplayChecks` |
| A face the minibuffer display draws | A definition here, an entry of the vocabulary (`Editor/Face/Vocabulary.lean`) and a definition of `Palette.theme` (`Editor/Face.lean`) |

Pinned by `ModelTest.minibufferDisplayChecks`: its rule, the display
contract on it and its faces in the vocabulary.
-/

namespace Editor.Completion

namespace Displays

/-- How many rows the minibuffer display shows unless config sets another:
ten, what Emacs's vertico (`vertico-count`) and ivy (`ivy-height`) list by
default. -/
def rows : Nat :=
  10

/-- The spaces between the longest shown text and the annotations' column,
in characters. -/
def gap : Nat :=
  2

/-- The face of a candidate's row, unless it is the chosen one. -/
def candidateFace : FaceName :=
  ⟨"minibuffer.candidate"⟩

/-- The face of the chosen candidate's row. -/
def chosenFace : FaceName :=
  ⟨"minibuffer.chosen"⟩

/-- The face of a candidate's matched ranges, over its row's. -/
def matchFace : FaceName :=
  ⟨"minibuffer.match"⟩

/-- The face of a candidate's annotation. -/
def annotationFace : FaceName :=
  ⟨"minibuffer.annotation"⟩

/-- The face of a group's header. -/
def groupFace : FaceName :=
  ⟨"minibuffer.group"⟩

/-- A line of the minibuffer display's window: a group's header, or the
candidate at an index of the listing. -/
inductive Line where
  /-- The header of the group of this name. -/
  | header (name : String)
  /-- The candidate at this index of the listing. -/
  | candidate (index : Nat)
  deriving DecidableEq, Repr

/-- The lines of the window of `showing` that starts at `first` and is
`rows` tall: the candidates from `first` on, in order, until `rows` lines
are used; and while the listing is grouped and `rows` is 2 or more, a
header before the first and before each whose group differs from the one
above it, never as the last line. -/
def lines (showing : Showing) (first rows : Nat) : Array Line :=
  Id.run do
    let headed := showing.grouped && 2 ≤ rows
    let mut out : Array Line := #[]
    for index in [first:showing.listed.size] do
      if rows ≤ out.size then
        break
      let group := (showing.listed[index]?).bind (·.candidate.group)
      let above := (showing.listed[index - 1]?).bind (·.candidate.group)
      if headed && (index == first || group != above) then
        if rows < out.size + 2 then
          break
        out := out.push (.header (group.getD ""))
      out := out.push (.candidate index)
    return out

/-- Whether the window of `showing` from `first`, `rows` tall, shows the
candidate at `chosen`. -/
def shows (showing : Showing) (first rows chosen : Nat) : Bool :=
  (lines showing first rows).contains (.candidate chosen)

/-- The start at or after `start`, and at most `chosen`, of the first
window, `rows` tall, that shows the candidate at `chosen`, trying at most
`fuel` starts. -/
def advance (showing : Showing) (rows chosen : Nat) : (fuel start : Nat) → Nat
  | 0, start => start
  | fuel + 1, start =>
    if chosen ≤ start || shows showing start rows chosen then start
    else advance showing rows chosen fuel (start + 1)

/-- Where the window of `showing`, `rows` tall, starts now: where it last
did (`Showing.first`), or the last candidate when that is past the
listing's end, and 0 for an empty listing; at the chosen candidate when
that is before it; and otherwise later, one at a time, while the chosen
candidate is not shown. A window shows at most `rows` candidates, so the
starts before `chosen + 1 - rows` are skipped: none of them shows it.
With nothing chosen, or no rows, the start is kept. -/
def window (showing : Showing) (rows : Nat) : Nat :=
  let size := showing.listed.size
  let start := if size == 0 then 0 else min showing.first (size - 1)
  match showing.chosen with
  | some chosen =>
    if size ≤ chosen then start
    else
      if chosen < start then chosen
      else
        if rows == 0 then start
        else advance showing rows chosen (rows + 1) (max start (chosen + 1 - rows))
  | none => start

/-- The text a candidate is shown by: its label, or its text when it has
none. -/
def shownText (listed : Listed) : String :=
  listed.candidate.label.getD listed.text

/-- The ranges of `listed`'s text that are drawn on what shows it: all of
them with no label; with a label that ends the text, those within that end,
shifted onto the label, one that crosses into it cut at its start; and none
with any other label. -/
def labelRanges (listed : Listed) : Array Span :=
  match listed.candidate.label with
  | none => listed.ranges
  | some label =>
    if !listed.text.endsWith label then #[]
    else
      let offset := listed.text.utf8ByteSize - label.utf8ByteSize
      listed.ranges.filterMap fun range =>
        if range.stop ≤ offset then none
        else some { start := max range.start offset - offset, stop := range.stop - offset }

/-- The row of the candidate `listed`, chosen or not, its annotation, if
any, at `column` characters (`minibuffer`). -/
def candidateRow (listed : Listed) (chosen : Bool) (column : Nat) : Row :=
  let shown := oneLine (shownText listed)
  let (text, annotated) :=
    match listed.candidate.annotation with
    | some annotation =>
      let before := shown.pushn ' ' (column - shown.length)
      (before ++ oneLine annotation, some (before.utf8ByteSize, annotation.utf8ByteSize))
    | none => (shown, none)
  let span (start stop : Nat) (face : FaceName) : Array Decoration :=
    if start < stop then #[{ start, stop, face }] else #[]
  let ranges :=
    (labelRanges listed |>.filter fun range => range.stop ≤ shown.utf8ByteSize).flatMap fun range =>
      span range.start range.stop matchFace
  let annotation :=
    match annotated with
    | some (start, size) => span start (start + size) annotationFace
    | none => #[]
  { text
    decorations :=
      span 0 text.utf8ByteSize (if chosen then chosenFace else candidateFace) ++ ranges ++
        annotation }

/-- The row of the header of the group `name`. -/
def headerRow (name : String) : Row :=
  let text := oneLine name
  { text
    decorations :=
      if text.isEmpty then #[]
      else #[{ start := 0, stop := text.utf8ByteSize, face := groupFace }] }

/-- What the minibuffer display at `rows` rows shows of `showing`: the
lines of its window (`window`, `lines`), each a header's row or a
candidate's, the annotations at the column of the longest shown text among
them and `gap`. -/
def sheetOf (rows : Nat) (showing : Showing) : Sheet :=
  if showing.listed.isEmpty then {}
  else
    let first := window showing rows
    let laid := lines showing first rows
    let shownAt (index : Nat) : Option Listed := showing.listed[index]?
    let width :=
      laid.foldl
        (fun width line =>
          match line with
          | .candidate index => max width (((shownAt index).map (shownText · |>.length)).getD 0)
          | .header _ => width)
        0
    { first
      rows :=
        laid.filterMap fun line =>
          match line with
          | .header name => some (headerRow name)
          | .candidate index =>
            (shownAt index).map (candidateRow · (showing.chosen == some index) (width + gap)) }

/-- The minibuffer display, named `minibuffer`, showing at most `rows`
rows: the default display. -/
def minibuffer (rows : Nat := Displays.rows) : Display :=
  { name := "minibuffer", sheet := sheetOf rows }

/-- The displays that ship, which the `completion` package registers
(`Editor/Completion/Compiled.lean`). -/
def shipped : Array Display :=
  #[minibuffer]

end Displays

end Editor.Completion
