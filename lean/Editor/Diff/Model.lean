import Editor.Diff.Script

/-!
# The pure model of a line diff

What the diff request answers (`Editor/Diff.lean`), as a pure function of two
texts and a line limit (`DiffModel.script`), so the logic above the job port
is tested by `lake test` alone. The file model answers a job's diff request
with it (`FileModel.diff`, `Editor/File/Model.lean`), over the snapshots it
holds.

It has the library's core (`crates/editor-diff`) by its own route:

- **The lines** are cut at each line feed, which stays with its line; a text
  that does not end in one has a last line without one, and an empty text
  has none.
- **The common head and tail lines** are stripped first, the tail from what
  the head left.
- **Over the limit** (either side of the middle longer than `limit` lines)
  the middle is one hunk. Otherwise its hunks are an LCS of its lines, found
  by the textbook table: quadratic, and plainly right for the model's texts
  of a few lines. The library's engine is imara-diff's histogram diff, which
  may pick other hunks of the same texts; the contract
  (`JobContract.diffProperties`) holds only what both keep.
- **Each hunk is trimmed** to the longest common prefix and suffix of its
  two byte ranges that end on a character boundary of both texts, the
  suffix from what the prefix left. A byte that continues a character is no
  boundary, so a character that differs only in its trailing bytes is
  replaced whole, and an escape, one character of four bytes, is one unit.
- **Hunks** (`DiffModel.hunks`) are the same line hunks, untrimmed, as byte
  ranges of whole lines of both texts, with none empty on both sides.
- **The steps**: a retain between two hunks, and a delete then an insert for
  each hunk; no step of length 0, no two retains side by side, and hunks
  that touch made one delete and one insert. Equal texts give one retain.
-/

namespace Editor

namespace DiffModel

/-- Where each line of `bytes` starts, and then where the last one ends: one
more offset than lines. -/
def lineStarts (bytes : ByteArray) : Array Nat :=
  Id.run do
    let mut starts := #[0]
    for index in [0:bytes.size] do
      if bytes.get! index == 10 then
        starts := starts.push (index + 1)
    if starts.back! != bytes.size then
      starts := starts.push bytes.size
    return starts

/-- The lines of `bytes`, each with its line feed. -/
def lines (bytes : ByteArray) : Array ByteArray :=
  let starts := lineStarts bytes
  (Array.range (starts.size - 1)).map fun index => bytes.extract starts[index]! starts[index + 1]!

/-- A run of lines of the old text replaced by a run of the new, as indices of
their lines, each from a start up to, not including, a stop. -/
structure Hunk where
  /-- The first old line. -/
  oldStart : Nat
  /-- After the last old line. -/
  oldStop : Nat
  /-- The first new line. -/
  newStart : Nat
  /-- After the last new line. -/
  newStop : Nat
  deriving DecidableEq, Repr

/-- The hunks of an LCS of the lines `old` and `new`: of two lines that could
each be matched, the old text's is given up first. -/
def lcsHunks (old new : Array ByteArray) : Array Hunk :=
  Id.run do
    -- `longest[i][j]`: the LCS of `old[i:]` and `new[j:]`.
    let mut longest : Array (Array Nat) :=
      Array.replicate (old.size + 1) (Array.replicate (new.size + 1) 0)
    for back in [0:old.size] do
      let i := old.size - 1 - back
      for backNew in [0:new.size] do
        let j := new.size - 1 - backNew
        let value :=
          if old[i]! == new[j]! then longest[i + 1]![j + 1]! + 1
          else max longest[i + 1]![j]! longest[i]![j + 1]!
        longest := longest.modify i (·.set! j value)
    let mut hunks := #[]
    let mut (i, j) := (0, 0)
    let mut open? : Option (Nat × Nat) := none
    for _ in [0:old.size + new.size] do
      if i ≥ old.size ∧ j ≥ new.size then
        break
      if i < old.size ∧ j < new.size ∧ old[i]! == new[j]! then
        if let some (oldStart, newStart) := open? then
          hunks := hunks.push { oldStart, oldStop := i, newStart, newStop := j }
          open? := none
        i := i + 1
        j := j + 1
      else
        if open?.isNone then
          open? := some (i, j)
        if j ≥ new.size ∨ (i < old.size ∧ longest[i + 1]![j]! ≥ longest[i]![j + 1]!) then
          i := i + 1
        else
          j := j + 1
    if let some (oldStart, newStart) := open? then
      hunks := hunks.push { oldStart, oldStop := i, newStart, newStop := j }
    return hunks

/-- The byte ranges `old` of `oldBytes` and `new` of `newBytes`, each a start
and a stop, less their longest common prefix and then their longest common
suffix that end on a character boundary of both. -/
def trim (oldBytes newBytes : ByteArray) (old new : Nat × Nat) : (Nat × Nat) × (Nat × Nat) :=
  Id.run do
    let both (a b : Nat) := Diff.boundary oldBytes a && Diff.boundary newBytes b
    let shorter := min (old.2 - old.1) (new.2 - new.1)
    let mut lead := 0
    while lead < shorter && oldBytes.get! (old.1 + lead) == newBytes.get! (new.1 + lead) do
      lead := lead + 1
    while lead > 0 && !both (old.1 + lead) (new.1 + lead) do
      lead := lead - 1
    let left := shorter - lead
    let mut trail := 0
    while trail < left && oldBytes.get! (old.2 - 1 - trail) == newBytes.get! (new.2 - 1 - trail) do
      trail := trail + 1
    while trail > 0 && !both (old.2 - trail) (new.2 - trail) do
      trail := trail - 1
    return ((old.1 + lead, old.2 - trail), (new.1 + lead, new.2 - trail))

/-- A script as it is built: the steps so far, and the changed range being
built, as the bytes it removes and what it puts in. -/
structure Builder where
  /-- The steps so far. -/
  steps : Diff.Script := #[]
  /-- The bytes the changed range removes. -/
  deleted : Nat := 0
  /-- What it puts in: a start in the new text and a count. -/
  inserted : Option (Nat × Nat) := none

namespace Builder

/-- Ends the changed range being built. -/
def flush (builder : Builder) : Builder :=
  let steps :=
    if builder.deleted > 0 then builder.steps.push (.delete builder.deleted) else builder.steps
  let steps :=
    match builder.inserted with
    | some (start, count) => steps.push (.insert start count)
    | none => steps
  { steps }

/-- Keeps `count` bytes; nothing for 0. -/
def retain (builder : Builder) (count : Nat) : Builder :=
  if count == 0 then builder
  else
    let builder := builder.flush
    match builder.steps.back? with
    | some (.retain kept) =>
      { builder with steps := builder.steps.pop.push (.retain (kept + count)) }
    | _ => { builder with steps := builder.steps.push (.retain count) }

/-- Removes `count` bytes. -/
def delete (builder : Builder) (count : Nat) : Builder :=
  { builder with deleted := builder.deleted + count }

/-- Puts in the `count` bytes of the new text from `start`; nothing for 0. -/
def insert (builder : Builder) (start count : Nat) : Builder :=
  if count == 0 then builder
  else
    { builder with
      inserted :=
        match builder.inserted with
        | some (first, soFar) => some (first, soFar + count)
        | none => some (start, count) }

/-- The script, for an old text of `size` bytes: one retain of the whole when
nothing changed. -/
def finish (builder : Builder) (size : Nat) : Diff.Script :=
  let steps := builder.flush.steps
  if
      steps.all
        (fun step =>
          match step with
          | .retain _ => true
          | _ => false) then
    #[.retain size]
  else steps

end Builder

/-- The line hunks of `oldLines` and `newLines`: the common head and tail
stripped, and the middle's LCS hunks when each side of it is at most `limit`
lines, or the middle as one hunk otherwise. The rules `script` and `hunks`
share, written once. -/
def lineHunks (oldLines newLines : Array ByteArray) (limit : Nat) : Array Hunk :=
  let shorter := min oldLines.size newLines.size
  let head :=
    ((List.range shorter).takeWhile fun index => oldLines[index]! == newLines[index]!).length
  let tail :=
    ((List.range (shorter - head)).takeWhile fun back =>
        oldLines[oldLines.size - 1 - back]! == newLines[newLines.size - 1 - back]!).length
  let (oldStop, newStop) := (oldLines.size - tail, newLines.size - tail)
  if head == oldStop ∧ head == newStop then #[]
  else
    if oldStop - head ≤ limit ∧ newStop - head ≤ limit then
      (lcsHunks (oldLines.extract head oldStop) (newLines.extract head newStop)).map fun hunk =>
        { oldStart := hunk.oldStart + head, oldStop := hunk.oldStop + head
          newStart := hunk.newStart + head, newStop := hunk.newStop + head }
    else #[{ oldStart := head, oldStop, newStart := head, newStop }]

/-- The edit script that turns `old` into `new`, with the middle diffed when
each side of it is at most `limit` lines. The module docs have the rules. -/
def script (old new : String) (limit : Nat) : Diff.Script :=
  let (oldBytes, newBytes) := (old.toUTF8, new.toUTF8)
  let (oldStarts, newStarts) := (lineStarts oldBytes, lineStarts newBytes)
  let hunks := lineHunks (lines oldBytes) (lines newBytes) limit
  let (builder, reached) :=
    hunks.foldl
      (fun (builder, reached) hunk =>
        let (removed, added) :=
          trim oldBytes newBytes (oldStarts[hunk.oldStart]!, oldStarts[hunk.oldStop]!)
            (newStarts[hunk.newStart]!, newStarts[hunk.newStop]!)
        if removed.1 == removed.2 ∧ added.1 == added.2 then (builder, reached)
        else
          ((((builder.retain (removed.1 - reached)).delete (removed.2 - removed.1)).insert added.1
              (added.2 - added.1)),
            removed.2))
      (({} : Builder), 0)
  (builder.retain (oldBytes.size - reached)).finish oldBytes.size

/-- The hunks that turn `old` into `new`, as byte ranges of whole lines in
both: the line hunks `script` trims, untrimmed, and none empty on both sides.
Equal texts have none. -/
def hunks (old new : String) (limit : Nat) : Diff.Hunks :=
  let (oldBytes, newBytes) := (old.toUTF8, new.toUTF8)
  let (oldStarts, newStarts) := (lineStarts oldBytes, lineStarts newBytes)
  (lineHunks (lines oldBytes) (lines newBytes) limit).filterMap fun hunk =>
    if hunk.oldStart == hunk.oldStop ∧ hunk.newStart == hunk.newStop then none
    else
      some
        { oldStart := oldStarts[hunk.oldStart]!, oldStop := oldStarts[hunk.oldStop]!
          newStart := newStarts[hunk.newStart]!, newStop := newStarts[hunk.newStop]! }

end DiffModel

end Editor
