import Editor.Api
import Editor.Command.Call
import Editor.Gutter.Track
import Editor.VersionControl.Git
import Editor.VersionControl.Show
import FilesApi

/-!
# The version-control gutter

A buffer of a tracked file shows, in a column before its text, which of its
lines were added, removed and changed against the file at `HEAD`: the
buffer's gutter (`Buffer.gutter`, `Editor/State.lean`; drawn by layout,
`Editor/Gutter.lean` carrying it through edits). The content at `HEAD` is
the buffer's old text: fetched once a buffer, and again when `HEAD` or the
index moves, which a watch of the repository's git directory reports; the
diff of the buffer's text against it is worked off the editor thread, as
hunks (`Diff.hunks`, `Editor/Diff.lean`), each time the buffer has changed.

## Which buffers

A buffer is tracked when it has a file, and its workspace is a local root
that can run commands and is a repository (it has a `Workspace.branch`, a
detached `HEAD` included), with the file under the root; and only where the
host registered the gutter's jobs, the same gate auto-reload uses
(`Gutter.trackedFile?`, `Editor/Gutter/Track.lean`). An excerpt buffer and a buffer with no
file have none. The column appears once `HEAD`'s content has arrived, with
no mark until its diff lands; a file `HEAD` lacks (untracked, new, an
unborn branch) has no gutter and no column, nor does one whose fetch
failed: a gutter failure is not said, since nothing was asked.

## The reconciler

The reconciler that decides which buffers are tracked and starts and
cancels these jobs after each publish is the core's
(`Gutter.reconcile`, `Editor/Gutter/Track.lean`), as are the jobs' names,
keys and orders (`Gutter.headJob`, `HeadOrder`, …); this module defines its
names from those, registers the jobs under them, and works them.

## The jobs

- **`vc-gutter-head`** (`headWork`) asks the version-control interface for
  the file at `HEAD` (`fileAt`), through its git implementation. What it
  comes to (`headFetched`): content is made a text, snapshotted, and the
  text released, the snapshot held in place of the last one; the buffer is
  given a gutter, with no mark, if it had none, so the column appears.
  `none` or a failure takes the gutter away. A reply of an older epoch is
  ignored. The head it replaces is released even while a diff of an older
  epoch reads it: a snapshot id is never used again, so that diff reads
  the text it was given or is refused, and it is ignored either way.
- **`vc-gutter-diff`** (`diffWork`) asks for the hunks of the head snapshot
  against the buffer's (`Diff.hunks`, under `FilesApi.diffLineLimit`). What it
  comes to (`diffed`): for the latest head, the buffer's gutter becomes the
  hunks' marks, and its revision is recorded as diffed (for an older epoch
  neither is) at the revision the buffer's snapshot was taken at
  (`marksOf`); the snapshot is released whatever came of it.
- **`vc-gutter-refs`** (`refsWork`) asks what to watch (`watched`), watches
  that directory and everything under it, coalesced over 100 ms and 256
  paths, and for each delivery with a change that matters
  (`Watched.matters`) posts `vc-gutter-moved <root>` and waits again: it
  never finishes, so a commit made while it posts is seen at its next
  wait. A refusal finishes it with `refsRefused`, which records it.

## The marks (`marksOf`)

Each hunk is a mark over its lines in the buffer's text: lines added are
`+` in `diff.added`, lines changed `~` in `diff.changed`, and lines removed,
which have none in the buffer, an empty mark at the start of the line after
them, `-` in `diff.removed`. The glyphs read on a grid of cells, as the
headless mode draws one.

Pinned by `ModelTest.gutterChecks` on the models and `ConfigTest.gutterChecks`
over real git, the library's watch service and its diff engine; the
reconciler alone by `ModelTest.gutterTrackChecks`.
-/

namespace Editor.VersionControl

/-- The name of the job that fetches a buffer's file at `HEAD`: the core's
(`Gutter.headJob`, `Editor/Gutter/Track.lean`), which the loop's reconciler
starts. -/
def headJob : String :=
  Gutter.headJob

/-- The name of the job that diffs a buffer against its file at `HEAD`: the
core's (`Gutter.diffJob`). -/
def diffJob : String :=
  Gutter.diffJob

/-- The name of the job that watches a repository for `HEAD` or the index
moving: the core's (`Gutter.refsJob`). -/
def refsJob : String :=
  Gutter.refsJob

/-- The name of the command the watch job posts when `HEAD` or the index of
its repository may have moved: the core's (`Gutter.movedName`). -/
def movedName : String :=
  Gutter.movedName

/-- The face of the marks of lines added. -/
def addedFace : FaceName :=
  ⟨"diff.added"⟩

/-- The face of the marks of lines removed. -/
def removedFace : FaceName :=
  ⟨"diff.removed"⟩

/-- The face of the marks of lines changed. -/
def changedFace : FaceName :=
  ⟨"diff.changed"⟩

/-- The marks of `hunks`, ranges of the new text ("The marks", in the module
docs). -/
def marksOf (hunks : Diff.Hunks) : Array GutterMark :=
  hunks.map fun hunk =>
    match hunk.kind with
    | .added => { start := hunk.newStart, stop := hunk.newStop, text := "+", face := addedFace }
    | .changed => { start := hunk.newStart, stop := hunk.newStop, text := "~", face := changedFace }
    | .removed =>
      { start := hunk.newStart, stop := hunk.newStart, text := "-", face := removedFace }

/-! ## The jobs and what they come to -/

/-- The command a head fetch finishes with ("The jobs", in the module docs). -/
def headFetched (order : Gutter.HeadOrder) (reply : Except Error (Option String)) : EditorM Unit :=
  do
  let state ← editorState
  let some entry :=
    state.tracked.find? fun entry =>
      entry.buffer == order.buffer && entry.epoch == order.epoch | return
  let some buffer := state.buffer? order.buffer | return
  match reply with
  | .ok (some content) =>
    let text ← createText content
    let head ← text.snapshot
    text.release
    if let some old := entry.head then
      old.release
    discard <| EditorState.ask (.gutter (.held order.buffer order.epoch (some head)))
    if buffer.gutter.isNone then
      discard <| order.buffer.setGutter (some { revision := ← buffer.text.revision })
  | _ =>
    if let some old := entry.head then
      old.release
    discard <| EditorState.ask (.gutter (.held order.buffer order.epoch none))
    discard <| order.buffer.setGutter none

/-- The head fetch job ("The jobs", in the module docs). It fails only for
arguments that are not an order. -/
def headWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    Gutter.HeadOrder.ofArguments?
      arguments | throw s!"{headJob}: its arguments are not a head order"
  return headFetched order
      (← Program.runM (Git.handler order.git order.root) (fileAt "HEAD" order.path))

/-- The command a diff finishes with ("The jobs", in the module docs). -/
def diffed (order : Gutter.DiffOrder) (reply : Except DiffError Diff.Hunks) : EditorM Unit := do
  order.taken.release
  let state ← editorState
  let latest :=
    state.tracked.any fun entry =>
      entry.buffer == order.buffer && entry.epoch == order.epoch && entry.head == some order.head
  discard <| EditorState.ask (.gutter (.diffed order.buffer order.epoch order.revision))
  if let .ok hunks := reply then
    if latest then
      discard <|
          order.buffer.setGutter (some { revision := order.revision, marks := marksOf hunks })

/-- The diff job ("The jobs", in the module docs). It fails only for
arguments that are not an order. -/
def diffWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    Gutter.DiffOrder.ofArguments?
      arguments | throw s!"{diffJob}: its arguments are not a diff order"
  return diffed order
      (← Diff.hunks (.snapshot order.head) (.snapshot order.taken) FilesApi.diffLineLimit)

/-- The command a watch job finishes with when what to watch, or the watch,
was refused: it is recorded, and not tried again while the repository has a
tracked buffer. -/
def refsRefused (root : System.FilePath) : EditorM Unit := do
  discard <| EditorState.ask (.gutter (.refused root))

/-- How a watch of a repository is coalesced: a window of 100 ms and a bound
of 256 paths, past which a delivery is one missed change. -/
def refsCoalescing : FileWatch.Coalescing :=
  { window := 100, bound := 256 }

/-- The watch job ("The jobs", in the module docs). -/
def refsWork (arguments : List Argument) : Work := fun _ => do
  let [.str root, .str git] := arguments | throw s!"{refsJob}: its arguments are not a root and git"
  let root : System.FilePath := root
  match ← Program.runM (Git.handler git root) watched with
  | .error _ =>
    return refsRefused root
  | .ok what =>
    match ← FileWatch.start (.directory what.directory true) refsCoalescing with
    | .error _ =>
      return refsRefused root
    | .ok watch =>
      let rec go : Nat → JobM (EditorM Unit)
        | 0 => return refsRefused root
        | rounds + 1 => do
          match ← FileWatch.next watch with
          | .error _ =>
            return refsRefused root
          | .ok changes =>
            if changes.any what.matters then
              post { command := movedName, arguments := [.str root.toString] }
            go rounds
      go 1000000

/-- `vc-gutter-moved <root>`, which the watch job posts: every tracked buffer
of the repository is stale, so the next publish fetches its file at `HEAD`
again. -/
def movedCommand (call : Call) : EditorM Unit := do
  if let .str root :: _ := call.arguments then
    discard <| EditorState.ask (.gutter (.moved root))

end Editor.VersionControl
