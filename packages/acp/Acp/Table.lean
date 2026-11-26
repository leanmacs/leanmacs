import Acp.Conversation.Store
import Acp.Generated
import Acp.Table.List
import AgentsApi.Table
import Editor.Api
import Editor.Job

/-!
# The agent table, the agents lists and the stall watchdog, on the editor side

What acp keeps of each project's agent table (`AgentsApi/Table.lean`,
`docs/design/agent-hosting.md`, "The agent table and resume, as built"),
over the editor API. The conversation's commands (`Acp/Conversation.lean`)
feed it; this module reads the conversations from their store
(`Acp/Conversation/Store.lean`) and never imports the commands.

## The table

A project's records live in its project store (`AgentsApi.Table.store`,
the cell `agents-table`), whose codec `Acp.setup` registers, so they are
kept across a restart (`AgentsApi.Table.keep`). An agent's id is minted by
`agent-start` one past the largest id of any project's table and of any
conversation (`mint`), so a kept id is never reused; it is the number of
the agent's conversation. `change` applies changes to the record of an id,
wherever its project is, writes the table back, writes every agents list
again and arms the watchdog.

## The stall watchdog

What the watchdog decides is the pure core's (`AgentsApi/Table.lean`):
whom it watches (`AgentRecord.watched`) and its verdict at a deadline
(`AgentRecord.verdict`); this module only carries them out. While a record
is watched, one job, `agent-stall`, keyed `agent-stall <id>` and carrying
the generation it was armed at, waits on the job clock until its deadline:
`AgentRecord.stallTimeout` from its start, or the deadline its verdict
gave. It is armed once, not again for each batch, so a stream of batches
starts no jobs; at its deadline its command does what the verdict says,
with the record as it is then. A record no longer watched has its watchdog
cancelled. The ids whose watchdog is armed are kept in an unscoped store
(`armedStore`); when the session was last heard from is the record's
(`AgentRecord.heardAt`), from the time the session job stamps on its
batch.

## The agents lists

One buffer a project, `*agents: <project>*` or the first free name of it,
read-only, in the major mode `agent-list`, in the workspace of the buffer
it was opened from. Its text is derived from the project's table and the
conversations on every redraw (`Acp/Table/List.lean`), never kept apart;
each change of the table or of a conversation writes every list again,
each view keeping its row (`Acp.Generated.rewrite`). The lists' numbers
are kept in an unscoped store (`listStore`); closing one drops it.
-/

namespace Acp.Table

open Editor
open AgentsApi

/-- The name of the agents list's major mode. -/
def modeName : String :=
  "agent-list"

/-- The name of the stall watchdog's job. -/
def stallJob : String :=
  "agent-stall"

/-- The key the stall watchdog of the agent `id` runs under. -/
def stallKey (id : Nat) : String :=
  s!"{stallJob} {id}"

/-- The numbers of the agents lists, in an unscoped store. -/
def listStore : Store (Array Nat) :=
  { name := "acp-agent-lists", version := 1, initial := #[]
    encode := fun numbers => .list (numbers.toList.map .nat)
    decode := fun
      | .list items =>
        items.toArray.mapM fun
          | .nat number => some number
          | _ => none
      | _ => none }

/-- The records of the project `identity`. -/
def records (identity : Project.Identity) : EditorM (Array AgentRecord) := do
  return (← editorState).workspaces.getOfProject Table.store identity

/-- The project of the workspace at `location`, if it is one's. -/
def projectOf? (location : Location) : EditorM (Option Project) := do
  return ((← editorState).workspaces.workspace? location).map (·.project)

/-- Every project's identity, name and records. -/
def everyTable : EditorM (Array (Project × Array AgentRecord)) := do
  let state ← editorState
  return state.workspaces.projects.map fun (project, _) =>
      (project, state.workspaces.getOfProject Table.store project.identity)

/-- The record of the agent `id` and its project, wherever it is. -/
def locate? (id : Nat) : EditorM (Option (Project × AgentRecord)) := do
  return (← everyTable).findSome? fun (project, held) =>
      (held.find? (·.id == id)).map fun record => (project, record)

/-- The id to mint for a new agent: one past the largest of every project's
table and every conversation. -/
def mint : EditorM Nat := do
  let kept := (← everyTable).flatMap fun (_, held) => held.map (·.id)
  let live := (← Acp.Conversation.conversations).map (·.number)
  return AgentsApi.Table.mint (kept ++ live)

/-- Whether a session of the agent `id` runs in this process: a
conversation of its id that has not ended. -/
def running (conversations : Array Conversation) (id : Nat) : Bool :=
  conversations.any fun conversation => conversation.number == id && conversation.ended.isNone

/-- The numbers of the agents lists. -/
def listBuffers : EditorM (Array Nat) := do
  return (← editorState).workspaces.getUnscoped listStore

/-- The agents list of the project of `buffer`'s workspace: the project and
its records; none for a buffer with no workspace. -/
def listOf? (buffer : BufferId) : EditorM (Option (Project × Array AgentRecord)) := do
  let some (_, project) := (← editorState).workspaceOf? buffer | return none
  return some (project, ← records project.identity)

/-- Writes the text of every agents list again (the module docs). -/
def redrawLists : EditorM Unit := do
  let view ← Acp.Conversation.chosenView
  let conversations ← Acp.Conversation.conversations
  for index in ← listBuffers do
    if let some (project, held)← listOf? ⟨index⟩ then
      Generated.rewrite ⟨index⟩ (text view project.name held (running conversations)) (follow :=
          false)

/-- Drops the buffer `id` from the agents lists, if it is one. -/
def closingList (id : BufferId) : EditorM Unit := do
  let held ← listBuffers
  if held.contains id.index then
    Workspace.setUnscoped listStore (held.filter (· != id.index))

/-- The ids of the agents whose stall watchdog is armed, in an unscoped
store. -/
def armedStore : Store (Array Nat) :=
  { name := "acp-agent-watch", version := 1, initial := #[]
    encode := fun ids => .list (ids.toList.map .nat)
    decode := fun
      | .list items =>
        items.toArray.mapM fun
          | .nat id => some id
          | _ => none
      | _ => none }

/-- The ids of the agents whose stall watchdog is armed. -/
def armedIds : EditorM (Array Nat) := do
  return (← editorState).workspaces.getUnscoped armedStore

/-- Notes whether the stall watchdog of the agent `id` is armed. -/
def setArmed (id : Nat) (armed : Bool) : EditorM Unit := do
  let held := (← armedIds).filter (· != id)
  Workspace.setUnscoped armedStore (if armed then held.push id else held)

/-- Starts the stall watchdog of the agent `id`, armed at the generation
`heard`, to wait until `deadline?`, or with none until
`AgentRecord.stallTimeout` after it starts. -/
def start (id heard : Nat) (deadline? : Option Nat) : EditorM Unit := do
  let deadline :=
    match deadline? with
    | some deadline => [.bool true, .nat deadline]
    | none => [.bool false]
  if (← startJob stallJob (.nat id :: .nat heard :: deadline) (key := some (stallKey id))).isOk then
    setArmed id true

/-- Arms the stall watchdog of `record` once it is watched, unless one is
armed; cancels an armed one once it is not (the module docs). -/
def arm (record : AgentRecord) : EditorM Unit := do
  let armed := (← armedIds).contains record.id
  if record.watched then
    unless armed do
      start record.id record.heard none
  else
    if armed then
      cancelJob (stallKey record.id)
      setArmed record.id false

/-- Applies `changes`, in order, to the record of the agent `id`, writes its
project's table back, writes every agents list again and arms the
watchdog; nothing for an id no table holds. -/
def change (id : Nat) (changes : Array AgentsApi.Change) : EditorM Unit := do
  let some (project, _) ← locate? id | return
  let held :=
    changes.foldl (fun held change => AgentsApi.Table.apply held { agent := id, change })
      (← records project.identity)
  discard <| Project.set Table.store project.identity held
  redrawLists
  if let some record := held.find? (·.id == id) then
    arm record

/-- Adds `record` to the table of the project of its workspace: whether it
was, since a workspace of no project has none. -/
def add (record : AgentRecord) : EditorM Bool := do
  let some project ← projectOf? record.location | return false
  discard <|
      Project.set Table.store project.identity
        (AgentsApi.Table.add (← records project.identity) record)
  redrawLists
  return true

/-- The command the stall watchdog of the agent `id`, armed at the
generation `armed`, hands the loop once the job clock reached `deadline`:
it carries out the record's verdict (`AgentRecord.verdict`, the module
docs). -/
def stalledCommand (id armed deadline : Nat) : EditorM Unit := do
  setArmed id false
  let some (_, record) ← locate? id | return
  match record.verdict armed deadline with
  | .rest =>
    pure ()
  | .stall heard =>
    change id #[.stalled heard]
  | .rearm deadline heard =>
    start id heard (some deadline)

/-- The stall watchdog (the module docs): waits on the job clock until its
deadline, or `AgentRecord.stallTimeout` from its start with none, then
hands the loop its command. -/
def stallWork (arguments : List Argument) : Work := fun _ => do
  let (id, armed, deadline) ←
    match arguments with
    | [.nat id, .nat armed, .bool true, .nat deadline] =>
      pure (id, armed, deadline)
    | [.nat id, .nat armed, .bool false] =>
      pure (id, armed, (← now) + AgentRecord.stallTimeout)
    | _ =>
      throw s!"{stallJob}: its arguments are not an agent, a generation and a deadline"
  waitUntil deadline
  return stalledCommand id armed deadline

/-- The agents list of the project `identity`, if one is open. -/
def listBufferOf? (identity : Project.Identity) : EditorM (Option BufferId) := do
  let state ← editorState
  return (← listBuffers).findSome? fun index =>
      let id : BufferId := ⟨index⟩
      match state.workspaceOf? id with
      | some (_, project) => if project.identity == identity then some id else none
      | none => none

/-- Shows the agents list of `project`, whose workspace is at `location`,
where the display rules say for the opener `opener` acting on `asking`: its
buffer, made if none is open, written again. Says under `opener` when it
cannot be made. -/
def showList (asking : ViewId) (location : Location) (project : Project) (opener : String) :
    EditorM Unit := do
  let id ←
    match ← listBufferOf? project.identity with
    | some id =>
      pure id
    | none =>
      let .ok id ← createBuffer ((← editorState).freeName s!"*agents: {project.name}*") |
        message s!"{opener}: the agents list could not be made"
        return
      discard <| id.setReadOnly true
      Workspace.setBufferWorkspace id location
      discard <| id.setMajorMode modeName
      Workspace.setUnscoped listStore ((← listBuffers).push id.index)
      pure id
  redrawLists
  discard <| id.display asking opener

end Acp.Table
