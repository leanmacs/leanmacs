import Editor.State
import Editor.State.Outbox
import Editor.Text

/-!
# The version-control gutter's reconciler

What the loop keeps in step after each publish so that a tracked buffer's
gutter is fetched, diffed and watched (`Editor/Loop.lean`,
`Loop.Stepped.published`, after auto-reload's): the core's, as the session
journal's reconciler and its job's name are (`Editor/Restore.lean`). The
state it keeps is the core's (`EditorState.tracked` and
`EditorState.refWatches`, `Editor/State.lean`), and the jobs it starts are
named here; version control registers and works them
(`packages/version-control/VersionControl/Gutter.lean`), and a set that does not register all
three starts none of them.

## Which buffers

A buffer is tracked when it has a file, and its workspace is a local root
that can run commands and is a repository (it has a `Workspace.branch`, a
detached `HEAD` included), with the file under the root (`trackedFile?`,
`relativeTo`); and only where the host registered the gutter's three jobs.
An excerpt buffer and a buffer with no file have none.

## The reconciler

`reconcile` keeps `EditorState.tracked` and `EditorState.refWatches` in
step with what is wanted. It is pure but for the text port, where it takes
the snapshots the diffs are asked with:

- **A new tracked buffer** gets a head fetch, the job `vc-gutter-head`,
  keyed by the buffer (`headKey`), with its order (`HeadOrder`).
- **A stale one** (its repository moved, `vc-gutter-moved`) gets another
  fetch, under a new epoch, so the reply of an older one is ignored. One
  that moved while a fetch is in flight waits for that fetch's content,
  then fetches again.
- **A diff** (the job `vc-gutter-diff`, keyed by the buffer, `diffKey`,
  with its order, `DiffOrder`) is started when `HEAD`'s content is held, no
  fetch and no diff is in flight, and the buffer's text is at a revision not
  diffed against it.
- **A repository** with a tracked buffer gets one watch job,
  `vc-gutter-refs`, keyed by its root (`refsKey`, `refsArguments`); its last
  buffer gone, the job is cancelled.
- **A buffer no longer wanted** (closed, its file's path changed, its
  workspace gone) has its jobs cancelled, its snapshots released, and its
  gutter taken away.

Pinned by `ModelTest.gutterTrackChecks`, on states built in the test; what
the jobs' commands do by version control's `VersionControlTest.gutterChecks`.
-/

namespace Editor.Gutter

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
its repository may have moved, which version control registers. -/
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

/-- `path`, which is absolute, relative to `root`, when it is under it. -/
def relativeTo (root path : System.FilePath) : Option String :=
  let lead := root.toString ++ if root.toString.endsWith "/" then "" else "/"
  if path.toString.startsWith lead then some (path.toString.drop lead.length).toString else none

/-! ## The reconciler -/

/-- The root and the path relative to it of the file of the buffer `id`, when
it is a tracked file ("Which buffers", in the module docs): it has a file,
and its workspace is a local root that can run commands and is a
repository, with the file under the root. The gutter tracks these
buffers, and version control stages a hunk in them
(`packages/version-control/VersionControl/Stage.lean`). -/
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

end Editor.Gutter
