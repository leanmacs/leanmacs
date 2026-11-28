import Editor.Scene

/-!
# Foldable ranges

A *foldable range* is a byte range of a buffer's text that its owner says
may be shown as one placeholder row (`docs/design/text-and-display.md`,
"Folds, as built"). A buffer's owner declares its foldable ranges beside its
spans, stops and links (`Buffer.folds`, `BufferId.setFolds`), each with a
key of its own choosing, a placeholder (a text with its own faces) and an
initial state. Like spans and links, nothing moves a range on an edit: they
are for a generated buffer its owner alone writes. Toggling a range
(`BufferId.setFolded`, the folds mode's `fold-toggle`, `Editor/Folds.lean`)
changes only whether it is folded, never the text.

This module is plain data and the pure functions over it:

- **Declaring again keeps the toggles** (`Fold.merge`): a declared range
  whose key a current range has takes that range's `folded`, and any other
  range keeps its declared `folded`, which is its initial state. A key the
  owner no longer declares is gone.
- **The covered rows** (`Fold.coveredRows`): a range covers the rows that
  hold a byte of `[start, stop)`, a line break being the row's it ends, or
  the row of `start` when the range is empty; offsets past the end are the
  end. The rows are asked through whatever answers "which row holds this
  offset", the text port in the editor.
- **The shown folds** (`Fold.shown`): the folded ranges in order of start
  (the longer first of two with one start), dropping one whose first row an
  earlier shown one covers. So of nested folded ranges the outer one shows,
  and a range that only partly overlaps a shown one leaves its later rows
  visible. Layout applies the same rule to whatever it is handed
  (`Editor/Display.lean`, "Folds"), so the two never disagree.
- **Rows over the shown folds**: `Fold.stepRows` steps a row up or down
  counting a shown fold as one row (evil's `j` and `k`, the follow's range);
  `Fold.startsAt` is the shown fold a row starts; `Fold.cover` the shown
  fold that holds a row (a selection end widened over a fold).
- **Which range a toggle acts on** (`Fold.toggleTarget`), from the ranges
  whose covered rows hold the cursor's row: the outermost folded one is
  unfolded, and with none folded the innermost one is folded.
- `Folds.modeName` is the name of the folds mode here, beside the data, so
  the registry can put that mode's keymaps in a buffer with foldable ranges
  without importing the mode (`Editor/Config/Registry.lean`, `activeMaps`).

## Where an addition goes

| Addition | Where |
|---|---|
| A new lookup over a buffer's foldable ranges | A function here, pinned in `ModelTest.foldChecks` |
| A new command over folds | `Editor/Folds.lean` |

Pinned by `ModelTest.foldChecks`.
-/

namespace Editor

/-- A foldable range of a buffer's text, as its owner declares it. -/
structure Foldable where
  /-- The byte offset where it starts. -/
  start : Nat
  /-- The byte offset where it stops, not included. -/
  stop : Nat
  /-- The owner's name for it, kept across a regeneration of the buffer: a
  range whose key survives keeps its toggled state (`Fold.merge`). -/
  key : String
  /-- What its placeholder row says while it is folded. -/
  text : String
  /-- Spans of `text` drawn in a face, its offsets bytes of `text`. -/
  decorations : Array Decoration := #[]
  /-- Whether it is folded: its declared initial state until it is toggled,
  and its current state after. -/
  folded : Bool := false
  deriving DecidableEq, Repr

/-- The name of the folds mode (`Editor/Folds.lean`, `Folds.mode`), whose
keymaps go after the links mode's in a buffer with foldable ranges. -/
def Folds.modeName : String :=
  "folds"

/-- The scene's fold of `foldable`: its range and its placeholder. -/
def Foldable.toFold (foldable : Foldable) : Fold :=
  { start := foldable.start, stop := foldable.stop, text := foldable.text
    decorations := foldable.decorations }

/-- A foldable range with the first and the last row it covers. -/
abbrev Fold.Covered :=
  Foldable × Nat × Nat

/-- The ranges of `declared`, each folded as `old`'s range of the same key
is, or as declared when `old` has none of its key ("Declaring again keeps
the toggles", in the module docs). -/
def Fold.merge (old declared : Array Foldable) : Array Foldable :=
  declared.map fun range =>
    match old.find? (·.key == range.key) with
    | some kept => { range with folded := kept.folded }
    | none => range

/-- Each range of `folds` with the rows it covers, `rowOf` answering which
row holds an offset of a text `size` bytes long ("The covered rows", in the
module docs). -/
def Fold.coveredRows {m : Type → Type} [Monad m] (size : Nat) (rowOf : Nat → m Nat)
    (folds : Array Foldable) : m (Array Fold.Covered) :=
  folds.mapM fun range => do
    let start := min range.start size
    let stop := max start (min range.stop size)
    let first ← rowOf start
    let last ←
      if start < stop then
        rowOf (stop - 1)
      else
        pure first
    return (range, first, max first last)

/-- The row of `text`, `size` bytes long, that holds the byte `offset`: an
offset inside a character is on that character's row, and one past the end
on the last row. -/
def Fold.rowOf (text : TextId) (size offset : Nat) : TextM Nat := do
  let offset := min offset size
  -- A character is at most four bytes, so a boundary is at most three back.
  for back in [0:4] do
    if back ≤ offset then
      try
        return (← text.pointOf (offset - back)).row
      catch _ =>
        pure ()
  return 0

/-- Each range of `folds` with the rows of `text` it covers
(`Fold.coveredRows` through the text port). -/
def Fold.coveredOf (text : TextId) (folds : Array Foldable) : TextM (Array Fold.Covered) := do
  if folds.isEmpty then
    return #[]
  let size ← text.byteLength
  Fold.coveredRows size (Fold.rowOf text size) folds

/-- `covered` in order of start, the longer first of two with one start. -/
def Fold.ordered (covered : Array Fold.Covered) : Array Fold.Covered :=
  covered.insertionSort fun (a, _) (b, _) =>
    a.start < b.start || (a.start == b.start && a.stop > b.stop)

/-- The shown folds of `covered`: its folded ranges in order of start,
dropping one whose first row an earlier shown one covers ("The shown
folds", in the module docs). -/
def Fold.shown (covered : Array Fold.Covered) : Array Fold.Covered :=
  (Fold.ordered (covered.filter (·.1.folded))).foldl
    (fun shown fold =>
      match shown.back? with
      | some (_, _, last) => if fold.2.1 ≤ last then shown else shown.push fold
      | none => shown.push fold)
    #[]

/-- The shown fold of `shown` whose rows hold `row`, if one does. -/
def Fold.cover (shown : Array Fold.Covered) (row : Nat) : Option Fold.Covered :=
  shown.find? fun (_, first, last) => first ≤ row && row ≤ last

/-- The shown fold of `shown` whose first row is `row`, if one is. -/
def Fold.startsAt (shown : Array Fold.Covered) (row : Nat) : Option Fold.Covered :=
  shown.find? fun (_, first, _) => first == row

/-- The ranges of `covered` whose rows hold `row`, in order of start, the
longer first of two with one start: outermost first. -/
def Fold.covering (covered : Array Fold.Covered) (row : Nat) : Array Fold.Covered :=
  Fold.ordered (covered.filter fun (_, first, last) => first ≤ row && row ≤ last)

/-- The row `count` rows down (up when `down` is false) from `row`, a shown
fold of `shown` counting as one row: a step from a row a shown fold holds
goes past its last (or first) row, a row landed on inside a shown fold is
that fold's first, and the steps stop at the row `last` and at 0. -/
def Fold.stepRows (shown : Array Fold.Covered) (row count last : Nat) (down : Bool) : Nat :=
  let land (row : Nat) : Nat := ((Fold.cover shown row).map (·.2.1)).getD row
  (List.range count).foldl
    (fun here _ =>
      let held := Fold.cover shown here
      if down then
        let edge := (held.map (·.2.2)).getD here
        if edge < last then land (edge + 1) else here
      else
        let edge := (held.map (·.2.1)).getD here
        if 0 < edge then land (edge - 1) else here)
    (land row)

/-- The range a toggle at `row` acts on and the state it gives it: of the
ranges of `covered` whose rows hold `row`, the outermost folded one is
unfolded, and with none folded the innermost one is folded; `none` when no
range holds `row`. -/
def Fold.toggleTarget (covered : Array Fold.Covered) (row : Nat) : Option (String × Bool) :=
  let here := Fold.covering covered row
  match here.find? (·.1.folded) with
  | some (range, _) => some (range.key, false)
  | none => here.back?.map fun (range, _) => (range.key, true)

end Editor
