import Acp.ClaudeCode
import Acp.Conversation.Render
import Acp.Conversation.State
import Acp.Conversation.Store
import Acp.Conversation.View
import Acp.Generated
import AgentsApi
import BuffersApi
import Editor.Api
import Editor.Command.Call
import Editor.Mode

/-!
# Sessions and the conversation buffer

A session with an agent in one of the current project's workspaces, and
the conversation buffer that shows it (`docs/design/agent-hosting.md`,
"Sessions and the conversation, as built"). Written over the editor API
and `agents-api` alone: the service is reached through `AgentsApi.Job`, by
its name, so this module imports nothing of the crate's binding
(`Acp.Real`), and `acp`'s tests run it with no Rust.

## The commands

- **`agent-start [root]`** starts a session in one of the focused buffer's
  project's workspaces: the one whose root the text names, or the buffer's
  own with none. It refuses a buffer with no workspace, a workspace whose
  location cannot run commands, and an agent name nobody registered
  (`Acp.defaultAgent`, `claude-code`, unless config replaced it). Otherwise
  it makes the conversation and its buffer, shows it where the display
  rules say for the opener `agent-start`, and starts the job
  `agent-session` keyed `agent-session <n>`.
- **`agent-prompt [text]`**, in a conversation buffer: sends the text as a
  prompt, or asks `Prompt: ` for one. It refuses before the session is
  open, and while a prompt is on its way or a turn is in flight. The prompt
  is shown at once, and labelled with its turn by the service's reply.
- **`agent-answer <ticket> <option-id>`**: answers a pending permission
  request with one of the options it offered, and refuses anything else
  without sending; once the service took the answer the ticket is shown
  answered. A minimal path: phase 6's queue, policy and audit log are built
  over it.
- **`agent-cancel`**: cancels the turn in flight, or says there is none.
- **`agent-stop`**: cancels the session's job by its key, which ends its
  child, and notes `session stopped`.
- **`agent-toggle`**, the mode's `toggle`: folds or unfolds the tool call
  on the cursor's row.

No command, job or handler ever sends a mode or a configuration option:
the session keeps the mode the user's Claude settings give it, and the
buffer shows the mode the session reports.

## The jobs, and one post a batch

The session job (`agent-session`, registered over `AgentsApi.Agent` so its
work sees the registered agents) opens the session, posts `agent-opened`,
and loops on `next`: each batch, everything the service held when it was
taken, becomes **one** post of `agent-events`, so one turn of the loop and
one scene; after each post it waits `batchPause` on the job clock (`sleep`,
the fake clock on a stepped host), so a session posts at most about twenty
times a second, each post carrying everything since the last take. It
ends on the session's end or a refusal, noting how. Each order goes out
from a job of its own (`agent-send`), whose reply is applied by its
command.

## The buffer

Read-only, named `*agent: <agent> <label>*` or the first free name of it,
in the session's workspace, in the major mode `agent-conversation`. Its
text is the conversation rendered by the view chosen at
`AgentsApi.ConversationView` (`Acp/Conversation/Render.lean`), written
again inside `BufferId.writing` after each change: a view whose cursor is
on the last line, or the empty row after it, follows the end; every other
keeps its cursor's row. Closing it cancels the session's job and drops its
conversation (`BuffersApi.Closing`).

The conversations are kept in an unscoped store (`store`), so they survive
a reload of config.
-/

namespace Acp.Conversation

open Editor
open AgentsApi

/-- The name of the command that starts a session. -/
def startName : String :=
  "agent-start"

/-- The name of the command that sends a prompt. -/
def promptName : String :=
  "agent-prompt"

/-- The name of the command that answers a permission request. -/
def answerName : String :=
  "agent-answer"

/-- The name of the command that cancels the turn in flight. -/
def cancelName : String :=
  "agent-cancel"

/-- The name of the command that stops the session. -/
def stopName : String :=
  "agent-stop"

/-- The name of the command that folds or unfolds the tool call on the
cursor's row. -/
def toggleName : String :=
  "agent-toggle"

/-- The name of the command the session job posts its opened session to. -/
def openedName : String :=
  "agent-opened"

/-- The name of the command the session job posts each batch to. -/
def eventsName : String :=
  "agent-events"

/-- The name of the job that runs a session. -/
def sessionJob : String :=
  "agent-session"

/-- The name of the job that sends a session an order. -/
def sendJob : String :=
  "agent-send"

/-- The name of the conversation buffer's major mode. -/
def modeName : String :=
  "agent-conversation"

/-- The label of the prompt `agent-prompt` asks with. -/
def promptLabel : String :=
  "Prompt: "

/-- How long the session job waits after posting a batch before it takes the
next, in milliseconds: so it takes at most once a pause. -/
def batchPause : Nat :=
  50

/-- The most batches a session takes: more than any session lives for. -/
def takeLimit : Nat :=
  1000000000

/-- The key the session job of the conversation `number` runs under. -/
def sessionKey (number : Nat) : String :=
  s!"{sessionJob} {number}"

/-! ## The conversations and their buffers -/

/-- Writes the text of `conversation`'s buffer again (the module docs): a view
whose cursor is on the last line, or the empty row after it, follows the
end; every other keeps its cursor's row, clamped to the text. -/
def redraw (conversation : Conversation) : EditorM Unit := do
  let some index := conversation.buffer | return
  Generated.rewrite ⟨index⟩ (Acp.Conversation.text (← chosenView) conversation) (follow := true)

/-- Applies `change` to the conversation `number`, keeps it and writes its
buffer again; nothing for a conversation there is none of. -/
def update (number : Nat) (change : Conversation → Conversation) : EditorM Unit := do
  let some conversation ← conversation? number | return
  let changed := change conversation
  save changed
  redraw changed

/-! ## The jobs and the commands they hand the loop -/

/-- The arguments `agent-send` is started with: the conversation, the
session and the order. -/
def sendArguments (number session : Nat) (order : Order) : List Argument :=
  [.nat number, .nat session] ++ Request.orderArguments order

/-- The command a finished session job hands the loop: how the session
ended is kept and noted. -/
def endedCommand (number : Nat) (how : String) : EditorM Unit :=
  update number fun conversation =>
    { conversation with
          ended := conversation.ended.orElse fun _ => some how, turn := none }.noted
      s!"session ended: {how}"

/-- The ending of the session's end, if `batch` holds it. -/
def endingOf (batch : Batch) : Option Ending :=
  batch.events.findSome? fun event =>
    match event with
    | .ended how => some how
    | _ => none

/-- The session job (the module docs): opens the session of the agent named
in its arguments among `agents`, in its root, posts it, and posts each
batch, waiting `batchPause` on the job clock after each. -/
def sessionWork (agents : Array Agent) (arguments : List Argument) : Work := fun _ => do
  let [.nat number, .str name, .str root] := arguments
    | throw s!"{sessionJob}: its arguments are not a conversation, an agent and a root"
  let some agent := Agent.choose agents name
    | return endedCommand number s!"no agent named {name}"
  match ← AgentsApi.Job.open agent root with
  | .error refusal =>
    return endedCommand number s!"the session did not open: {refusal.describe}"
  | .ok opened =>
    post { command := openedName, arguments := .nat number :: opened.toArguments }
    for _ in [0:takeLimit] do
      match ← AgentsApi.Job.next opened.session with
      | .error refusal =>
        return endedCommand number refusal.describe
      | .ok batch =>
        post { command := eventsName, arguments := .nat number :: batch.toArguments }
        if let some how := endingOf batch then
          return endedCommand number (Conversation.describeEnding how)
        sleep batchPause
    return endedCommand number s!"no end after {takeLimit} batches"

/-- The command a finished `agent-send` hands the loop: the reply to `order`
applied to the conversation `number`. -/
def sentCommand (number : Nat) (order : Order) (reply : Except Refusal Sent) : EditorM Unit :=
  update number fun conversation =>
    match order, reply with
    | .prompt _, .ok sent =>
      match sent.turn with
      | some turn => conversation.sent turn
      | none => { conversation with awaiting := false }
    | .prompt _, .error refusal =>
      { conversation with awaiting := false }.noted s!"{promptName}: {refusal.describe}"
    | .answer ticket optionId, .ok _ => conversation.answered ticket optionId
    | .answer _ _, .error refusal => conversation.noted s!"{answerName}: {refusal.describe}"
    | .cancel, .error refusal => conversation.noted s!"{cancelName}: {refusal.describe}"
    | _, _ => conversation

/-- `agent-send`: hands its session its order and finishes with the reply. -/
def sendWork (arguments : List Argument) : Work := fun _ => do
  let .nat number :: .nat session :: rest := arguments
    | throw s!"{sendJob}: its arguments are not a conversation, a session and an order"
  let some order := Request.order? rest | throw s!"{sendJob}: its arguments hold no order"
  return sentCommand number order (← AgentsApi.Job.send session order)

/-- `agent-opened`: the conversation and its opened session. -/
def openedCommand (call : Call) : EditorM Unit := do
  let .nat number :: rest := call.arguments | return
  let some opened := Opened.ofArguments? rest | return
  update number (·.opened opened)

/-- `agent-events`: the conversation and a batch of its session's events. -/
def eventsCommand (call : Call) : EditorM Unit := do
  let .nat number :: rest := call.arguments | return
  let some batch := Batch.ofArguments? rest | return
  update number (·.applyBatch batch)

/-! ## The user's commands -/

/-- The workspace `agent-start` asked from `call` starts in: the one of the
buffer's project whose root the text names, or the buffer's own; or what it
says when there is none. -/
def startingWorkspace (call : Call) : EditorM (Except String Workspace) := do
  let state ← editorState
  let some (own, project) := state.workspaceOf? call.target.window.buffer
    | return .error s!"{startName}: {call.target.buffer.name} has no workspace"
  let named :=
    match call.arguments with
    | .str text :: _ => if text.trimAscii.isEmpty then none else some text.trimAscii.toString
    | _ => none
  let workspace? :=
    match named with
    | none => some own
    | some root =>
      let all : Array Workspace := state.workspaces.workspaces.map Prod.fst
      all.find? fun (workspace : Workspace) =>
        workspace.project.identity == project.identity &&
          (workspace.location.root?.map System.FilePath.toString) == some root
  match workspace?, named with
  | some workspace, _ =>
    if workspace.location.can.runCommands then
      return .ok workspace
    else
      return .error
          s!"{startName}: {workspace.label} is {workspace.location.describe}, where commands cannot run"
  | none, root =>
    return .error s!"{startName}: no workspace of {project.name} is at {root.getD ""}"

/-- `agent-start` (the module docs). -/
def startCommand (call : Call) : EditorM Unit := do
  let workspace ←
    match ← startingWorkspace call with
    | .ok workspace =>
      pure workspace
    | .error said =>
      message said
      return
  let some agent ← Agent.named defaultAgent | message s!"{startName}: no agent named {defaultAgent}"
  let state ← editorState
  let number := ((← conversations).foldl (fun most held => max most held.number) 0) + 1
  let started : Conversation := { number, agent := agent.name, location := workspace.location }
  let started := started.noted s!"starting {agent.name} in {started.root}"
  let .ok id ←
    createBuffer (state.freeName s!"*agent: {agent.name} {workspace.label}*")
        (Acp.Conversation.text (← chosenView)
          started) | message s!"{startName}: the conversation buffer could not be made"
  discard <| id.setReadOnly true
  Workspace.setBufferWorkspace id workspace.location
  discard <| id.setMajorMode modeName
  let started := { started with buffer := some id.index }
  save started
  match
    ←
      startJob sessionJob [.nat number, .str agent.name, .str started.root] (key :=
          some (sessionKey number)) with
  | .error refusal =>
    update number (·.noted s!"{startName}: {refusal.describe}")
  | .ok () =>
    pure ()
  discard <| id.display call.target.window.id startName

/-- The conversation of `call`'s buffer, or what `name` says when it is
none's. -/
def ofCall? (name : String) (call : Call) : EditorM (Option Conversation) := do
  match ← ofBuffer? call.target.window.buffer with
  | some conversation =>
    return some conversation
  | none =>
    message s!"{name}: {call.target.buffer.name} is not a conversation buffer"
    return none

/-- Starts `agent-send` with `order` for `conversation`'s session, or says
under `name` that it is not open. Whether it started. -/
def sendOrder (name : String) (conversation : Conversation) (order : Order) : EditorM Bool := do
  let some session := conversation.session |
    do
      message s!"{name}: the session is not open yet"
      return false
  match ← startJob sendJob (sendArguments conversation.number session order) with
  | .error refusal =>
    message s!"{name}: {refusal.describe}"
    return false
  | .ok () =>
    return true

/-- `agent-prompt` (the module docs): the text is its first argument; an
answer of its prompt comes back with `true` after it. -/
def promptCommand (call : Call) : EditorM Unit := do
  let some conversation ← ofCall? promptName call | return
  match call.arguments with
  | .str text :: rest =>
    if !text.trimAscii.isEmpty then
      send conversation text
    else
      if rest matches .bool true :: _ then
        message s!"{promptName}: no prompt"
      else
        ask
  | _ =>
    ask
where
  /-- Opens the prompt for a prompt's text, whose answer comes back to
  `agent-prompt`. -/
  ask : EditorM Unit :=
    discard <| prompt promptLabel { command := promptName, arguments := [.bool true] }
  /-- Sends `text` as the conversation's prompt, unless it may not be. -/
  send (conversation : Conversation) (text : String) : EditorM Unit := do
    if conversation.session.isNone then
      message s!"{promptName}: the session is not open yet"
    else
      if conversation.busy then
        message s!"{promptName}: a turn is in flight"
      else
        if ← sendOrder promptName conversation (.prompt text) then
          update conversation.number (·.prompted text)

/-- `agent-answer <ticket> <option-id>` (the module docs). -/
def answerCommand (call : Call) : EditorM Unit := do
  let some conversation ← ofCall? answerName call | return
  let words :=
    match call.arguments with
    | .str text :: _ => (text.splitOn " ").filter fun (word : String) => !word.isEmpty
    | _ => []
  let [ticketText, optionId] := words
    | message s!"{answerName}: give a ticket and an option's id"
  let some ticket := ticketText.toNat? | message s!"{answerName}: {ticketText} is no ticket"
  match conversation.permission? ticket with
  | some (_, options, .pending) =>
    if options.any (·.id == optionId) then
      discard <| sendOrder answerName conversation (.answer ticket optionId)
    else
      message s!"{answerName}: the request {ticket} offers no option {optionId}"
  | _ =>
    message s!"{answerName}: no permission request {ticket} is pending"

/-- `agent-cancel` (the module docs). -/
def cancelCommand (call : Call) : EditorM Unit := do
  let some conversation ← ofCall? cancelName call | return
  if conversation.turn.isSome then
    discard <| sendOrder cancelName conversation .cancel
  else
    message s!"{cancelName}: no turn in flight"

/-- `agent-stop` (the module docs). -/
def stopCommand (call : Call) : EditorM Unit := do
  let some conversation ← ofCall? stopName call | return
  cancelJob (sessionKey conversation.number)
  update conversation.number fun conversation =>
      { conversation with
            ended := conversation.ended.orElse fun _ => some "stopped", turn := none
            awaiting := false }.noted
        "session stopped"

/-- `agent-toggle` (the module docs). -/
def toggleCommand (call : Call) : EditorM Unit := do
  let some conversation ← ofCall? toggleName call | return
  let some row ← Generated.cursorRow call.target.window.id call.target.buffer.text | return
  match (render (← chosenView) conversation).2[row]? with
  | some (some id) =>
    update conversation.number (·.toggled id)
  | _ =>
    message s!"{toggleName}: no tool call on this line"

/-- What closing a conversation buffer does: its session's job is
cancelled, which ends its child, and its conversation dropped. -/
def closing (id : BufferId) : EditorM Unit := do
  let some conversation ← ofBuffer? id | return
  cancelJob (sessionKey conversation.number)
  Workspace.setUnscoped store ((← conversations).filter (·.number != conversation.number))

/-- The conversation buffer's major mode: `toggle` folds a tool call, and the
localleader's `p`, `c` and `k` prompt, cancel and stop. -/
def conversationMode : Editor.Mode :=
  { name := modeName, roles := [(Role.toggle, toggleName)]
    locals := [("p", promptName), ("c", cancelName), ("k", stopName)]
    roleDescs := [(Role.toggle, "fold or unfold the tool call")]
    localDescs := [("p", "prompt the agent"), ("c", "cancel the turn"), ("k", "stop the session")] }

end Acp.Conversation

namespace Acp

open Editor
open Acp.Conversation

/-- What the package `acp` registers (the module docs): Claude Code's adapter
at `AgentsApi.Agent`, the default view at `AgentsApi.ConversationView`, the
commands, the jobs, the mode, the closing hook and the ex names. -/
def setup : SetupM Unit := do
  Extension.add claudeCode
  Extension.add defaultView
  commandWith startName startCommand
  commandWith promptName promptCommand
  commandWith answerName answerCommand
  commandWith cancelName cancelCommand
  commandWith stopName stopCommand
  commandWith toggleName toggleCommand
  commandWith openedName openedCommand
  commandWith eventsName eventsCommand
  Extension.workJob AgentsApi.Agent sessionJob sessionWork
  workJob sendJob sendWork
  defineMode conversationMode
  Extension.add ({ name := "acp", closing } : BuffersApi.Closing)
  exCommand startName startName (takes := .text)
  exCommand promptName promptName (takes := .text)
  exCommand answerName answerName (takes := .text)
  exCommand cancelName cancelName
  exCommand stopName stopName

end Acp
