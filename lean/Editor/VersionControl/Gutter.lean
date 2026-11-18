import Editor.Api
import Editor.Command.Call
import Editor.Files
import Editor.VersionControl.Git
import Editor.VersionControl.Show

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
detached `HEAD` included), with the file under the root; and only where the host registered the gutter's jobs,
the same gate auto-reload uses. An excerpt buffer and a buffer with no
file have none. The column appears once `HEAD`'s content has arrived, with
no mark until its diff lands; a file `HEAD` lacks (untracked, new, an
unborn branch) has no gutter and no column, nor does one whose fetch
failed: a gutter failure is not said, since nothing was asked.

## The reconciler

`reconcile`, after each publish (`Loop.Stepped.published`, after auto-reload's),
keeps `EditorState.tracked` and `EditorState.refWatches` in step with what is
wanted. It is pure but for the text port, where it takes the snapshots the
diffs are asked with:

- **A new tracked buffer** gets a head fetch, the job `vc-gutter-head`, keyed
  by the buffer (`headKey`).
- **A stale one** (its repository moved, `vc-gutter-moved`) gets another
  fetch, under a new epoch, so the reply of an older one is ignored. One
  that moved while a fetch is in flight waits for that fetch's content,
  then fetches again.
- **A diff** (the job `vc-gutter-diff`, keyed by the buffer, `diffKey`) is
  started when `HEAD`'s content is held, no fetch and no diff is in flight,
  and the buffer's text is at a revision not diffed against it. So a diff's
  epoch names the head it reads: none is started against a head a fetch in
  flight will replace. One diff in flight
  a buffer bounds the work with no timer: an edit made while one is in
  flight is diffed when it lands, at the next publish. Between the two the
  marks are carried through the edits.
- **A repository** with a tracked buffer gets one watch job, `vc-gutter-refs`,
  keyed by its root (`refsKey`); its last buffer gone, the job is cancelled.
  A refused watch is not tried again while it has a buffer.
- **A buffer no longer wanted** (closed, its file's path changed, its
  workspace gone) has its jobs cancelled, its snapshots released, and its
  gutter taken away.

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
  against the buffer's (`Diff.hunks`, under `Files.diffLineLimit`). What it
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
over real git, the library's watch service and its diff engine.
-/

namespace Editor.VersionControl

/-- The name of the job that fetches a buffer's file at `HEAD`. -/
def headJob : String :=
  "vc-gutter-head"

/-- The name of the job that diffs a buffer against its file at `HEAD`. -/
def diffJob : String :=
  "vc-gutter-diff"

/-- The name of the job that watches a repository for `HEAD` or the index
moving. -/
def refsJob : String :=
  "vc-gutter-refs"

/-- The name of the command the watch job posts when `HEAD` or the index of
its repository may have moved. -/
def movedName : String :=
  "vc-gutter-moved"

/-- The key of the head fetch of `buffer`. -/
def headKey (buffer : BufferId) : String :=
  s!"{headJob} {buffer.index}"

/-- The key of the diff of `buffer`. -/
def diffKey (buffer : BufferId) : String :=
  s!"{diffJob} {buffer.index}"

/-- The key of the watch of the repository at `root`. -/
def refsKey (root : System.FilePath) : String :=
  s!"{refsJob} {(Location.local root).describe}"

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

/-! ## The orders -/

/-- What a head fetch is started with. -/
structure HeadOrder where
  /-- The buffer. -/
  buffer : BufferId
  /-- The fetch's epoch. -/
  epoch : Nat
  /-- The repository's root. -/
  root : System.FilePath
  /-- The git program. -/
  git : String
  /-- The file's path, relative to the root. -/
  path : String
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with. -/
def HeadOrder.arguments (order : HeadOrder) : List Argument :=
  [.nat order.buffer.index, .nat order.epoch, .str order.root.toString, .str order.git,
    .str order.path]

/-- The order `arguments` are, if they are one. -/
def HeadOrder.ofArguments? : List Argument → Option HeadOrder
  | [.nat buffer, .nat epoch, .str root, .str git, .str path] =>
    some { buffer := ⟨buffer⟩, epoch, root, git, path }
  | _ => none

/-- What a diff is started with. -/
structure DiffOrder where
  /-- The buffer. -/
  buffer : BufferId
  /-- The epoch of the head it diffs against. -/
  epoch : Nat
  /-- The snapshot of the file at `HEAD`. -/
  head : SnapshotId
  /-- The snapshot of the buffer's text. -/
  taken : SnapshotId
  /-- The revision of the buffer's text it was taken at. -/
  revision : Nat
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with. -/
def DiffOrder.arguments (order : DiffOrder) : List Argument :=
  [.nat order.buffer.index, .nat order.epoch, .nat order.head.index, .nat order.taken.index,
    .nat order.revision]

/-- The order `arguments` are, if they are one. -/
def DiffOrder.ofArguments? : List Argument → Option DiffOrder
  | [.nat buffer, .nat epoch, .nat head, .nat taken, .nat revision] =>
    some { buffer := ⟨buffer⟩, epoch, head := ⟨head⟩, taken := ⟨taken⟩, revision }
  | _ => none

/-- What a watch of a repository is started with: its root and the git
program. -/
def refsArguments (root : System.FilePath) (git : String) : List Argument :=
  [.str root.toString, .str git]

/-! ## The jobs and what they come to -/

/-- The command a head fetch finishes with ("The jobs", in the module docs). -/
def headFetched (order : HeadOrder) (reply : Except Error (Option String)) : EditorM Unit := do
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
    HeadOrder.ofArguments? arguments | throw s!"{headJob}: its arguments are not a head order"
  return headFetched order
      (← Program.runM (Git.handler order.git order.root) (fileAt "HEAD" order.path))

/-- The command a diff finishes with ("The jobs", in the module docs). -/
def diffed (order : DiffOrder) (reply : Except DiffError Diff.Hunks) : EditorM Unit := do
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
    DiffOrder.ofArguments? arguments | throw s!"{diffJob}: its arguments are not a diff order"
  return diffed order
      (← Diff.hunks (.snapshot order.head) (.snapshot order.taken) Files.diffLineLimit)

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

/-! ## The reconciler -/

/-- The root and the path relative to it of the file of the buffer `id`, when
it is a tracked file ("Which buffers", in the module docs): it has a file,
and its workspace is a local root that can run commands and is a
repository, with the file under the root. The gutter tracks these
buffers, and a hunk is staged in them (`Editor/VersionControl/Stage.lean`). -/
def trackedFile? (state : EditorState) (id : BufferId) : Option (System.FilePath × String) := do
  let buffer ← state.buffer? id
  let file ← buffer.file
  let (workspace, _) ← state.workspaceOf? id
  let .local root := workspace.location | none
  if !workspace.location.can.runCommands || workspace.branch.isNone then
    none
  let path ← relativeTo root file.path
  return (root, path)

/-- The buffers `state` wants tracked ("Which buffers", in the module docs):
each with its root and its file's path relative to it (`trackedFile?`). -/
def wantedBuffers (state : EditorState) : Array (BufferId × System.FilePath × String) :=
  (List.range state.buffers.size).toArray.filterMap fun index => do
    let id : BufferId := ⟨index⟩
    let (root, path) ← trackedFile? state id
    return (id, root, path)

/-- The version-control gutter's reconciler ("The reconciler", in the module
docs): the state with what it tracks and watches in step with what it
wants, the jobs to start, and the keys of those to cancel. `registered`
says which jobs the host registered, and `git` is the git program. -/
def reconcile (registered : String → Bool) (git : String) (state : EditorState) :
    TextM (EditorState × Array JobStart × Array String) := do
  let on := [headJob, diffJob, refsJob].all registered
  let wanted := if on then wantedBuffers state else #[]
  let wants (entry : Tracked) : Bool :=
    wanted.any fun (id, root, path) =>
      id == entry.buffer && root == entry.root && path == entry.path
  let mut state := state
  let mut starts : Array JobStart := #[]
  let mut cancels : Array String := #[]
  -- What is no longer wanted gives up its jobs, its snapshots and its
  -- gutter.
  for entry in state.tracked.filter (!wants ·) do
    cancels := cancels.push (headKey entry.buffer) |>.push (diffKey entry.buffer)
    if let some head := entry.head then
      head.release
    if let some (_, taken) := entry.diffing then
      taken.release
    state := (state.setGutter entry.buffer none).2
  let kept := state.tracked.filter wants
  let added : Array Tracked :=
    (wanted.filter fun (id, _, _) => !kept.any (·.buffer == id)).map fun (buffer, root, path) =>
      { buffer, root, path, git }
  let mut tracked : Array Tracked := #[]
  for entry in kept ++ added do
    let mut entry := entry
    let mut fetch := added.any (·.buffer == entry.buffer)
    if entry.stale && !entry.fetching then
      entry :=
        { entry with
          stale := false, fetching := true, epoch := entry.epoch + 1 }
      fetch := true
    if fetch then
      starts :=
        starts.push
          { name := headJob, key := some (headKey entry.buffer)
            arguments :=
              HeadOrder.arguments
                { buffer := entry.buffer, epoch := entry.epoch, root := entry.root, git := entry.git
                  path := entry.path } }
    if let some head := entry.head then
      if entry.diffing.isNone && !entry.fetching then
        if let some buffer := state.buffer? entry.buffer then
          let revision ← buffer.text.revision
          if entry.diffed != some revision then
            let taken ← buffer.text.snapshot
            entry := { entry with diffing := some (revision, taken) }
            starts :=
              starts.push
                { name := diffJob, key := some (diffKey entry.buffer)
                  arguments :=
                    DiffOrder.arguments
                      { buffer := entry.buffer, epoch := entry.epoch, head, taken, revision } }
    tracked := tracked.push entry
  -- One watch a repository with a tracked buffer.
  let roots :=
    tracked.foldl
      (fun (roots : Array System.FilePath) entry =>
        if roots.contains entry.root then roots else roots.push entry.root)
      #[]
  let watching := state.refWatches.filter (roots.contains ·.root)
  for watch in state.refWatches.filter (!roots.contains ·.root) do
    cancels := cancels.push (refsKey watch.root)
  let arming := roots.filter fun root => !watching.any (·.root == root)
  for root in arming do
    starts :=
      starts.push
        { name := refsJob, key := some (refsKey root), arguments := refsArguments root git }
  return ({ state with
        tracked, refWatches := watching ++ arming.map fun root => { root } },
      starts, cancels)

end Editor.VersionControl
