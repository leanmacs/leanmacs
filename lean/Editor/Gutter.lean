import Editor.State

/-!
# Gutter marks, carried to the revision a view shows

A buffer's gutter (`Buffer.gutter`, `Editor/State.lean`, "Buffers") holds
marks as byte ranges of its text at one revision: the revision of the text
its owner computed them from, which an edit made since has moved on from.
A view shows its text at its own revision, so before the marks are drawn
they are carried there through the text's log (`marksOf`), by a pure
function of the patch (`carry`). The marks follow every edit at once, and
their owner replaces them when it has computed them again (the
version-control gutter, `Editor/VersionControl/Gutter.lean`, does that off
the editor thread).

## The rules

- **A start maps after, a stop before** (`mapOffset`): an insertion at a
  mark's start goes before the mark, and one at its stop after it, so a
  mark grows only by what is put inside it.
- **A mark with bytes whose bytes were all deleted is dropped.** A mark
  with none, which marks the line that holds its offset (lines removed
  there), maps its offset after, and stays empty.
- **A forgotten log draws no mark**: the patch cannot be had, so where the
  marks would go is not known, and none is drawn until their owner sets
  them again.
- **Clipped to the view's range** as a view's decorations are
  (`Loop.spansIn`, `Editor/Loop.lean`): a mark with bytes is cut to the
  range and dropped when nothing is left; an empty one is kept when its
  offset is in the range, its ends included.

Pinned by `ModelTest.gutterCarryChecks`.
-/

namespace Editor.Gutter

/-- Where `offset` of the text before `patch` is in the text after it, an
offset inside a replaced range, or at an insertion, going to the replacement's
stop when `after` and to its start otherwise. -/
def mapOffset (patch : Patch) (after : Bool) (offset : Nat) : Nat :=
  Id.run do
    let mut shift : Int := 0
    for edit in patch.edits do
      if offset < edit.old.start then
        return (offset + edit.new.start - edit.old.start : Int).toNat
      if offset ≤ edit.old.stop then
        return if after then edit.new.stop else edit.new.start
      shift := (edit.new.stop : Int) - edit.old.stop
    return ((offset : Int) + shift).toNat

/-- `mark` carried through `patch` ("The rules", in the module docs): `none`
when it had bytes and all of them were deleted. -/
def carry (patch : Patch) (mark : GutterMark) : Option GutterMark :=
  let start := mapOffset patch true mark.start
  if mark.start < mark.stop then
    let stop := mapOffset patch false mark.stop
    if start < stop then
      some
        { mark with
          start, stop }
    else none
  else
    some
      { mark with
        start, stop := start }

/-- `marks` clipped to `start` through `stop` ("The rules", in the module
docs), in order. -/
def clipped (marks : Array GutterMark) (start stop : Nat) : Array GutterMark :=
  marks.filterMap fun mark =>
    if mark.start < mark.stop then
      let cut :=
        { mark with
          start := max mark.start start, stop := min mark.stop stop }
      if cut.start < cut.stop then some cut else none
    else if start ≤ mark.start && mark.start ≤ stop then some mark else none

/-- The marks of `gutter`, a gutter of `text`, as `snapshot` of it shows them,
from `start` through `stop` of it: carried from the gutter's revision to the
snapshot's through the text's log, and clipped ("The rules", in the module
docs). None for no gutter, for a log that cannot say what changed since, and
for a snapshot of a revision the log does not reach. -/
def marksOf (text : TextId) (gutter : Option Buffer.Gutter) (snapshot : SnapshotId)
    (start stop : Nat) : TextM (Array GutterMark) := do
  let some gutter := gutter | return #[]
  let revision ← snapshot.revision
  if gutter.revision == revision then
    return clipped gutter.marks start stop
  try
    let patch ← text.changesSince gutter.revision
    if patch.revision != revision then
      return #[]
    return clipped (gutter.marks.filterMap (carry patch)) start stop
  catch _ =>
    return #[]

end Editor.Gutter
