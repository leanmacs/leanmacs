import Editor.Api
import Editor.Buffers
import Editor.Command.Call
import Editor.Mode
import Editor.VersionControl.Git
import Editor.VersionControl.Status

/-!
# The message buffer: `vc-commit`

magit's commit message buffer: a buffer to write a commit's message in, and
the commands that commit with it or give it up. Written over the editor API
(`Editor/Api.lean`), the job port and the version-control interface's
`commit` (`Editor/VersionControl.lean`), through its git implementation.
Message conventions (a template, a summary line's length, trailers) are
config's business: the buffer starts empty, and what it holds is the
message, as it is.

## The commands

- **`vc-commit`** (`commitName`; the status buffer's leader suffix `c`),
  under `vc-status`'s gate: a buffer with no workspace, or a workspace that
  cannot run commands, says so and makes nothing. When the workspace's
  record names a live message buffer it is shown and focused. Otherwise it
  makes `*vc-commit: <label>*` (`EditorState.freeName`): empty, editable,
  with no file, given the workspace, in the mode `vc-commit`, shown where
  the display rules say for the opener `vc-commit`, and focused.
- **`vc-commit-accept`** (`acceptName`; the mode's leader suffix `c`, as
  magit's `C-c C-c`): only in its workspace's kept message buffer, else
  `vc-commit-accept: <buffer> is not a commit message buffer`. With a
  commit in flight it says `a commit is running`. Otherwise it reads the
  buffer's text and its revision, records the commit as in flight, and
  starts the unkeyed job `vc-commit-run` with the root, the git program,
  the label, the view, the buffer, the revision and the text.
- **`vc-commit-run`** asks for the commit (`commit`). What it comes to
  (`committed`) ends the commit in flight:
  - **A commit made** removes the message buffer if its text is still at
    the revision accepted, and otherwise keeps it and says so. It says
    `vc-commit: committed <first line>`, and starts the read of the
    workspace's kept status buffer, if it has one, without showing it.
    The gutter's watch sees `HEAD` move and refreshes every tracked
    buffer.
  - **A refusal of git's** (`failed`: nothing staged, a conflict, a hook)
    writes everything git printed into the read-only
    `*vc-commit-output: <label>*`, in place of its text, shown for the
    opener `vc-commit` without taking the focus, so a hook's output is
    seen and not swallowed. The message buffer is kept with its text, to
    be fixed and accepted again. The echo area says `vc-commit:
    <Error.describe> (output in *vc-commit-output: <label>*)`.
  - **Any other refusal** (git could not run, or printed what cannot be
    read) is said in the echo area only.
- **`vc-commit-abort`** (`abortName`; the mode's leader suffix `k`, as
  magit's `C-c C-k`): in the kept message buffer, closes it (every window
  that showed it shows the most recent buffer left,
  `Buffers.closeInto`) and forgets it; refused while a commit runs.

## The record

Each workspace keeps a `CommitRecord` in its store (`commitStore`), as the
shell keeps what it runs (`Shell.runningStore`): the numbers of its message
buffer and its output buffer, each found by its number and never by its
name, and whether a commit is in flight.

## The mode

`vc-commit` (`commitMode`): no role, and the leader suffixes `c` and `k`.
Accept and abort are actions of this mode alone, so they are its locals,
not roles (`Editor/Role.lean`, "The rule for adding a role").

Pinned by `ModelTest.commitBufferChecks` on the loop's driver over the
editor's models, the job model and the model of a repository, and
`ContractTest.statusBufferChecks` over real git.
-/

namespace Editor.VersionControl

/-- The name the command that commits with the message buffer's text is
registered under. -/
def acceptName : String :=
  "vc-commit-accept"

/-- The name the command that gives the message buffer up is registered
under. -/
def abortName : String :=
  "vc-commit-abort"

/-- The name the job that commits is registered under. -/
def commitJob : String :=
  "vc-commit-run"

/-- The name of the message buffer's major mode. -/
def commitModeName : String :=
  "vc-commit"

/-- The name of the message buffer of the workspace labelled `label`. -/
def messageBufferName (label : String) : String :=
  s!"*{commitName}: {label}*"

/-- The name of the buffer a refused commit's output is written into, of the
workspace labelled `label`. -/
def outputBufferName (label : String) : String :=
  s!"*{commitName}-output: {label}*"

/-! ## The record -/

/-- What a workspace keeps of its message buffer ("The record", in the module
docs). -/
structure CommitRecord where
  /-- The number of its message buffer. -/
  buffer : Option Nat := none
  /-- The number of the buffer a refused commit's output is written into. -/
  output : Option Nat := none
  /-- Whether a commit is in flight. -/
  committing : Bool := false
  deriving DecidableEq, Repr

/-- A buffer's number that may be none, as a tree. -/
def encodeNumber : Option Nat → Value
  | some index => .nat index
  | none => .null

/-- The buffer's number that may be none a tree is (`encodeNumber`), if it is
one. -/
def decodeNumber? : Value → Option (Option Nat)
  | .nat index => some (some index)
  | .null => some none
  | _ => none

/-- A record as a tree. -/
def CommitRecord.encode (record : CommitRecord) : Value :=
  .record
    [("buffer", encodeNumber record.buffer), ("output", encodeNumber record.output),
      ("committing", .bool record.committing)]

/-- The record a tree is (`CommitRecord.encode`), if it is one. -/
def CommitRecord.decode? : Value → Option CommitRecord
  | .record [("buffer", buffer), ("output", output), ("committing", .bool committing)] => do
    return { buffer := ← decodeNumber? buffer, output := ← decodeNumber? output, committing }
  | _ => none

/-- A workspace's record of its message buffer. -/
def commitStore : Store CommitRecord :=
  { name := "vc-commit", version := 1, initial := {}, encode := CommitRecord.encode
    decode := CommitRecord.decode? }

/-- The buffer `index` names, while it names one. -/
def live (state : EditorState) (index : Option Nat) : Option BufferId :=
  (index.filter fun index => (state.buffer? ⟨index⟩).isSome).map (⟨·⟩)

/-! ## The order -/

/-- What a commit is started with. -/
structure CommitOrder where
  /-- The repository's root, the workspace's. -/
  root : System.FilePath
  /-- The git program. -/
  git : String
  /-- The workspace's label. -/
  label : String
  /-- The view that asked. -/
  view : ViewId
  /-- The message buffer. -/
  buffer : BufferId
  /-- The revision of its text that was accepted. -/
  revision : Nat
  /-- The message: the buffer's text. -/
  message : String
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with. -/
def CommitOrder.arguments (order : CommitOrder) : List Argument :=
  [.str order.root.toString, .str order.git, .str order.label, .nat order.view.index,
    .nat order.buffer.index, .nat order.revision, .str order.message]

/-- The order `arguments` are, if they are one (`CommitOrder.arguments`). -/
def CommitOrder.ofArguments? : List Argument → Option CommitOrder
  | [.str root, .str git, .str label, .nat view, .nat buffer, .nat revision, .str message] =>
    some { root, git, label, view := ⟨view⟩, buffer := ⟨buffer⟩, revision, message }
  | _ => none

/-- The read of the status buffer of `order`'s workspace, which does not show
it. -/
def CommitOrder.read (order : CommitOrder) : ReadOrder :=
  { root := order.root, git := order.git, label := order.label, view := order.view
    shows := false }

/-! ## The buffers and the commands -/

/-- Closes the message buffer `id` (`Buffers.closeInto`): every window that
showed it shows the most recent buffer left, or a new empty one. -/
def closeMessage (id : BufferId) : EditorM Unit := do
  let state ← editorState
  match state.mostRecent id with
  | some fallback =>
    Buffers.closeInto id fallback
  | none =>
    let .ok made ←
      createBuffer
          (state.freeName EditorState.scratchName) | giveUp "making the empty buffer was refused"
    Buffers.closeInto id made
    Buffers.unrefused "naming the empty buffer" (← made.rename EditorState.scratchName)

/-- Writes `output` into the output buffer of `order`'s workspace, made if it
has none, and shows it without taking the focus ("The commands", in the
module docs). -/
def showOutput (order : CommitOrder) (output : String) : EditorM Unit := do
  let location := Location.local order.root
  let state ← editorState
  let record := state.workspaces.get commitStore location
  let id ←
    match live state record.output with
    | some id =>
      replace id output
      pure id
    | none =>
      let .ok id ← createBuffer (state.freeName (outputBufferName order.label)) output | return
      discard <| id.setReadOnly true
      Workspace.setBufferWorkspace id location
      pure id
  let record := (← editorState).workspaces.get commitStore location
  discard <| Workspace.set commitStore location { record with output := some id.index }
  let state ← editorState
  let asking := if (state.window? order.view).isSome then order.view else state.frame.focused
  discard <| id.display asking commitName (focus := false)

/-- The command a finished commit hands the loop ("The commands", in the
module docs). -/
def committed (order : CommitOrder) (reply : Except Error Unit) : EditorM Unit := do
  let location := Location.local order.root
  let record := (← editorState).workspaces.get commitStore location
  discard <| Workspace.set commitStore location { record with committing := false }
  match reply with
  | .ok () =>
    let said := s!"{commitName}: committed {firstLine order.message}"
    let state ← editorState
    match live state record.buffer with
    | some id =>
      let some buffer := state.buffer? id | return
      if id == order.buffer && (← buffer.text.revision) == order.revision then
        closeMessage id
        let record := (← editorState).workspaces.get commitStore location
        discard <| Workspace.set commitStore location { record with buffer := none }
        message said
      else
        message s!"{said}; the message buffer was edited since, and is kept"
    | none =>
      message said
    let state ← editorState
    if (kept state (state.workspaces.get statusStore location)).isSome then
      startRead order.read
  | .error (.failed exit output) =>
    showOutput order output
    message
        s!"{commitName}: {(Error.failed exit output).describe} (output in {outputBufferName order.label})"
  | .error error =>
    message s!"{commitName}: {error.describe}"

/-- The commit job: commits its order's message through git, and finishes with
what it comes to (`committed`). It fails only for arguments that are not a
commit order. -/
def commitWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    CommitOrder.ofArguments? arguments | throw s!"{commitJob}: its arguments are not a commit order"
  return committed order (← Program.runM (Git.handler order.git order.root) (commit order.message))

/-- `vc-commit` ("The commands", in the module docs). Its arguments are
ignored. -/
def commitCommand (call : Call) : EditorM Unit := do
  let state ← editorState
  let some (workspace, _) :=
    state.workspaceOf?
      call.target.window.buffer | message s!"{commitName}: {call.target.buffer.name} has no workspace"
  let location := workspace.location
  let cannot := s!"{commitName}: {workspace.label} cannot run commands"
  let .local _ := location | message cannot
  unless location.can.runCommands do
    message cannot
    return
  let record := state.workspaces.get commitStore location
  let id ←
    match live state record.buffer with
    | some id =>
      pure id
    | none =>
      let .ok id ← createBuffer (state.freeName (messageBufferName workspace.label)) | return
      Workspace.setBufferWorkspace id location
      discard <| id.setMajorMode commitModeName
      discard <| Workspace.set commitStore location { record with buffer := some id.index }
      pure id
  discard <| id.display call.target.window.id commitName

/-- The message buffer `call` was made in, its workspace's root, label and
record, as the command `name` asks it; said and `none` when the buffer is
not its workspace's kept message buffer. -/
def messageOf (call : Call) (name : String) :
    EditorM (Option (System.FilePath × String × CommitRecord)) := do
  let state ← editorState
  let buffer := call.target.window.buffer
  let notMessage := s!"{name}: {call.target.buffer.name} is not a commit message buffer"
  let some (workspace, _) := state.workspaceOf? buffer |
    message notMessage;
    return none
  let .local root := workspace.location |
    message notMessage;
    return none
  let record := state.workspaces.get commitStore workspace.location
  if live state record.buffer != some buffer then
    message notMessage
    return none
  return some (root, workspace.label, record)

/-- `vc-commit-accept` ("The commands", in the module docs). -/
def acceptCommand (call : Call) : EditorM Unit := do
  let some (root, label, record) ← messageOf call acceptName | return
  if record.committing then
    message s!"{acceptName}: a commit is running"
    return
  let text := call.target.buffer.text
  let order : CommitOrder :=
    { root, git := ← gitProgram, label, view := call.target.window.id
      buffer := call.target.window.buffer, revision := ← text.revision, message := ← text.read }
  match ← startJob commitJob order.arguments with
  | .error refusal =>
    message s!"{acceptName}: {refusal.describe}"
  | .ok () =>
    discard <| Workspace.set commitStore (.local root) { record with committing := true }

/-- `vc-commit-abort` ("The commands", in the module docs). -/
def abortCommand (call : Call) : EditorM Unit := do
  let some (root, _, record) ← messageOf call abortName | return
  if record.committing then
    message s!"{abortName}: a commit is running"
    return
  closeMessage call.target.window.buffer
  discard <| Workspace.set commitStore (.local root) { record with buffer := none }

/-- The `vc-commit` mode ("The mode", in the module docs). -/
def commitMode : Mode :=
  { name := commitModeName, locals := [("c", acceptName), ("k", abortName)] }

end Editor.VersionControl
