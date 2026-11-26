import Acp.Conversation.Store
import Acp.Generated
import Acp.Permissions.Audit
import Acp.Permissions.Outbox
import Acp.Permissions.Queue
import Editor.Api
import Editor.Job

/-!
# The queue of permission requests and the audit log, on the editor side

What acp keeps and writes of permission requests, over the editor API
(`docs/design/agent-hosting.md`, "Permissions, as built"). The pure parts
are the modules under `Acp/Permissions/`; the conversation's commands
(`Acp/Conversation.lean`) call this module, which reads the conversations
from their store (`Acp/Conversation/Store.lean`) and never imports the
commands.

## The queue buffer

One buffer a project, `*agent permissions: <project>*` or the first free
name of it, read-only, in the major mode `agent-permissions`, in the
workspace of the buffer it was opened from, so its project is that
buffer's. Its text is derived from the conversations on every redraw
(`Acp.Permissions.entries`), never kept apart, so a reload loses nothing;
each change of a conversation, and each close of a conversation buffer,
writes every queue buffer again, each view keeping its row
(`Acp.Generated.rewrite`). The queue buffers' numbers are kept in an
unscoped store (`queueStore`); closing one drops it from the store.

## The audit log

`<state>/agents/permissions.log`, under the host's state directory
(`EditorState.stateDirectory`), one file for the editor; with no state
directory nothing is logged. Records (`Acp/Permissions/Audit.lean`) go to
an outbox in an unscoped store (`auditStore`), whose rules are the pure
`Acp/Permissions/Outbox.lean`'s: when no write is in flight, its lines are
handed to one job, `agent-audit`, as one text, which makes the log's
directory and then appends the text, and returns the result as a value.
Its command drops the lines it wrote, says a refusal once, and starts the
next write if more lines are waiting. This module only keeps the outbox,
starts the job each transition hands it and says a refusal. So the appends
reach the file service one at a time, in the order the records were made,
and none is lost: two jobs at once could land out of order, and a keyed job
would cancel an older one. The only order sent for the log is an append, after a
make of its directory: nothing saves over it, removes it or reads it.
-/

namespace Acp.Permissions

open Editor
open AgentsApi

/-- The name of the queue buffer's major mode. -/
def modeName : String :=
  "agent-permissions"

/-- The name of the job that appends the audit log. -/
def auditJob : String :=
  "agent-audit"

/-- The audit log under the state directory `state`. -/
def logPath (state : System.FilePath) : System.FilePath :=
  state / "agents" / "permissions.log"

/-- The numbers of the queue buffers, in the unscoped store. -/
def queueStore : Store (Array Nat) :=
  { name := "acp-permission-queues", version := 1, initial := #[]
    encode := fun all => .list (all.toList.map .nat)
    decode := fun
      | .list items =>
        items.toArray.mapM fun item =>
          match item with
          | .nat number => some number
          | _ => none
      | _ => none }

/-- The audit log's outbox (`Acp/Permissions/Outbox.lean`), in the unscoped
store. -/
def auditStore : Store Outbox :=
  { name := "acp-permission-audit", version := 1, initial := {}, encode := Outbox.encode
    decode := Outbox.decode }

/-! ## The audit log -/

/-- Keeps `outbox` and hands its write, if it started one, to `agent-audit`
(the module docs). A write whose job could not start is said, and its lines
wait in the outbox with no write in flight. -/
def startWrite (outbox : Outbox) (write : Option Outbox.Write) : EditorM Unit := do
  let started ←
    match write, (← editorState).stateDirectory with
    | some write, some directory =>
      match ← startJob auditJob [.str directory.toString, .str write.text, .nat write.count] with
      | .ok () =>
        pure true
      | .error refusal =>
        message s!"agent audit log: {refusal.describe}"
        pure false
    | some _, none =>
      pure false
    | none, _ =>
      pure true
  Workspace.setUnscoped auditStore (if started then outbox else { outbox with writing := none })

/-- What the command of a finished `agent-audit` does: a refusal of the log
at `path` said once, and the outbox's `Outbox.wrote` of the `count` lines
the write held. -/
def audited (count : Nat) (path : String) (refusal : Option FileError) : EditorM Unit := do
  if let some error := refusal then
    message s!"agent audit log: {path} not written: {error.describe}"
  let (outbox, write) := ((← editorState).workspaces.getUnscoped auditStore).wrote count
  startWrite outbox write

/-- `agent-audit`: makes the log's directory under the state directory its
arguments name, appends their text, and finishes with the result, never
throwing for a refusal of the file service. -/
def auditWork (arguments : List Argument) : Work := fun _ => do
  let [.str directory, .str text, .nat count] := arguments
    | throw s!"{auditJob}: its arguments are not a directory, a text and a count"
  let path := logPath directory
  let refusal ←
    match ← File.makeDirectory (path.parent.getD directory) with
    | .error error =>
      pure (some error)
    | .ok () =>
      match ← File.append path text.toUTF8 with
      | .error error =>
        pure (some error)
      | .ok () =>
        pure none
  return audited count path.toString refusal

/-- Appends `records` to the audit log (the module docs): the outbox's
`Outbox.enqueue` of their lines. Nothing with no state directory. -/
def audit (records : Array Record) : EditorM Unit := do
  if records.isEmpty || (← editorState).stateDirectory.isNone then
    return
  let (outbox, write) :=
    ((← editorState).workspaces.getUnscoped auditStore).enqueue (records.map (·.line))
  startWrite outbox write

/-! ## The queue -/

/-- The name of the project of the workspace at `location`, or the
location's own words when it is no workspace's. -/
def projectName (location : Location) : EditorM String := do
  let state ← editorState
  return ((state.workspaces.workspace? location).map (·.project.name)).getD location.describe

/-- The queue of the project of `buffer`'s workspace: the project's name and
its entries; none for a buffer with no workspace. -/
def queueOf? (buffer : BufferId) : EditorM (Option (String × Array Entry)) := do
  let state ← editorState
  let some (_, project) := state.workspaceOf? buffer | return none
  let inProject (location : Location) : Bool :=
    (state.workspaces.workspace? location).any (·.project.identity == project.identity)
  return some (project.name, entries (← Acp.Conversation.conversations) inProject)

/-- The numbers of the queue buffers. -/
def queueBuffers : EditorM (Array Nat) := do
  return (← editorState).workspaces.getUnscoped queueStore

/-- Writes the text of every queue buffer again (the module docs). -/
def redrawQueues : EditorM Unit := do
  let view ← Acp.Conversation.chosenView
  for index in ← queueBuffers do
    if let some (project, found)← queueOf? ⟨index⟩ then
      Generated.rewrite ⟨index⟩ (text view project found) (follow := false)

/-- Drops the buffer `id` from the queue buffers, if it is one. -/
def closingQueue (id : BufferId) : EditorM Unit := do
  let held ← queueBuffers
  if held.contains id.index then
    Workspace.setUnscoped queueStore (held.filter (· != id.index))

/-- The queue buffer of the project `identity`, if one is open. -/
def queueBufferOf? (identity : Project.Identity) : EditorM (Option BufferId) := do
  let state ← editorState
  return (← queueBuffers).findSome? fun index =>
      let id : BufferId := ⟨index⟩
      match state.workspaceOf? id with
      | some (_, project) => if project.identity == identity then some id else none
      | none => none

/-- Shows the queue of `project`, whose workspace is at `location`, where the
display rules say for the opener `opener` acting on `asking`: its buffer,
made if none is open, written again. Says under `opener` when it cannot be
made. -/
def showQueue (asking : ViewId) (location : Location) (project : Project) (opener : String) :
    EditorM Unit := do
  let id ←
    match ← queueBufferOf? project.identity with
    | some id =>
      pure id
    | none =>
      let .ok id ← createBuffer ((← editorState).freeName s!"*agent permissions: {project.name}*") |
        message s!"{opener}: the queue buffer could not be made"
        return
      discard <| id.setReadOnly true
      Workspace.setBufferWorkspace id location
      discard <| id.setMajorMode modeName
      Workspace.setUnscoped queueStore ((← queueBuffers).push id.index)
      pure id
  redrawQueues
  discard <| id.display asking opener

end Acp.Permissions
