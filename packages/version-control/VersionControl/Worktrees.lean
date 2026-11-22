import Editor.Api
import Editor.Command.Call
import Editor.Mode
import ProjectApi
import VersionControl.Status
import VersionControl.Views

/-!
# The worktree list: `vc-worktrees`

Every worktree of a repository, one per line, each with what is checked
out there, magit's worktree section as a buffer of its own: a read-only
buffer of generated text, one per workspace, whose `activate` opens the
status buffer (`VersionControl/Status.lean`) of the worktree on the
cursor's line. Written over the editor API (`Editor/Api.lean`), the job
port (`Editor/Job.lean`), the workspace finder
(`packages/workspace/Workspace/Finder.lean`) and the version-control interface
(`Editor/VersionControl.lean`), through its git implementation. As the
status buffer's, a read is the command that starts the job
`vc-worktrees-read`, the job, which asks `worktrees`, and the command it
finishes with (`listed`), which writes the buffer. The commands, the jobs
and the mode as compiled code registers them are in
`VersionControl/Compiled.lean`.

## The view

Pure, and tested on values the model gives (`WorktreeView`):

- **Row 0** is `<label>: worktrees`.
- **Each worktree** is a row, in the reply's order, the main one first:
  `<head>: <path>`, the head its branch or `detached` (`main: /r`,
  `feature: /w`, `detached: /d`). The row of the asking workspace's root
  ends ` (this one)`.
- **The worktree on a row** is the reply's before it: row r ≥ 1 is
  worktree r - 1 (`WorktreeView.entryAt`).

## The record

Each workspace keeps a `WorktreesRecord` in its store (`worktreesStore`):
the number of its worktree list, found by it and never by its name, and the
worktrees last shown, which `vc-worktrees-visit` reads the cursor's
worktree from.

## The commands

- **`vc-worktrees`** (`worktreesName`, the status buffer's leader suffix
  `w`, and the ex name `vc-worktrees`), in the focused buffer: under
  `vc-status`'s gate (`readOrder`), a buffer with no workspace, or one whose
  location cannot run commands, is said, and nothing starts. Otherwise it
  starts the job `vc-worktrees-read`, keyed `vc-worktrees <location>`
  (`listKeyOf`), so a second read replaces the first.
- **What the read comes to** (`listed`): a failure says `vc-worktrees:
  <Error.describe>` and opens nothing. A list replaces the kept buffer's
  text, each view keeping its cursor's row, or makes the buffer:
  read-only, named `*vc-worktrees: <label>*` or the first free name of
  that, given the workspace, in the mode `vc-worktrees`, shown where the
  display rules say for the opener `vc-worktrees`, and focused. The record
  is written.
- **`vc-worktrees-refresh`** (`worktreesRefreshName`, the mode's `refresh`):
  in its workspace's kept worktree list, starts the read without showing
  it; in any other buffer it says `vc-worktrees-refresh: <buffer> is not a
  worktree list`, as `vc-worktrees-visit` does.
- **`vc-worktrees-visit`** (`worktreesVisitName`, the mode's `activate`),
  on the cursor's row:
  - a row with no worktree says `vc-worktrees: no worktree on this line`;
  - the asking workspace's own root starts the status read for it, shown
    (`startRead`);
  - any other path is reached through the interface library
    `project-api` (`ProjectApi.workspaces?`'s `reach`; with none it says
    `vc-worktrees-visit: no workspace implementation`) with
    `visitContinuation`, which version control builds from the interface's
    types: the workspace's reach answers from the table's cache under the
    current generation at once, otherwise through the unkeyed job
    `vc-worktree-find` (`visitFindWork`, registered over the point), which
    runs the finder with the workspace settings on that path and records the
    answer, as a file's open would. Then the status
    read of the workspace reached starts, with its label, shown from the
    asking view. Local workspaces are found,
    never registered, so the status buffer opened is the one opening a file
    in that worktree would give.
  - A path with no answer, a worktree whose directory is gone, says
    `vc-worktrees-visit: <path> is not a repository any more` and opens
    nothing.

## The mode

`vc-worktrees` (`worktreesMode`), read-only to editing commands: `refresh`
is `vc-worktrees-refresh` and `activate` is `vc-worktrees-visit`, on each
scheme's keys for those roles. No new role.

Pinned by `VersionControlTest.worktreeViewChecks` on the model's values,
`VersionControlTest.worktreeBufferChecks` on the loop's driver over the editor's
models, the job model and the model of a repository, and
`VersionControlTest.Linked.statusBufferChecks` over real git.
-/

namespace Editor.VersionControl

/-- The name the command that reads the worktree list again is registered
under. -/
def worktreesRefreshName : String :=
  "vc-worktrees-refresh"

/-- The name the command that opens the cursor's worktree's status is
registered under. -/
def worktreesVisitName : String :=
  "vc-worktrees-visit"

/-- The name the job that reads the worktree list is registered under. -/
def worktreesReadJob : String :=
  "vc-worktrees-read"

/-- The name the job that finds a worktree's workspace is registered
under. -/
def worktreeFindJob : String :=
  "vc-worktree-find"

/-- The name of the worktree list's major mode. -/
def worktreesModeName : String :=
  "vc-worktrees"

/-! ## The view -/

namespace WorktreeView

/-- What a row says is checked out: the branch, or `detached`. -/
def headText : Head → String
  | .branch name => name
  | .detached => "detached"

/-- The row of `worktree`, marked when it is at `here`. -/
def line (here : System.FilePath) (worktree : Worktree) : String :=
  let base := s!"{headText worktree.head}: {worktree.path}"
  if worktree.path == here then s!"{base} (this one)" else base

/-- The text of the worktree list of the workspace labelled `label`, whose
root is `here`: the head line, then one row per worktree, each ended by a
line feed ("The view", in the module docs). -/
def render (label : String) (here : System.FilePath) (worktrees : Array Worktree) : String :=
  String.join ((#[s!"{label}: worktrees"] ++ worktrees.map (line here)).toList.map (· ++ "\n"))

/-- The worktree on row `row` of a list showing `worktrees`: none on the head
line, or past the last. -/
def entryAt (worktrees : Array Worktree) (row : Nat) : Option Worktree :=
  match row with
  | 0 => none
  | row + 1 => worktrees[row]?

end WorktreeView

/-! ## The record -/

/-- What is checked out as a tree. -/
def Head.encode : Head → Value
  | .branch name => .record [("branch", .str name)]
  | .detached => .str "detached"

/-- What is checked out a tree is (`Head.encode`), if it is. -/
def Head.decode? : Value → Option Head
  | .record [("branch", .str name)] => some (.branch name)
  | .str "detached" => some .detached
  | _ => none

/-- A worktree as a tree. -/
def Worktree.encode (worktree : Worktree) : Value :=
  .list [.str worktree.path.toString, worktree.head.encode]

/-- The worktree a tree is (`Worktree.encode`), if it is one. -/
def Worktree.decode? : Value → Option Worktree
  | .list [.str path, head] => (fun head => ({ path, head } : Worktree)) <$> Head.decode? head
  | _ => none

/-- What a workspace keeps of its worktree list ("The record", in the module
docs). -/
structure WorktreesRecord where
  /-- The number of its worktree list. -/
  buffer : Option Nat := none
  /-- The worktrees last shown, in row order from row 1. -/
  worktrees : Array Worktree := #[]
  deriving DecidableEq, Repr

/-- A record as a tree. -/
def WorktreesRecord.encode (record : WorktreesRecord) : Value :=
  .record
    [("buffer",
        match record.buffer with
        | some index => .nat index
        | none => .null),
      ("worktrees", .list (record.worktrees.toList.map Worktree.encode))]

/-- The record a tree is (`WorktreesRecord.encode`), if it is one. -/
def WorktreesRecord.decode? : Value → Option WorktreesRecord
  | .record [("buffer", buffer), ("worktrees", .list worktrees)] => do
    let buffer ←
      match buffer with
      | .nat index =>
        some (some index)
      | .null =>
        some none
      | _ =>
        none
    return { buffer, worktrees := ← worktrees.toArray.mapM Worktree.decode? }
  | _ => none

/-- A workspace's record of its worktree list. -/
def worktreesStore : Store WorktreesRecord :=
  { name := "vc-worktrees", version := 1, initial := {}, encode := WorktreesRecord.encode
    decode := WorktreesRecord.decode? }

/-! ## The commands -/

/-- The job key of the worktree list reads of the repository at `root`. -/
def listKeyOf (root : System.FilePath) : String :=
  s!"{worktreesName} {(Location.local root).describe}"

/-- The name of the worktree list of the workspace labelled `label`. -/
def worktreesBufferName (label : String) : String :=
  s!"*{worktreesName}: {label}*"

/-- Starts the worktree list read of `order`, keyed by its root; a start that
is refused is said. -/
def startList (order : ReadOrder) : EditorM Unit := do
  if let .error refusal←
      startJob worktreesReadJob order.arguments (key := some (listKeyOf order.root)) then
    message s!"{worktreesName}: {refusal.describe}"

/-- The command a finished worktree list read hands the loop ("What the read
comes to", in the module docs). -/
def listed (order : ReadOrder) (reply : Except Error (Array Worktree)) : EditorM Unit := do
  match reply with
  | .error error =>
    message s!"{worktreesName}: {error.describe}"
  | .ok worktrees =>
    let location := Location.local order.root
    let state ← editorState
    let record := state.workspaces.get worktreesStore location
    let content := WorktreeView.render order.label order.root worktrees
    let kept := (record.buffer.filter fun index => (state.buffer? ⟨index⟩).isSome).map (⟨·⟩)
    let id ←
      match kept with
      | some id =>
        replace id content
        pure id
      | none =>
        let some id ← readOnlyBufferOf (worktreesBufferName order.label) content location | return
        discard <| id.setMajorMode worktreesModeName
        pure id
    discard <| Workspace.set worktreesStore location { buffer := some id.index, worktrees }
    if order.shows then
      displayFor id order.view worktreesName

/-- The worktree list read job: asks its order's repository for its
worktrees through git, and finishes with what it comes to (`listed`). It
fails only for arguments that are not a read order. -/
def listWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    ReadOrder.ofArguments?
      arguments | throw s!"{worktreesReadJob}: its arguments are not a read order"
  return listed order (← Program.runM (Git.handler order.git order.root) worktrees)

/-- `vc-worktrees` ("The commands", in the module docs). Its arguments are
ignored. -/
def worktreesCommand (call : Call) : EditorM Unit := do
  if let some order← readOrder worktreesName call then
    startList order

/-- The read of the worktree list `call` was made in, as the command `name`
asks it, with the worktrees it shows; said and `none` when the buffer is not
its workspace's kept worktree list. -/
def worktreesOf (call : Call) (name : String) : EditorM (Option (ReadOrder × WorktreesRecord)) := do
  let state ← editorState
  let buffer := call.target.window.buffer
  let notList := s!"{name}: {call.target.buffer.name} is not a worktree list"
  let some (workspace, _) := state.workspaceOf? buffer |
    message notList;
    return none
  let .local root := workspace.location |
    message notList;
    return none
  let record := state.workspaces.get worktreesStore workspace.location
  if record.buffer != some buffer.index then
    message notList
    return none
  let order : ReadOrder :=
    { root, git := ← gitProgram, label := workspace.label, view := call.target.window.id
      shows := false }
  return some (order, record)

/-- `vc-worktrees-refresh` ("The commands", in the module docs). -/
def worktreesRefreshCommand (call : Call) : EditorM Unit := do
  let some (order, _) ← worktreesOf call worktreesRefreshName | return
  startList order

/-- What a visit says of a worktree whose directory is in no repository any
more. -/
def goneSentence (path : System.FilePath) : String :=
  s!"{worktreesVisitName}: {path} is not a repository any more"

/-- Starts the status read, shown from `view`, of the workspace at
`location` the table holds; said when it holds none, which is a worktree
whose directory is gone. -/
def readWorkspace (location : Location) (path : System.FilePath) (git : String) (view : ViewId) :
    EditorM Unit := do
  match location, (← editorState).workspaces.workspace? location with
  | .local root, some workspace =>
    startRead { root, git, label := workspace.label, view, shows := true }
  | _, _ =>
    message (goneSentence path)

/-- What reaching a worktree a visit names comes to ("The commands", in the
module docs): the status read of its workspace started, or the worktree said
to be gone; its find runs under `vc-worktree-find`. -/
def visitContinuation : Workspace.Reach.Continuation :=
  { job := worktreeFindJob, name := worktreesName, gone := goneSentence
    reached := fun order location => readWorkspace location order.path order.git order.view }

/-- The visit's find job over `values`, the `project-api` values registered
when it starts: their `work` handing on to `visitContinuation`
(`ProjectApi.workOver`); with none it fails, saying so. -/
def visitFindWork (values : Array ProjectApi.Workspaces) : List Argument → Work :=
  ProjectApi.workOver values visitContinuation

/-- `vc-worktrees-visit` ("The commands", in the module docs). -/
def worktreesVisitCommand (call : Call) : EditorM Unit := do
  let some (order, record) ← worktreesOf call worktreesVisitName | return
  let some worktree :=
    WorktreeView.entryAt record.worktrees
      (← cursorRowOf call) | message s!"{worktreesName}: no worktree on this line"
  if worktree.path == order.root then
    startRead { order with shows := true }
    return
  let some workspaces ←
    ProjectApi.workspaces? | message (ProjectApi.noImplementation worktreesVisitName)
  workspaces.reach visitContinuation worktree.path order.git order.view []

/-- The `vc-worktrees` mode ("The mode", in the module docs). -/
def worktreesMode : Mode :=
  { name := worktreesModeName
    roles := [(Role.refresh, worktreesRefreshName), (Role.activate, worktreesVisitName)] }

end Editor.VersionControl
