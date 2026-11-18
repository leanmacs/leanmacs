import Editor.Diff.Script
import Editor.VersionControl

/-!
# Hunks to stage

The pure core of staging and unstaging a hunk (`Editor/VersionControl/Stage.lean`):
how a hunk of the diff service (`Diff.Hunk`, byte ranges of whole lines)
becomes a hunk the version-control interface applies (`LineHunk`,
`Editor/VersionControl.lean`), and which hunk is on the cursor's line.

- **The context** (`Hunk.context`) is 3 lines on each side, git's default,
  taken from the index, the text the change is applied to: the old side of
  a hunk of the file against the index (`HunkSide.stage`), the new side of a
  hunk of the index against `HEAD` (`HunkSide.unstage`). It is clamped at the
  index's start and end, so short context is only ever at an end, where
  git then holds the hunk.
- **A hunk is located** (`LineHunk.locate`) through a `Lines` of each
  text: the row of an offset, the offset of a row and a slice. The texts
  as strings (`Lines.ofText`, used by `LineHunk.ofTexts`) and as snapshots
  (`Stage.lean`) are both one, so the one walk is pinned on strings.
- **Rows** are counted in line feeds, from 0: `oldLine` and `newLine` are
  the rows of the first context line, in the old and the new text.
- **The hunk on a line** (`Hunks.pick`), a line `[start, stop)` of the new
  text: the first hunk whose new range overlaps it; otherwise a removal
  (an empty new range) at its start, where the gutter draws its `-`;
  otherwise a removal at the text's end when the line is the last.
- **A line carried to the old text** (`Hunks.toOld`): outside every hunk
  it is shifted by the sizes of the hunks before it; inside one it is
  that hunk's old range. So the cursor's line of a buffer is carried to a
  line of the index, to pick among the hunks of the index against
  `HEAD`.

Pinned by `ModelTest.hunkChecks`.
-/

namespace Editor.VersionControl

/-- How many lines of context a hunk carries on each side: 3, git's
default. -/
def Hunk.context : Nat :=
  3

/-- Which way a hunk goes, which says which of its texts is the index: the
old one of a hunk of the file against the index, the new one of a hunk of
the index against `HEAD`. -/
inductive HunkSide where
  /-- A hunk of the file against the index, to stage. -/
  | stage
  /-- A hunk of the index against `HEAD`, to unstage. -/
  | unstage
  deriving DecidableEq, Repr

/-- What locating a hunk asks of a text, in a monad `m`. -/
structure Lines (m : Type → Type) where
  /-- Its length in bytes. -/
  size : Nat
  /-- How many rows it has: one more than its line feeds. -/
  rows : Nat
  /-- The row, from 0, of a byte offset. -/
  rowOf : Nat → m Nat
  /-- The byte offset where a row starts, for a row it has. -/
  rowStart : Nat → m Nat
  /-- Its bytes from a start up to, not including, a stop. -/
  slice : Nat → Nat → m String

/-- Where `row` starts in `lines`, or its end for a row past its last. -/
def Lines.startOf {m : Type → Type} [Monad m] (lines : Lines m) (row : Nat) : m Nat :=
  if row < lines.rows then lines.rowStart row else pure lines.size

/-- `text` as a `Lines`. -/
def Lines.ofText (text : String) : Lines Id :=
  let bytes := text.toUTF8
  let starts :=
    (List.range bytes.size).foldl
      (fun (starts : Array Nat) offset =>
        if bytes.get! offset == 10 then starts.push (offset + 1) else starts)
      #[0]
  { size := bytes.size, rows := starts.size
    rowOf := fun offset => (starts.filter (· ≤ offset)).size - 1
    rowStart := fun row => starts[row]?.getD bytes.size
    slice := fun start stop => (String.fromUTF8? (bytes.extract start stop)).getD "" }

/-- The hunk of the lines `before`, `removed`, `added` and `after`, each text
split at its line feeds, which are kept (`linesOf`). -/
def LineHunk.make (oldLine newLine : Nat) (before removed added after : String) : LineHunk :=
  { oldLine, newLine, before := linesOf before, removed := linesOf removed
    added := linesOf added, after := linesOf after }

/-- The `LineHunk` of `hunk`, a hunk of `old` against `new` going `side`, its
context taken from the index's text ("The context", in the module docs). -/
def LineHunk.locate {m : Type → Type} [Monad m] (side : HunkSide) (old new : Lines m)
    (hunk : Diff.Hunk) : m LineHunk := do
  let (index, start, stop) :=
    match side with
    | .stage => (old, hunk.oldStart, hunk.oldStop)
    | .unstage => (new, hunk.newStart, hunk.newStop)
  let startRow ← index.rowOf start
  let stopRow ← index.rowOf stop
  let first := startRow - min Hunk.context startRow
  let beforeStart ← index.startOf first
  let afterStop ←
    if stop == index.size then
      pure index.size
    else
      index.startOf (stopRow + Hunk.context)
  let before ← index.slice beforeStart start
  let after ← index.slice stop afterStop
  let count := startRow - first
  let oldRow ← old.rowOf hunk.oldStart
  let newRow ← new.rowOf hunk.newStart
  return LineHunk.make (oldRow - count) (newRow - count) before
      (← old.slice hunk.oldStart hunk.oldStop) (← new.slice hunk.newStart hunk.newStop) after

/-- The `LineHunk` of `hunk`, a hunk of the text `old` against `new` going
`side` (`LineHunk.locate`). -/
def LineHunk.ofTexts (side : HunkSide) (old new : String) (hunk : Diff.Hunk) : LineHunk :=
  LineHunk.locate side (Lines.ofText old) (Lines.ofText new) hunk

/-- The hunk among `hunks` on the line `[start, stop)` of their new text, whose
length is `size` ("The hunk on a line", in the module docs). -/
def Hunks.pick (hunks : Diff.Hunks) (start stop size : Nat) : Option Diff.Hunk :=
  let removal (hunk : Diff.Hunk) := hunk.newStart == hunk.newStop
  (hunks.find? fun hunk => !removal hunk && hunk.newStart < stop && start < hunk.newStop) <|>
    (hunks.find? fun hunk => removal hunk && hunk.newStart == start) <|>
    hunks.find? fun hunk => removal hunk && stop == size && hunk.newStart == size

/-- The line `[start, stop)` of the new text of `hunks` carried to their old
text ("A line carried to the old text", in the module docs). -/
def Hunks.toOld (hunks : Diff.Hunks) (start stop : Nat) : Nat × Nat :=
  match
    hunks.find? fun hunk =>
      hunk.newStart < stop && start < hunk.newStop ||
        hunk.newStart == hunk.newStop && hunk.newStart == start && start == stop with
  | some hunk => (hunk.oldStart, hunk.oldStop)
  | none =>
    let shift : Int :=
      (hunks.filter (·.newStop ≤ start)).foldl
        (fun shift hunk =>
          shift + ((hunk.oldStop - hunk.oldStart : Nat) : Int) -
            ((hunk.newStop - hunk.newStart : Nat) : Int))
        0
    ((start + shift).toNat, (stop + shift).toNat)

end Editor.VersionControl
