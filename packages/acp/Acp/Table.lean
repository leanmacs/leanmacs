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

While a record's attention is `working` and it has not stalled, one job,
`agent-stall`, keyed `agent-stall <id>`, waits on the job clock until its
deadline: `stallTimeout` after the prompt, or after the session was last
heard from (`heard`: the job clock's time the session job stamped on its
batch). It is armed once, not again for each batch, so a stream of batches
starts no jobs; at its deadline its command arms it again for the last
batch's timeout if one came since, and otherwise tells the reducer the
agent stalled, at its current generation. A record that stops working has
its watchdog cancelled. What the watchdog keeps of each agent, when it was
last heard and whether a watchdog is armed, is in an unscoped store
(`watchStore`).

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

/-- How long a working agent may be silent before its activity is unknown,
in milliseconds on the job clock. -/
def stallTimeout : Nat :=
  120000

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

/-- What the stall watchdog keeps of an agent: when its session was last
heard from, on the job clock (none since its last prompt), and whether a
watchdog is armed for it. -/
structure Watch where
  /-- The agent's id. -/
  id : Nat
  /-- When its session's last batch was taken, on the job clock; none since
  its last prompt. -/
  heardAt : Option Nat := none
  /-- Whether a watchdog is armed for it. -/
  armed : Bool := false
  deriving DecidableEq, Repr

/-- What the watchdog keeps of each agent, in an unscoped store. -/
def watchStore : Store (Array Watch) :=
  { name := "acp-agent-watch", version := 1, initial := #[]
    encode := fun watches =>
      .list
        (watches.toList.map fun watch =>
          .list [.nat watch.id, (watch.heardAt.map Value.nat).getD .null, .bool watch.armed])
    decode := fun
      | .list items =>
        items.toArray.mapM fun
          | .list [.nat id, .null, .bool armed] => some { id, armed }
          | .list [.nat id, .nat heardAt, .bool armed] =>
            some { id, heardAt := some heardAt, armed }
          | _ => none
      | _ => none }

/-- What the watchdog keeps of the agent `id`. -/
def watchOf (id : Nat) : EditorM Watch := do
  return (((← editorState).workspaces.getUnscoped watchStore).find? (·.id == id)).getD { id }

/-- Keeps `watch` in place of the agent's own. -/
def keepWatch (watch : Watch) : EditorM Unit := do
  let held := ((← editorState).workspaces.getUnscoped watchStore).filter (·.id != watch.id)
  Workspace.setUnscoped watchStore (held.push watch)

/-- Notes that the session of the agent `id` was heard from at `time`, on
the job clock. -/
def heard (id time : Nat) : EditorM Unit := do
  keepWatch { ← watchOf id with heardAt := some time }

/-- Arms the stall watchdog of `record` once it works and has not stalled,
unless one is armed; cancels an armed one once it does not (the module
docs). A watchdog armed at `deadline?` waits until then; with none, until
`stallTimeout` after it starts. -/
def arm (record : AgentRecord) (deadline? : Option Nat := none) : EditorM Unit := do
  let watch ← watchOf record.id
  if record.attention == .working && !record.stalled then
    unless watch.armed do
      let deadline :=
        match deadline? with
        | some deadline => [.bool true, .nat deadline]
        | none => [.bool false]
      if
          (←
              startJob stallJob (.nat record.id :: deadline) (key :=
                  some (stallKey record.id))).isOk then
        keepWatch { watch with armed := true }
  else
    if watch.armed then
      cancelJob (stallKey record.id)
      keepWatch { watch with armed := false }

/-- Applies `changes`, in order, to the record of the agent `id`, writes its
project's table back, writes every agents list again and arms the
watchdog; nothing for an id no table holds. A prompt forgets when the
session was last heard from, so its watchdog counts from the prompt. -/
def change (id : Nat) (changes : Array AgentsApi.Change) : EditorM Unit := do
  let some (project, _) ← locate? id | return
  if changes.contains .prompted then
    keepWatch { ← watchOf id with heardAt := none }
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

/-- The command the stall watchdog of the agent `id` hands the loop once
the job clock reached `deadline`: when its session was heard from since
`stallTimeout` before the deadline, the watchdog is armed again for that
time's timeout; otherwise the reducer is told it stalled, at its current
generation (the module docs). -/
def stalledCommand (id deadline : Nat) : EditorM Unit := do
  let watch ← watchOf id
  keepWatch { watch with armed := false }
  let some (_, record) ← locate? id | return
  match watch.heardAt with
  | some time =>
    if time + stallTimeout > deadline then
      arm record (some (time + stallTimeout))
    else
      change id #[.stalled record.heard]
  | none =>
    change id #[.stalled record.heard]

/-- The stall watchdog (the module docs): waits on the job clock until its
deadline, or `stallTimeout` from its start with none, then hands the loop
its verdict. -/
def stallWork (arguments : List Argument) : Work := fun _ => do
  let deadline ←
    match arguments with
    | [.nat _, .bool true, .nat deadline] =>
      pure deadline
    | [.nat _, .bool false] =>
      pure ((← now) + stallTimeout)
    | _ =>
      throw s!"{stallJob}: its arguments are not an agent and a deadline"
  let .nat id :: _ := arguments | throw s!"{stallJob}: its arguments name no agent"
  waitUntil deadline
  return stalledCommand id deadline

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
