import Editor.Api
import Editor.Command.Call
import FilesApi
import VersionControl.Git
import VersionControl.Gutter
import VersionControl.Hunk
import VersionControl.Status

/-!
# Staging a hunk: `vc-stage-hunk` and `vc-unstage-hunk`

Stages, or unstages, the hunk on the cursor's line of a file buffer, magit's
`magit-stage` on a hunk. Written over the editor API (`Editor/Api.lean`),
the job port, the diff service (`Diff.hunks`, `Editor/Diff.lean`), the
pure core of hunks (`VersionControl/Hunk.lean`) and the
version-control interface (`Editor/VersionControl.lean`), through its git
implementation.

## Which hunk

- **A stageable hunk** is a hunk of the saved file against the index, not
  one of the gutter's, which are of the buffer against `HEAD`: so staging
  one hunk is right when other hunks of the file are staged already.
- **An unstageable hunk** is a hunk of the index against `HEAD`. The
  cursor's line of the buffer is carried to a line of the index across the
  hunks of the index against the buffer (`Hunks.toOld`), and the hunk is
  picked there.
- **The hunk on the cursor's line** is picked as `Hunks.pick` says: one
  whose lines overlap it, or a removal just before it, where the gutter
  draws its `-`. Over the diff line limit (`FilesApi.diffLineLimit`) the
  middle of a file is one hunk, so the hunk on a line may be all of it.

## The gate

A file buffer whose workspace is a local root that can run commands and is
a repository, with the file under the root: the gutter's gate
(`Gutter.trackedFile?`, `Editor/Gutter/Track.lean`). Each refusal is
said as `vc-stage-hunk: <why>` (`vc-unstage-hunk: ` for the other): a buffer
with no file, a buffer that is not in a repository, a save in flight (`is
being saved; try again`).

To stage, a buffer with no unsaved changes whose file a check found changed
on disk, or gone (`Buffer.File.changed`), is refused too (`staleOnDisk?`):
its text is not the saved file, so a hunk of it would put into the index
lines the working tree does not hold. It says `<path> changed on disk;
reload it (:e) and try again`, or `<path> is gone from disk; nothing
staged`. A buffer with unsaved changes is saved first, and its save is
refused over a changed file. Unstaging takes nothing from the buffer's
text, so it is not refused.

## The pipeline

A command may not wait and a job may, so each step that asks git or the
diff service is a job, and each job's command does the next step:

1. **The command** reads the root, the git program config's workspace
   settings name, the label, the buffer, the path and the cursor's row. To
   stage, a buffer with unsaved changes is saved first, and the fetch
   follows the save once the file is written (the files implementation's `save`, `FilesApi.files?`, with its
   follow-up; with none it says `<name>: no files implementation`); a
   refused save starts nothing. Otherwise the fetch starts now. Unstaging
   saves nothing: the file's content plays no part in what is unstaged,
   and the buffer only places the cursor.
2. **`vc-hunk-fetch`** reads the index's content of the path (`fileAt ""`),
   and, to unstage, `HEAD`'s too. A path the index holds no merged file of
   (untracked, in conflict) says `<path> has no version in the index`, and
   to stage the whole file; a path `HEAD` lacks, to unstage the whole file.
3. **`hunksFetched`**: to stage, a buffer edited since its save says
   `<path> changed while staging; nothing staged`, and a file found changed
   on disk since the command ran is refused as the gate refuses it.
   Otherwise each content
   fetched is made a text, snapshotted, and the text released, as the
   gutter's head fetch does; the buffer is snapshotted, and `vc-hunk-diff`
   started with the snapshots. A refused start releases every one.
4. **`vc-hunk-diff`** asks for the hunks of the index against the buffer,
   and, to unstage, of `HEAD` against the index (`Diff.hunks`, under
   `FilesApi.diffLineLimit`).
5. **`hunksDiffed`** picks the hunk ("Which hunk"), and reads only its lines
   and their context from the snapshots (`LineHunk.locate`, over
   `snapshotLines`), releasing every snapshot on every path, a refusal of
   the text port's included. No hunk on the line says `no change on this
   line` (`nothing staged on this line` to unstage). Otherwise it starts
   `vc-hunk-apply` with the hunk.
6. **`vc-hunk-apply`** runs `stageHunk` or `unstageHunk`.
7. **`hunkApplied`**: a failure says `vc-stage-hunk: <Error.describe>`. A
   success says `staged a hunk of <path>` (`unstaged a hunk of <path>`)
   and starts the read of the workspace's kept status buffer, if it has
   one, without showing it. The gutter is against `HEAD`, and staging does
   not move `HEAD`, so it is unchanged.

None of these jobs is keyed: a keyed restart would cancel a job whose
command releases snapshots, and cancelling an apply could kill git while
it holds the index's lock. A second press while the first runs is safe:
the second patch's context no longer matches the index, git refuses it,
and that is said.

Pinned by `VersionControlTest.stageHunkChecks` on the loop's driver over the
editor's models, the job model and the model of a repository, and
`VersionControlTest.Linked.statusBufferChecks` over real git and the library's diff
engine.
-/

namespace Editor.VersionControl

/-- The name the command that stages the cursor's hunk is registered
under. -/
def stageHunkName : String :=
  "vc-stage-hunk"

/-- The name the command that unstages the cursor's hunk is registered
under. -/
def unstageHunkName : String :=
  "vc-unstage-hunk"

/-- The name of the job that reads the index's content of a file, and
`HEAD`'s to unstage. -/
def hunkFetchJob : String :=
  "vc-hunk-fetch"

/-- The name of the job that diffs a file's buffer against the index, and the
index against `HEAD` to unstage. -/
def hunkDiffJob : String :=
  "vc-hunk-diff"

/-- The name of the job that stages or unstages a hunk. -/
def hunkApplyJob : String :=
  "vc-hunk-apply"

/-! ## The orders -/

/-- What staging or unstaging a hunk is started with. -/
structure HunkOrder where
  /-- Whether the hunk is unstaged. -/
  unstage : Bool
  /-- The repository's root, the workspace's. -/
  root : System.FilePath
  /-- The git program. -/
  git : String
  /-- The workspace's label. -/
  label : String
  /-- The view that asked. -/
  view : ViewId
  /-- The file's buffer. -/
  buffer : BufferId
  /-- The file's path, relative to the root. -/
  path : String
  /-- The row of the cursor. -/
  row : Nat
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with. -/
def HunkOrder.arguments (order : HunkOrder) : List Argument :=
  [.bool order.unstage, .str order.root.toString, .str order.git, .str order.label,
    .nat order.view.index, .nat order.buffer.index, .str order.path, .nat order.row]

/-- The order at the start of `arguments`, if they start with one, and the
arguments after it. -/
def HunkOrder.split? : List Argument → Option (HunkOrder × List Argument)
  |
  .bool unstage ::
      .str root ::
      .str git :: .str label :: .nat view :: .nat buffer :: .str path :: .nat row :: rest =>
    some ({ unstage, root, git, label, view := ⟨view⟩, buffer := ⟨buffer⟩, path, row }, rest)
  | _ => none

/-- The order `arguments` are, if they are one (`HunkOrder.arguments`). -/
def HunkOrder.ofArguments? (arguments : List Argument) : Option HunkOrder :=
  match HunkOrder.split? arguments with
  | some (order, []) => some order
  | _ => none

/-- The name of the command `order` is of, which its sentences start with. -/
def HunkOrder.name (order : HunkOrder) : String :=
  if order.unstage then unstageHunkName else stageHunkName

/-- What a hunk's diff is started with: its order, and the snapshots of the
index's content, the buffer's text and, to unstage, `HEAD`'s content. -/
structure HunkDiffOrder where
  /-- What staging or unstaging was started with. -/
  order : HunkOrder
  /-- The snapshot of the index's content of the file. -/
  index : SnapshotId
  /-- The snapshot of the buffer's text. -/
  taken : SnapshotId
  /-- The snapshot of `HEAD`'s content of the file, to unstage. -/
  head : Option SnapshotId
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with: the hunk order's, then
the snapshots, `HEAD`'s last when there is one. -/
def HunkDiffOrder.arguments (order : HunkDiffOrder) : List Argument :=
  order.order.arguments ++ [.nat order.index.index, .nat order.taken.index] ++
    (order.head.map fun head => [Argument.nat head.index]).getD []

/-- The order `arguments` are, if they are one (`HunkDiffOrder.arguments`). -/
def HunkDiffOrder.ofArguments? (arguments : List Argument) : Option HunkDiffOrder := do
  let (order, rest) ← HunkOrder.split? arguments
  match rest with
  | [.nat index, .nat taken] =>
    some { order, index := ⟨index⟩, taken := ⟨taken⟩, head := none }
  | [.nat index, .nat taken, .nat head] =>
    some { order, index := ⟨index⟩, taken := ⟨taken⟩, head := some ⟨head⟩ }
  | _ =>
    none

/-- The snapshots `order` names, each released once. -/
def HunkDiffOrder.release (order : HunkDiffOrder) : EditorM Unit := do
  order.index.release
  order.taken.release
  if let some head := order.head then
    head.release

/-- The arguments of an apply: the hunk order's, then the hunk's rows and its
four runs of lines, each joined. -/
def applyArguments (order : HunkOrder) (hunk : LineHunk) : List Argument :=
  order.arguments ++
    [.nat hunk.oldLine, .nat hunk.newLine, .str (String.join hunk.before.toList),
      .str (String.join hunk.removed.toList), .str (String.join hunk.added.toList),
      .str (String.join hunk.after.toList)]

/-- The hunk order and the hunk `arguments` are, if they are an apply's
(`applyArguments`). -/
def applyOfArguments? (arguments : List Argument) : Option (HunkOrder × LineHunk) := do
  let (order, rest) ← HunkOrder.split? arguments
  match rest with
  | [.nat oldLine, .nat newLine, .str before, .str removed, .str added, .str after] =>
    some (order, LineHunk.make oldLine newLine before removed added after)
  | _ =>
    none

/-! ## The steps -/

/-- The text of `snapshot` as `LineHunk.locate` reads it. -/
def snapshotLines (snapshot : SnapshotId) : TextM (Lines TextM) := do
  return {
      size := ← snapshot.byteLength, rows := ← snapshot.rowCount
      rowOf := fun offset => do
        return (← snapshot.pointOf offset).row
      rowStart := fun row => snapshot.offsetOf ⟨row, 0⟩, slice := snapshot.slice }

/-- The hunk on the order's row ("Which hunk", in the module docs), read from
the snapshots, or the sentence that says why there is none. -/
def pickHunk (order : HunkDiffOrder) (buffer : Except DiffError Diff.Hunks)
    (head : Option (Except DiffError Diff.Hunks)) : TextM (Except String LineHunk) := do
  let name := order.order.name
  let buffer ←
    match buffer with
    | .ok hunks =>
      pure hunks
    | .error error =>
      return .error s!"{name}: {error.describe}"
  let taken ← snapshotLines order.taken
  let index ← snapshotLines order.index
  let start ← taken.startOf order.order.row
  let stop ← taken.startOf (order.order.row + 1)
  match head, order.head with
  | none, _ =>
    match Hunks.pick buffer start stop taken.size with
    | none =>
      return .error s!"{name}: no change on this line"
    | some hunk =>
      return .ok (← LineHunk.locate .stage index taken hunk)
  | some (.error error), _ =>
    return .error s!"{name}: {error.describe}"
  | some (.ok staged), some head =>
    let (start, stop) := Hunks.toOld buffer start stop
    match Hunks.pick staged start stop index.size with
    | none =>
      return .error s!"{name}: nothing staged on this line"
    | some hunk =>
      return .ok (← LineHunk.locate .unstage (← snapshotLines head) index hunk)
  | some (.ok _), none =>
    return .error s!"{name}: HEAD was not read"

/-- The command a finished apply hands the loop ("The pipeline", in the
module docs). -/
def hunkApplied (order : HunkOrder) (reply : Except Error Unit) : EditorM Unit := do
  match reply with
  | .error error =>
    message s!"{order.name}: {error.describe}"
  | .ok () =>
    message s!"{if order.unstage then "unstaged" else "staged"} a hunk of {order.path}"
    let state ← editorState
    if (kept state (state.workspaces.get statusStore (.local order.root))).isSome then
      startRead
          { root := order.root, git := order.git, label := order.label, view := order.view
            shows := false }

/-- The apply job: stages or unstages its hunk through git, and finishes with
what it comes to (`hunkApplied`). It fails only for arguments that are not
an apply's. -/
def hunkApplyWork (arguments : List Argument) : Work := fun _ => do
  let some (order, hunk) :=
    applyOfArguments? arguments | throw s!"{hunkApplyJob}: its arguments are not an apply order"
  let handler := Git.handler order.git order.root
  let reply ←
    if order.unstage then
      Program.runM handler (unstageHunk order.path hunk)
    else
      Program.runM handler (stageHunk order.path hunk)
  return hunkApplied order reply

/-- The command a finished diff hands the loop ("The pipeline", in the module
docs): the hunk on the row is picked and read, every snapshot is released,
whatever came of it, and the apply is started. -/
def hunksDiffed (order : HunkDiffOrder) (buffer : Except DiffError Diff.Hunks)
    (head : Option (Except DiffError Diff.Hunks)) : EditorM Unit := do
  let picked ←
    tryCatch (pickHunk order buffer head) fun error => do
        order.release
        throw error
  order.release
  match picked with
  | .error sentence =>
    message sentence
  | .ok hunk =>
    if let .error refusal← startJob hunkApplyJob (applyArguments order.order hunk) then
      message s!"{order.order.name}: {refusal.describe}"

/-- The diff job: the hunks of the index against the buffer, and of `HEAD`
against the index to unstage, and finishes with what they come to
(`hunksDiffed`). It fails only for arguments that are not a diff order. -/
def hunkDiffWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    HunkDiffOrder.ofArguments?
      arguments | throw s!"{hunkDiffJob}: its arguments are not a diff order"
  let buffer ← Diff.hunks (.snapshot order.index) (.snapshot order.taken) FilesApi.diffLineLimit
  let head ←
    match order.head with
    | some head =>
      some <$> Diff.hunks (.snapshot head) (.snapshot order.index) FilesApi.diffLineLimit
    | none =>
      pure none
  return hunksDiffed order buffer head

/-- Why the hunks of `buffer` cannot be staged from its text, if they cannot:
its file changed on disk, or is gone, since it was last loaded or saved, so
its text is not the saved file a stageable hunk is of ("The gate", in the
module docs). The command `name` says it, about `path`. -/
def staleOnDisk? (name path : String) (buffer : Buffer) : Option String :=
  match buffer.file.bind (·.changed) with
  | some { found := some _, .. } =>
    some s!"{name}: {path} changed on disk; reload it (:e) and try again"
  | some { found := none, .. } => some s!"{name}: {path} is gone from disk; nothing staged"
  | none => none

/-- A snapshot of a new text holding `content`, the text released. -/
def snapshotOf (content : String) : EditorM SnapshotId := do
  let text ← createText content
  let snapshot ← text.snapshot
  text.release
  return snapshot

/-- The command a finished fetch hands the loop ("The pipeline", in the module
docs). -/
def hunksFetched (order : HunkOrder) (index : Except Error (Option String))
    (head : Option (Except Error (Option String))) : EditorM Unit := do
  let name := order.name
  let verb := if order.unstage then "unstage" else "stage"
  let some buffer := (← editorState).buffer? order.buffer | message s!"{name}: its buffer is gone"
  let index ←
    match index with
    | .error error =>
      message s!"{name}: {error.describe}"
      return
    | .ok none =>
      message
          s!"{name}: {order.path} has no version in the index to {verb} (untracked or in conflict); {verb} the whole file"
      return
    | .ok (some content) =>
      pure content
  let head ←
    match head with
    | none =>
      pure none
    | some (.error error) =>
      message s!"{name}: {error.describe}"
      return
    | some (.ok none) =>
      message s!"{name}: {order.path} is not in HEAD; unstage the whole file"
      return
    | some (.ok (some content)) =>
      pure (some content)
  if !order.unstage && (← order.buffer.hasUnsavedChanges) matches .ok true then
    message s!"{name}: {order.path} changed while staging; nothing staged"
    return
  if !order.unstage then
    if let some sentence := staleOnDisk? name order.path buffer then
      message sentence
      return
  let diff : HunkDiffOrder :=
    { order, index := ← snapshotOf index, taken := ← buffer.text.snapshot
      head := ← head.mapM snapshotOf }
  if let .error refusal← startJob hunkDiffJob diff.arguments then
    diff.release
    message s!"{name}: {refusal.describe}"

/-- The fetch job: the index's content of the file, and `HEAD`'s to unstage,
and finishes with what they come to (`hunksFetched`). It fails only for
arguments that are not a hunk order. -/
def hunkFetchWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    HunkOrder.ofArguments? arguments | throw s!"{hunkFetchJob}: its arguments are not a hunk order"
  let handler := Git.handler order.git order.root
  let index ← Program.runM handler (fileAt "" order.path)
  let head ←
    if order.unstage then
      some <$> Program.runM handler (fileAt "HEAD" order.path)
    else
      pure none
  return hunksFetched order index head

/-- `vc-stage-hunk`, or `vc-unstage-hunk` when `unstage` ("The gate", "The
pipeline", in the module docs). Its arguments are ignored. -/
def hunkCommand (unstage : Bool) (call : Call) : EditorM Unit := do
  let name := if unstage then unstageHunkName else stageHunkName
  let state ← editorState
  let id := call.target.window.buffer
  let some buffer := state.buffer? id | return
  let some file := buffer.file | message s!"{name}: {buffer.name} has no file"
  let some (root, path) :=
    Gutter.trackedFile? state id | message s!"{name}: {buffer.name} is not in a repository"
  if file.saving.isSome then
    message s!"{name}: {path} is being saved; try again"
    return
  let label := ((state.workspaceOf? id).map (·.1.label)).getD ""
  let selection ← call.target.selection
  let cursor := (selection.ranges[selection.primary]?.map (·.head)).getD 0
  let order : HunkOrder :=
    { unstage, root, git := ← gitProgram, label, view := call.target.window.id, buffer := id, path
      row := (← call.target.buffer.text.pointOf cursor).row }
  let fetch : JobStart := { name := hunkFetchJob, arguments := order.arguments }
  if !unstage && (← id.hasUnsavedChanges) matches .ok true then
    match ← FilesApi.files? with
    | some files =>
      files.save id false (some fetch)
    | none =>
      message (FilesApi.noImplementation name)
  else if let some sentence := if unstage then none else staleOnDisk? name path buffer then
    message sentence
  else if let .error refusal← startJob fetch.name fetch.arguments then
    message s!"{name}: {refusal.describe}"

/-- `vc-stage-hunk` ("The pipeline", in the module docs). -/
def stageHunkCommand (call : Call) : EditorM Unit :=
  hunkCommand false call

/-- `vc-unstage-hunk` ("The pipeline", in the module docs). -/
def unstageHunkCommand (call : Call) : EditorM Unit :=
  hunkCommand true call

end Editor.VersionControl
