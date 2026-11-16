import Editor.Display.Model
import Editor.Text.Real

/-!
# The display interface where there is no window

The headless host has no window and no layout, but the command loop
publishes a scene after every event and a command may ask the display a
question of layout. The recorder answers both, in `IO`
(`DisplayRecorder.handle`, a `DisplayHandler`):

- **a publish** is kept: the recorder holds the last scene published and how
  many have been, which the host's `scene` directive prints;
- **a query** is answered with the display model's rule
  (`Editor/Display/Model.lean`) over the text of the one snapshot it names,
  read from the library through the read half of the real binding's table
  of snapshots (`SnapshotReader`). A snapshot the table no longer holds,
  because a command released it, is refused with `noSuchSnapshot`, as the
  real binding refuses it.

It is the one place the model's layout rule runs outside a test, because a
host with no window has no layout to ask. An editor with a window asks the
real binding (the display pipeline's) every time.

`contract-test` holds it to the display interface's contract
(`Editor/Display/Contract.lean`) over real snapshots, at the cell sizes
`model-test` holds the model to it at.
-/

namespace Editor

/-- The display interface of a host with no window: the scenes published,
and layout answered by the model's rule over the library's snapshots. -/
structure DisplayRecorder where
  /-- The cells it lays text out in. -/
  cells : Display.Cells
  /-- Where it reads the text of a snapshot: the read half of the table the
  text binding writes. -/
  snapshots : SnapshotReader
  /-- The last scene published, if one has been. -/
  last : IO.Ref (Option Scene)
  /-- How many scenes have been published. -/
  count : IO.Ref Nat

namespace DisplayRecorder

/-- A recorder in `cells` that reads snapshots through `snapshots`, with no
scene published. -/
def new (cells : Display.Cells) (snapshots : SnapshotReader) : BaseIO DisplayRecorder :=
  return { cells, snapshots, last := ← IO.mkRef none, count := ← IO.mkRef 0 }

/-- A display model in the recorder's cells that knows `snapshot`'s text, as
the library holds it now; one that knows no text when the table does not
hold the snapshot. -/
def modelOf (recorder : DisplayRecorder) (snapshot : SnapshotId) : IO DisplayModel := do
  let some held ← recorder.snapshots.find? snapshot | return { cells := recorder.cells }
  return { cells := recorder.cells, texts := #[(snapshot, ← held.read)] }

/-- Answers `request`: a publish is kept as the last scene and counted, and a
query is answered by the model's rule over the snapshot it names. -/
def handle (recorder : DisplayRecorder) : DisplayHandler
  | .publish scene => do
    recorder.last.set (some scene)
    recorder.count.modify (· + 1)
  | .rows query => do
    return (← recorder.modelOf query.snapshot).rows query
  | .move query => do
    return (← recorder.modelOf query.snapshot).move query
  | .heights => return recorder.cells.heights
  -- There is no window to ask.
  | .frame _ => return ()

/-- The last scene published, if one has been. -/
def last? (recorder : DisplayRecorder) : BaseIO (Option Scene) :=
  recorder.last.get

/-- How many scenes have been published. -/
def published (recorder : DisplayRecorder) : BaseIO Nat :=
  recorder.count.get

end DisplayRecorder

end Editor
