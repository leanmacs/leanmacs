import Editor.Fold
import Editor.Link
import Editor.Scene

/-!
# A rendered Markdown document, described

What rendering a Markdown document makes (`docs/design/text-and-display.md`,
"Rendered markdown, as built"), as plain data: no Markdown is left in it,
and it says nothing of layout. It is the shape phase 7 lifts into the
core's rich-text description.

- **A piece** (`Piece`) is one top-level block rendered: its text, with the
  markup left out, and, at offsets of that text, its spans (each a face
  over a range, outer first, so a later one is drawn over an earlier one),
  its links, its tables, its headings, its fenced code blocks and its wrap
  indents. `Piece.shift` moves its offsets; `Piece.join` puts pieces one
  after another with a separator between.
- **Indents** (`Piece.indents`) are layout-free data, as links are: where
  the visual lines of a range's rows start, in points or, the hanging form,
  after a row's first bytes (`WrapIndent`, `Editor/Scene.lean`). Nothing
  is measured for them. `Piece.indentedBy` puts a whole piece a step in, a
  block quote's blocks or a list item's: one indent over it, listed first,
  then each it had a step further in, a lead left as it is, since it is
  measured from the row's shifted start. Of two over a row the later
  listed wins.
- **The description** (`Description`) is the pieces joined by one empty
  line (`Description.ofPieces`), with its foldable ranges made from the
  headings and fences.
- **Folds** (`foldsOf`) are made from the whole document on every update,
  since an append can move where a heading's range ends:
  - each heading is a range from its text's start to the start of the
    next heading of the same or a higher level, or to the end. Its key is
    `heading <n>`, n its ordinal in the document from 1, and its
    placeholder its text in its heading face and ` …`;
  - each fenced code block is a range over its rows. Its key is
    `code <n>`, and its placeholder `<language or code>, <k> lines` (`1
    line` for one) in `text.code-block`. A fence with no rows renders as
    an empty row, and its range is the empty one at that row's start,
    which covers that row (`Fold.coveredRows`), `0 lines`;
  - every one is declared unfolded. A buffer's `setFolds` merges by key,
    so a toggle survives a regeneration (`Fold.merge`).
- **A table** (`Table`) is rows of cell ranges of the text. It is the one
  part measured when the description is applied: a cell's width is the
  display's, so its align-to stops are made then
  (`Editor/Markdown/View.lean`).
- **The options** (`Options`) are what a render takes beyond the document:
  the root a relative link is resolved against, the gap between table
  columns, the indent step of a list item's or a quote's blocks, and the
  face a fence's capture is drawn in, by grammar and
  capture name, which the caller resolves from config, so the renderer
  never reads a language table.

This module, and every module of the renderer, sits below the editor's
state (`Editor/State.lean` keeps a buffer's document): it imports only the
scene's types, links and folds.

## Where an addition goes

| Addition | Where |
|---|---|
| A new part of a rendered block | A field of `Piece`, moved by `Piece.shift`, kept by `Piece.append` (and so `Piece.join`), and gathered by `Description.ofPieces` |
| A new way a block is indented | A use of `Piece.indentedBy`, or an indent of the piece, in its case of `Editor/Markdown/Block.lean` |
| A new document-wide part (made from every piece, on every update) | `Description.ofPieces` |

Pinned by the rendered-markdown checks of `ModelTest/Editor/Markdown/Doc.lean`.
-/

namespace Editor.Markdown

/-- What a render takes beyond the document. -/
structure Options where
  /-- The directory a relative link or `path:line` is resolved against; with
  none, a relative one is not linked. -/
  root : Option System.FilePath := none
  /-- The gap between a table column's widest cell and the next column, in
  points. -/
  gap : Nat := 16
  /-- How far a list item's blocks and a block quote's are indented, a
  nesting level, in points. -/
  indent : Nat := 16
  /-- The face a fence's capture is drawn in, by its layer's grammar and the
  capture's name; `none` leaves it in `text.code-block`. -/
  faces : String → String → Option FaceName := fun _ _ => none

/-- A table: its rows, each the ranges of its cells in the text, the header
first. A row with a missing cell is shorter. -/
structure Table where
  /-- The rows, each its cells as a start and a stop. -/
  rows : Array (Array (Nat × Nat)) := #[]
  deriving DecidableEq, Repr, Inhabited

/-- One top-level block rendered: its text and, at offsets of that text, its
parts. -/
structure Piece where
  /-- Its text, with the markup left out. -/
  text : String := ""
  /-- Its spans, outer first: a later one is drawn over an earlier one. -/
  spans : Array Decoration := #[]
  /-- Its links. -/
  links : Array Link := #[]
  /-- Its tables. -/
  tables : Array Table := #[]
  /-- Its headings, each its level, and the start and the stop of its
  text. -/
  headings : Array (Nat × Nat × Nat) := #[]
  /-- Its fenced code blocks, each the start and the stop of its rows, and
  its language, or the empty string for none. -/
  codes : Array (Nat × Nat × String) := #[]
  /-- Its wrap indents, in order: a later one over a row wins. -/
  indents : Array WrapIndent := #[]
  deriving DecidableEq, Repr, Inhabited

/-- A rendered document: its text, its spans, its tables, its links, its
wrap indents and its foldable ranges. -/
structure Description where
  /-- Its text. -/
  text : String := ""
  /-- Its spans, outer first. -/
  spans : Array Decoration := #[]
  /-- Its tables, measured when it is applied. -/
  tables : Array Table := #[]
  /-- Its links. -/
  links : Array Link := #[]
  /-- Its foldable ranges, every one unfolded. -/
  folds : Array Foldable := #[]
  /-- Its wrap indents, in order. -/
  indents : Array WrapIndent := #[]
  deriving DecidableEq, Repr, Inhabited

/-- The bytes of `source` from `start` up to `stop`, as a string; the empty
string when they do not end between characters. -/
def slice (source : String) (start stop : Nat) : String :=
  (String.fromUTF8? (source.toUTF8.extract start stop)).getD ""

/-- A span of `face` from `start` to `stop`. -/
def span (start stop : Nat) (face : String) : Decoration :=
  { start, stop, face := ⟨face⟩ }

namespace Piece

/-- `piece` with every offset moved `by` bytes on. -/
def shift (piece : Piece) (distance : Nat) : Piece :=
  { piece with
    spans :=
      piece.spans.map fun span =>
        { span with
          start := span.start + distance, stop := span.stop + distance }
    links :=
      piece.links.map fun link =>
        { link with
          start := link.start + distance, stop := link.stop + distance }
    tables :=
      piece.tables.map fun table =>
        { rows := table.rows.map (·.map fun (start, stop) => (start + distance, stop + distance)) }
    headings :=
      piece.headings.map fun (level, start, stop) => (level, start + distance, stop + distance)
    codes :=
      piece.codes.map fun (start, stop, language) => (start + distance, stop + distance, language)
    indents :=
      piece.indents.map fun indent =>
        { indent with
          start := indent.start + distance, stop := indent.stop + distance } }

/-- `before`, then `separator`, then `after`, with `after`'s parts moved past
the two. -/
def append (before after : Piece) (separator : String) : Piece :=
  let after := after.shift (before.text.utf8ByteSize + separator.utf8ByteSize)
  { text := before.text ++ separator ++ after.text, spans := before.spans ++ after.spans
    links := before.links ++ after.links, tables := before.tables ++ after.tables
    headings := before.headings ++ after.headings, codes := before.codes ++ after.codes
    indents := before.indents ++ after.indents }

/-- `pieces` one after another, `separator` between each two. -/
def join (pieces : Array Piece) (separator : String) : Piece :=
  match pieces.toList with
  | [] => {}
  | first :: rest => rest.foldl (fun joined piece => joined.append piece separator) first

/-- `piece` after `text`, with its parts moved past it. -/
def after (text : String) (piece : Piece) : Piece :=
  ({ text } : Piece).append piece ""

/-- `piece` with `spans` before its own: drawn under them. -/
def under (spans : Array Decoration) (piece : Piece) : Piece :=
  { piece with spans := spans ++ piece.spans }

/-- `piece` a step of `step` points in ("Indents", in the module docs): one
indent over its whole text, its first lines and the rest `step` in, listed
first, then each indent it had with `step` added to its first-line indent
and to a continuation in points; a lead is left as it is, since it is
measured from the row's start, which the step has moved. -/
def indentedBy (step : Nat) (piece : Piece) : Piece :=
  let whole : WrapIndent :=
    { start := 0, stop := piece.text.utf8ByteSize, first := step, rest := .points step }
  let deeper :=
    piece.indents.map fun indent =>
      { indent with
        first := indent.first + step
        rest :=
          match indent.rest with
          | .points x => .points (x + step)
          | .lead bytes => .lead bytes }
  { piece with indents := #[whole] ++ deeper }

end Piece

/-- The separator of two top-level blocks: one empty line. -/
def blockSeparator : String :=
  "\n\n"

/-- The rendered offset each of `pieces` starts at, joined by
`blockSeparator`. -/
def offsetsOf (pieces : Array Piece) : Array Nat :=
  (pieces.foldl
      (fun (offsets, offset) piece =>
        (offsets.push offset, offset + piece.text.utf8ByteSize + blockSeparator.utf8ByteSize))
      (#[], 0)).1

/-- The foldable ranges of `piece`, a whole document's ("Folds", in the
module docs): each heading's, then each fence's, in order of
start, every one unfolded. -/
def foldsOf (piece : Piece) : Array Foldable :=
  let size := piece.text.utf8ByteSize
  let headings :=
    piece.headings.zipIdx.map fun ((level, start, stop), index) =>
      let next :=
        (piece.headings.extract (index + 1) piece.headings.size).find? fun (other, _, _) =>
          other ≤ level
      let text := slice piece.text start stop
      ({  start, stop := (next.map (·.2.1)).getD size, key := s!"heading {index + 1}"
          text := text ++ " …",
          decorations := #[span 0 text.utf8ByteSize s!"text.heading.{level}"] } : Foldable)
  let codes :=
    piece.codes.zipIdx.map fun ((start, stop, language), index) =>
        let rows := if start < stop then (slice piece.text start stop).splitOn "\n" |>.length else 0
        let text :=
        s!"{if language.isEmpty then "code" else language}, {rows} {if rows == 1 then "line" else "lines"}"
        ({
          start, stop, key := s!"code {index + 1}", text
          decorations := #[span 0 text.utf8ByteSize "text.code-block"] } : Foldable)
  (headings ++ codes).insertionSort fun a b => a.start < b.start

/-- The description of a document whose top-level blocks rendered to
`pieces`: the pieces joined by one empty line, and its foldable ranges. -/
def Description.ofPieces (pieces : Array Piece) : Description :=
  let joined := Piece.join pieces blockSeparator
  { text := joined.text, spans := joined.spans, tables := joined.tables, links := joined.links
    folds := foldsOf joined, indents := joined.indents }

end Editor.Markdown
