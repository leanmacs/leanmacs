import Editor.Api
import Editor.Command.Call
import Editor.Files
import Editor.Mode
import Editor.VersionControl.Git

/-!
# The status buffer: `vc-status`

magit's status buffer, one per workspace: a read-only buffer of generated
text, a head line and then one line per changed file naming its state,
with commands to visit, stage and unstage the file on the cursor's line.
Written over the editor API (`Editor/Api.lean`), the job port
(`Editor/Job.lean`) and the version-control interface
(`Editor/VersionControl.lean`), through its git implementation
(`Editor/VersionControl/Git.lean`). A command may not wait and a job may,
so a read is the command that starts the job `vc-status-read`, the job,
which asks git, and the command it finishes with (`shown`), which writes
the buffer. The commands, the jobs and the mode as compiled code registers
them are in `Editor/VersionControl/Compiled.lean`.

## The repository

The status buffer's repository is the root of the workspace of the buffer
it is opened from: the stored location a file's open found and recorded
once (`docs/design/projects.md`), read from the table and never derived
again. This module defines no finder. A buffer with no workspace opens no
status buffer, and says so; a workspace whose location cannot run commands
(`Location.can`) is refused, since git cannot run there. The root is taken
to be the repository's top level, which it is for every workspace git or a
`.git` marker finds (`docs/design/version-control.md`, "Open questions").

## The view

Pure, and tested on values the model gives (`StatusView`):

- **Row 0** is `<label>: <head>`, the workspace's label and `on <branch>`
  or `detached`.
- **Each file** is a row, in the status's order: `<state>: <path>`, with
  ` (<detail>)` when there is a detail (`StatusView.line`). The state is
  `staged`, `unstaged`, `staged, unstaged`, `untracked`, `renamed`,
  `renamed, unstaged` or `conflicted`; the detail says how: `modified`,
  `added, modified`, `from old.rs`, `both modified`.
- **No files** is one row, `no changes`.
- **The file on a row** is the status's file before it: row r ≥ 1 is file
  r - 1 (`StatusView.fileAt`).
- **Toggling** a file stages it when it is untracked, conflicted or has an
  unstaged change, and else unstages it: a staged rename by both its
  paths, so it goes back to an unstaged deletion and an untracked file
  (`StatusView.toggleRequest`). The explicit forms
  (`StatusView.stageRequest`, `StatusView.unstageRequest`) refuse, with a
  sentence, a file with nothing to stage or nothing staged.
- **A file is deleted** (`StatusView.deleted`) when it is gone from the
  working tree: its unstaged change is a deletion, a rename's included, or
  it is a staged deletion the status does not also list as untracked,
  which it does while the file is still on disk. A conflict is never
  deleted: the status cannot say whether its file is on disk, and the
  file is where its resolution is written.

## The record

Each workspace keeps a `StatusRecord` in its store (`statusStore`): the
number of its status buffer, found by it and never by its name, and the
files last shown, which the commands read the cursor's file from.

## The commands

- **`vc-status`** (`statusName`), in the focused buffer: with no workspace
  it says `vc-status: <buffer> has no workspace`, and a location that
  cannot run commands `vc-status: <label> cannot run commands`; each makes
  no buffer and starts no job. Otherwise it starts the job
  `vc-status-read`, keyed by the workspace (`keyOf`), so a second read
  replaces the first, with the root, the git program config's workspace
  settings name, the label, the asking view, and whether to show it.
- **What the read comes to** (`shown`): a failure says `vc-status:
  <Error.describe>`, opens nothing, and leaves a shown buffer's text as it
  was. A status replaces the kept buffer's text inside `BufferId.writing`,
  each view of it keeping its cursor's row, clamped to the text; or makes
  the buffer: read-only, named `*vc-status: <label>*` or the first free
  name of that (`EditorState.freeName`), given the workspace, in the mode
  `vc-status`. The record is written. When the read shows it, the buffer is shown
  where the display rules say for the opener `vc-status`, from the asking
  view, or the focused view when that is gone, and focused when no rule
  says otherwise.
- **`vc-status-refresh`** (`refreshName`, the mode's `refresh`): in its
  workspace's kept status buffer, it starts the read without showing it; in
  any other buffer it says `vc-status-refresh: <buffer> is not a status
  buffer`, as each command below does.
- **`vc-status-visit`** (`visitName`, the mode's `activate`): opens the
  cursor's file at `<root>/<path>` in the window (`Files.visit`). A
  deleted file (`StatusView.deleted`) says `vc-status-visit: <path> is
  deleted` and opens nothing, and a row with no file `vc-status: no file
  on this line`.
- **`vc-status-toggle`** (`toggleName`, the mode's `toggle`): starts the
  unkeyed job `vc-status-apply` with the root, the git program, the label,
  the view and the cursor's file's toggle request. The job runs it; what
  it comes to (`applied`) says `vc-status: <Error.describe>` of a failure,
  and otherwise starts the keyed read without showing it, so the buffer shows
  the new state.
- **`vc-status-stage`** and **`vc-status-unstage`** (`stageName`,
  `unstageName`, the mode's leader suffixes `s` and `u`): the explicit
  forms, through the same job, saying the refusal sentence when there is
  nothing to do.

## The mode

`vc-status` (`mode`), whose buffer is read-only to editing commands
(`Editor/Command/Dispatch.lean`, "Read-only buffers"). It fills three
roles, `refresh` with `vc-status-refresh`, `activate` with
`vc-status-visit` and `toggle` with `vc-status-toggle`, and has the leader
suffixes `s`, `u`, `c` and `w`: `c` is `vc-commit`, which opens the message
buffer (`Editor/VersionControl/Commit.lean`), and `w` is `vc-worktrees`,
which opens the worktree list (`Editor/VersionControl/Worktrees.lean`). It needs no key of its own: each scheme's role table
puts its keys on the roles.

Pinned by `ModelTest.statusViewChecks` on the model's values,
`ModelTest.statusBufferChecks` on the loop's driver over the editor's
models, the job model and the model of a repository, and
`ContractTest.statusBufferChecks` over real git.
-/

namespace Editor.VersionControl

/-- The name the command that opens the status buffer is registered under,
and the opener it is shown for. -/
def statusName : String :=
  "vc-status"

/-- The name the command that reads the status again is registered
under. -/
def refreshName : String :=
  "vc-status-refresh"

/-- The name the command that visits the cursor's file is registered
under. -/
def visitName : String :=
  "vc-status-visit"

/-- The name the command that stages or unstages the cursor's file is
registered under. -/
def toggleName : String :=
  "vc-status-toggle"

/-- The name the command that stages the cursor's file is registered
under. -/
def stageName : String :=
  "vc-status-stage"

/-- The name the command that unstages the cursor's file is registered
under. -/
def unstageName : String :=
  "vc-status-unstage"

/-- The name the command that opens the message buffer
(`Editor/VersionControl/Commit.lean`) is registered under, and the opener its
buffers are shown for: the status buffer's leader suffix `c`. -/
def commitName : String :=
  "vc-commit"

/-- The name the command that opens the worktree list
(`Editor/VersionControl/Worktrees.lean`) is registered under, and the opener
its buffer is shown for: the status buffer's leader suffix `w`. -/
def worktreesName : String :=
  "vc-worktrees"

/-- The name the job that reads a status is registered under. -/
def readJob : String :=
  "vc-status-read"

/-- The name the job that stages or unstages is registered under. -/
def applyJob : String :=
  "vc-status-apply"

/-- The name of the status buffer's major mode. -/
def modeName : String :=
  "vc-status"

/-! ## The view -/

/-- A change, for a person. -/
def Change.describe : Change → String
  | .added => "added"
  | .modified => "modified"
  | .deleted => "deleted"

/-- A conflict, for a person. -/
def Conflict.describe : Conflict → String
  | .bothModified => "both modified"
  | .bothAdded => "both added"
  | .bothDeleted => "both deleted"
  | .addedByUs => "added by us"
  | .addedByThem => "added by them"
  | .deletedByUs => "deleted by us"
  | .deletedByThem => "deleted by them"

namespace StatusView

/-- The state a line names ("The view", in the module docs). -/
def label : FileState → String
  | .changed (some _) none => "staged"
  | .changed none (some _) => "unstaged"
  | .changed (some _) (some _) => "staged, unstaged"
  | .changed none none => "unchanged"
  | .renamed _ none => "renamed"
  | .renamed _ (some _) => "renamed, unstaged"
  | .untracked => "untracked"
  | .conflicted _ => "conflicted"

/-- How a line's state came about, where there is more to say. -/
def detail : FileState → Option String
  | .changed (some staged) none => some staged.describe
  | .changed none (some unstaged) => some unstaged.describe
  | .changed (some staged) (some unstaged) => some s!"{staged.describe}, {unstaged.describe}"
  | .changed none none => none
  | .renamed origin none => some s!"from {origin}"
  | .renamed origin (some unstaged) => some s!"from {origin}, {unstaged.describe}"
  | .untracked => none
  | .conflicted how => some how.describe

/-- The line of `file`: its state, its path, and its detail. -/
def line (file : FileStatus) : String :=
  let base := s!"{label file.state}: {file.path}"
  match detail file.state with
  | some said => s!"{base} ({said})"
  | none => base

/-- What is checked out, as the head line says it. -/
def headText : Head → String
  | .branch name => s!"on {name}"
  | .detached => "detached"

/-- The text of the status buffer of the workspace labelled `label` for
`status`: the head line, then one line per file, or `no changes`; each
line ended by a line feed. -/
def render (label : String) (status : Status) : String :=
  let rows := if status.files.isEmpty then #["no changes"] else status.files.map line
  String.join ((#[s!"{label}: {headText status.head}"] ++ rows).toList.map (· ++ "\n"))

/-- The file on row `row` of a status buffer showing `files`: none on the
head line, or past the last file. -/
def fileAt (files : Array FileStatus) (row : Nat) : Option FileStatus :=
  match row with
  | 0 => none
  | row + 1 => files[row]?

/-- Whether `state` has something to stage: it is untracked, conflicted, or
changed in the working tree. -/
def stageable : FileState → Bool
  | .changed _ (some _) | .renamed _ (some _) | .untracked | .conflicted _ => true
  | _ => false

/-- The paths that unstage `file`, when it has something staged: a rename's
both. -/
def staged? (file : FileStatus) : Option (Array String) :=
  match file.state with
  | .changed (some _) _ => some #[file.path]
  | .renamed origin _ => some #[file.path, origin]
  | _ => none

/-- What toggling `file` asks ("The view", in the module docs). -/
def toggleRequest (file : FileStatus) : Request :=
  if stageable file.state then .stage #[file.path]
  else
    match staged? file with
    | some paths => .unstage paths
    | none => .stage #[file.path]

/-- What staging `file` asks, or why it asks nothing. -/
def stageRequest (file : FileStatus) : Except String Request :=
  if stageable file.state then .ok (.stage #[file.path])
  else .error s!"{stageName}: {file.path} has nothing to stage"

/-- What unstaging `file` asks, or why it asks nothing. -/
def unstageRequest (file : FileStatus) : Except String Request :=
  match staged? file with
  | some paths => .ok (.unstage paths)
  | none => .error s!"{unstageName}: {file.path} has nothing staged"

/-- Whether `file`'s file is gone from the working tree, among the status's
`files` ("The view", in the module docs). -/
def deleted (files : Array FileStatus) (file : FileStatus) : Bool :=
  match file.state with
  | .changed _ (some .deleted) | .renamed _ (some .deleted) => true
  | .changed (some .deleted) none =>
    !files.any fun other => other.path == file.path && other.state == .untracked
  | _ => false

end StatusView

/-! ## The record -/

/-- A change as a tree. -/
def Change.encode : Change → Value
  | .added => .str "added"
  | .modified => .str "modified"
  | .deleted => .str "deleted"

/-- The change a tree is (`Change.encode`), if it is one. -/
def Change.decode? : Value → Option Change
  | .str "added" => some .added
  | .str "modified" => some .modified
  | .str "deleted" => some .deleted
  | _ => none

/-- Every kind of conflict. -/
def Conflict.all : List Conflict :=
  [.bothModified, .bothAdded, .bothDeleted, .addedByUs, .addedByThem, .deletedByUs, .deletedByThem]

/-- A change that may be none as a tree. -/
def encodeChange : Option Change → Value
  | some change => change.encode
  | none => .null

/-- The change that may be none a tree is (`encodeChange`), if it is one. -/
def decodeChange? : Value → Option (Option Change)
  | .null => some none
  | tree => some <$> Change.decode? tree

/-- A state as a tree. -/
def FileState.encode : FileState → Value
  | .changed staged unstaged =>
    .record [("changed", .list [encodeChange staged, encodeChange unstaged])]
  | .renamed origin unstaged => .record [("renamed", .list [.str origin, encodeChange unstaged])]
  | .untracked => .str "untracked"
  | .conflicted how => .record [("conflicted", .str how.describe)]

/-- The state a tree is (`FileState.encode`), if it is one. -/
def FileState.decode? : Value → Option FileState
  | .record [("changed", .list [staged, unstaged])] =>
    return .changed (← decodeChange? staged) (← decodeChange? unstaged)
  | .record [("renamed", .list [.str origin, unstaged])] =>
    return .renamed origin (← decodeChange? unstaged)
  | .str "untracked" => some .untracked
  | .record [("conflicted", .str how)] => (Conflict.all.find? (·.describe == how)).map .conflicted
  | _ => none

/-- What a workspace keeps of its status buffer ("The record", in the module
docs). -/
structure StatusRecord where
  /-- The number of its status buffer. -/
  buffer : Option Nat := none
  /-- The files last shown, in row order from row 1. -/
  files : Array FileStatus := #[]
  deriving DecidableEq, Repr

/-- A record as a tree. -/
def StatusRecord.encode (record : StatusRecord) : Value :=
  .record
    [("buffer",
        match record.buffer with
        | some index => .nat index
        | none => .null),
      ("files",
        .list (record.files.toList.map fun file => .list [.str file.path, file.state.encode]))]

/-- The record a tree is (`StatusRecord.encode`), if it is one. -/
def StatusRecord.decode? : Value → Option StatusRecord
  | .record [("buffer", buffer), ("files", .list files)] => do
    let buffer ←
      match buffer with
      | .nat index =>
        some (some index)
      | .null =>
        some none
      | _ =>
        none
    let files ←
      files.toArray.mapM fun
          | .list [.str path, state] =>
            (fun state => ({ path, state } : FileStatus)) <$> FileState.decode? state
          | _ => none
    return { buffer, files }
  | _ => none

/-- A workspace's record of its status buffer. -/
def statusStore : Store StatusRecord :=
  { name := "vc-status", version := 1, initial := {}, encode := StatusRecord.encode
    decode := StatusRecord.decode? }

/-- The kept status buffer of `record`, while its number still names a
buffer. -/
def kept (state : EditorState) (record : StatusRecord) : Option BufferId :=
  (record.buffer.filter fun index => (state.buffer? ⟨index⟩).isSome).map (⟨·⟩)

/-! ## The orders -/

/-- The job key of the reads of the repository at `root`. -/
def keyOf (root : System.FilePath) : String :=
  s!"{statusName} {(Location.local root).describe}"

/-- What a read is started with. -/
structure ReadOrder where
  /-- The repository's root, the workspace's. -/
  root : System.FilePath
  /-- The git program. -/
  git : String
  /-- The workspace's label. -/
  label : String
  /-- The view that asked. -/
  view : ViewId
  /-- Whether the buffer is shown once it is written. -/
  shows : Bool
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with. -/
def ReadOrder.arguments (order : ReadOrder) : List Argument :=
  [.str order.root.toString, .str order.git, .str order.label, .nat order.view.index,
    .bool order.shows]

/-- The order `arguments` are, if they are one (`ReadOrder.arguments`). -/
def ReadOrder.ofArguments? : List Argument → Option ReadOrder
  | [.str root, .str git, .str label, .nat view, .bool shows] =>
    some { root, git, label, view := ⟨view⟩, shows }
  | _ => none

/-- What a write is started with: the read it is followed by, and the
request, a stage or an unstage. -/
structure ApplyOrder where
  /-- The read that follows it, whose `shows` is off. -/
  read : ReadOrder
  /-- The request. -/
  request : Request
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with: the read's, less its
`shows`, then the request's kind and its paths. -/
def ApplyOrder.arguments (order : ApplyOrder) : List Argument :=
  let (kind, paths) :=
    match order.request with
    | .stage paths => ("stage", paths)
    | .unstage paths => ("unstage", paths)
    | _ => ("status", #[])
  (order.read.arguments.take 4) ++ .str kind :: paths.toList.map .str

/-- The order `arguments` are, if they are one (`ApplyOrder.arguments`). -/
def ApplyOrder.ofArguments? : List Argument → Option ApplyOrder
  | .str root :: .str git :: .str label :: .nat view :: .str kind :: rest => do
    let paths ←
      rest.toArray.mapM fun
          | .str path => some path
          | _ => none
    let request ←
      match kind with
      | "stage" =>
        some (Request.stage paths)
      | "unstage" =>
        some (.unstage paths)
      | _ =>
        none
    return { read := { root, git, label, view := ⟨view⟩, shows := false }, request }
  | _ => none

/-- A write as a program over the port: a stage or an unstage, and for any
other request a status read, whose status is dropped. -/
def write : Request → VersionControlM (Except Error Unit)
  | .stage paths => stage paths
  | .unstage paths => unstage paths
  | _ => do
    return (← status).map fun _ => ()

/-! ## The buffer and the commands -/

/-- The name of the status buffer of the workspace labelled `label`. -/
def bufferName (label : String) : String :=
  s!"*{statusName}: {label}*"

/-- What a command says of a refusal of the version-control interface. -/
def failed (error : Error) : String :=
  s!"{statusName}: {error.describe}"

/-- Starts the read of `order`, keyed by its root; a start that is refused
is said. -/
def startRead (order : ReadOrder) : EditorM Unit := do
  if let .error refusal← startJob readJob order.arguments (key := some (keyOf order.root)) then
    message s!"{statusName}: {refusal.describe}"

/-- The row of the cursor of `view` showing `text`, if it has one. -/
def cursorRow (view : ViewId) (text : TextId) : EditorM (Option Nat) := do
  match ← view.selection with
  | .ok selection =>
    let head := (selection.ranges[selection.primary]?.map (·.head)).getD 0
    return some (← text.pointOf head).row
  | .error _ =>
    return none

/-- Replaces the text of the status buffer `id` with `content`, inside
`writing`, each view of it keeping its cursor's row, clamped to the
text. -/
def replace (id : BufferId) (content : String) : EditorM Unit := do
  let .ok text ← id.text | return
  let state ← editorState
  let mut rows := #[]
  for window in state.windows.filter (·.buffer == id) do
    if let some row← cursorRow window.id text then
      rows := rows.push (window.id, row)
  id.writing do
      text.replaceRange 0 (← text.byteLength) content
  let count ← text.lineCount
  for (view, row) in rows do
    Files.placeCursor view (← text.offsetOf ⟨min row (count - 1), 0⟩)

/-- The command a finished read hands the loop ("What the read comes to", in
the module docs). -/
def shown (order : ReadOrder) (reply : Except Error Status) : EditorM Unit := do
  match reply with
  | .error error =>
    message (failed error)
  | .ok status =>
    let location := Location.local order.root
    let state ← editorState
    let record := state.workspaces.get statusStore location
    let content := StatusView.render order.label status
    let id ←
      match kept state record with
      | some id =>
        replace id content
        pure id
      | none =>
        let .ok id ← createBuffer (state.freeName (bufferName order.label)) content | return
        discard <| id.setReadOnly true
        Workspace.setBufferWorkspace id location
        discard <| id.setMajorMode modeName
        pure id
    discard <| Workspace.set statusStore location { buffer := some id.index, files := status.files }
    if order.shows then
      let state ← editorState
      let asking := if (state.window? order.view).isSome then order.view else state.frame.focused
      discard <| id.display asking statusName

/-- The read job: asks its order's repository for its status through git,
and finishes with what it comes to (`shown`). It fails only for arguments
that are not a read order. -/
def readWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    ReadOrder.ofArguments? arguments | throw s!"{readJob}: its arguments are not a read order"
  return shown order (← Program.runM (Git.handler order.git order.root) status)

/-- The command a finished write hands the loop: a failure is said, and
otherwise the status is read again into the buffer, without showing it. -/
def applied (order : ApplyOrder) (reply : Except Error Unit) : EditorM Unit := do
  match reply with
  | .error error =>
    message (failed error)
  | .ok () =>
    startRead order.read

/-- The write job: runs its order's request through git, and finishes with
what it comes to (`applied`). It fails only for arguments that are not a
write order. -/
def applyWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    ApplyOrder.ofArguments? arguments | throw s!"{applyJob}: its arguments are not a write order"
  return applied order
      (← Program.runM (Git.handler order.read.git order.read.root) (write order.request))

/-- The git program config's workspace settings name. -/
def gitProgram : EditorM String := do
  return (← RegistryRequest.ask .workspaceSettings).1.git

/-- The read the command `name` asks of the focused buffer's workspace, shown:
`none`, said, when the buffer has no workspace or its location cannot run
commands ("The commands", in the module docs). `vc-status`'s gate, which
`vc-worktrees` shares. -/
def readOrder (name : String) (call : Call) : EditorM (Option ReadOrder) := do
  match (← editorState).workspaceOf? call.target.window.buffer with
  | none =>
    message s!"{name}: {call.target.buffer.name} has no workspace"
    return none
  | some (workspace, _) =>
    match workspace.location with
    | .local root =>
      if workspace.location.can.runCommands then
        return some
            { root, git := ← gitProgram, label := workspace.label, view := call.target.window.id
              shows := true }
      else
        message s!"{name}: {workspace.label} cannot run commands"
        return none
    | _ =>
      message s!"{name}: {workspace.label} cannot run commands"
      return none

/-- `vc-status` ("The commands", in the module docs). Its arguments are
ignored. -/
def statusCommand (call : Call) : EditorM Unit := do
  if let some order← readOrder statusName call then
    startRead order

/-- The read of the status buffer `call` was made in, as the command `name`
asks it, with the files it shows; said and `none` when the buffer is not its
workspace's kept status buffer. -/
def statusOf (call : Call) (name : String) : EditorM (Option (ReadOrder × StatusRecord)) := do
  let state ← editorState
  let buffer := call.target.window.buffer
  let notStatus := s!"{name}: {call.target.buffer.name} is not a status buffer"
  let some (workspace, _) := state.workspaceOf? buffer |
    message notStatus;
    return none
  let .local root := workspace.location |
    message notStatus;
    return none
  let record := state.workspaces.get statusStore workspace.location
  if kept state record != some buffer then
    message notStatus
    return none
  let order : ReadOrder :=
    { root, git := ← gitProgram, label := workspace.label, view := call.target.window.id
      shows := false }
  return some (order, record)

/-- The file on the row of `call`'s cursor among `files`. -/
def cursorFile (call : Call) (files : Array FileStatus) : EditorM (Option FileStatus) := do
  let selection ← call.target.selection
  let head := (selection.ranges[selection.primary]?.map (·.head)).getD 0
  let row := (← call.target.buffer.text.pointOf head).row
  return StatusView.fileAt files row

/-- What a command says on a row with no file. -/
def noFile : String :=
  s!"{statusName}: no file on this line"

/-- `vc-status-refresh` ("The commands", in the module docs). -/
def refreshCommand (call : Call) : EditorM Unit := do
  let some (order, _) ← statusOf call refreshName | return
  startRead order

/-- `vc-status-visit` ("The commands", in the module docs). -/
def visitCommand (call : Call) : EditorM Unit := do
  let some (order, record) ← statusOf call visitName | return
  let some file ← cursorFile call record.files | message noFile
  if StatusView.deleted record.files file then
    message s!"{visitName}: {file.path} is deleted"
  else
    Files.visit call.target.window.id (order.root / file.path) { row := 0, column := 0 } true

/-- Starts the write `request` for the status buffer of `order`. -/
def startWrite (order : ReadOrder) (request : Request) : EditorM Unit := do
  if let .error refusal← startJob applyJob (ApplyOrder.arguments { read := order, request }) then
    message s!"{statusName}: {refusal.describe}"

/-- The command `name` that applies `choose` to the cursor's file: its
request is started, and a refusal said. -/
def onCursorFile (name : String) (choose : FileStatus → Except String Request) (call : Call) :
    EditorM Unit := do
  let some (order, record) ← statusOf call name | return
  let some file ← cursorFile call record.files | message noFile
  match choose file with
  | .ok request =>
    startWrite order request
  | .error sentence =>
    message sentence

/-- `vc-status-toggle` ("The commands", in the module docs). -/
def toggleCommand (call : Call) : EditorM Unit :=
  onCursorFile toggleName (fun file => .ok (StatusView.toggleRequest file)) call

/-- `vc-status-stage` ("The commands", in the module docs). -/
def stageCommand (call : Call) : EditorM Unit :=
  onCursorFile stageName StatusView.stageRequest call

/-- `vc-status-unstage` ("The commands", in the module docs). -/
def unstageCommand (call : Call) : EditorM Unit :=
  onCursorFile unstageName StatusView.unstageRequest call

/-- The `vc-status` mode ("The mode", in the module docs). -/
def mode : Mode :=
  { name := modeName
    roles := [(Role.refresh, refreshName), (Role.activate, visitName), (Role.toggle, toggleName)]
    locals := [("s", stageName), ("u", unstageName), ("c", commitName), ("w", worktreesName)] }

end Editor.VersionControl
