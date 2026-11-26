import Acp.Conversation.Render
import Acp.Permissions.Policy

/-!
# The queue of a project's pending permission requests

A project's pending permission requests, across its sessions, are one queue
(`docs/design/agent-hosting.md`, "Permissions, as built"), derived from the
conversations on every redraw, so the one place a pending request is kept
stays the conversation's store, which a reload leaves (`entries`):

- every pending request of every conversation that has not ended and whose
  workspace is in the project;
- by conversation number, then by the request's place in its conversation:
  oldest session first, then oldest request. Two sessions' tickets are
  numbered apart, so an entry is named by its conversation and its ticket,
  never by the ticket alone.

Its text (`render`) is `permissions of <project>`, then `<k> pending` or
`nothing pending`, an empty row, then each entry's lines as the chosen
view lists it (`ConversationView.queued`), each split at its line feeds.
With the lines comes the map of rows: for each row, the conversation and
the ticket of the request it shows, which `agent-queue-answer` reads to find
the request on the cursor's row (`rowOf` gives an entry's first row).
-/

namespace Acp.Permissions

open AgentsApi

/-- One request of the queue: its conversation's number and the request. -/
structure Entry where
  /-- The number of the conversation that asks. -/
  conversation : Nat
  /-- The request. -/
  request : PermissionRequest
  deriving DecidableEq, Repr

/-- The pending permission requests of `conversation`, in its order. -/
def pendingRequests (conversation : Conversation) : Array PermissionRequest :=
  conversation.items.filterMap fun item =>
    match item with
    | .permission ticket turn call options .pending =>
      some (requestOf conversation ticket turn call options)
    | _ => none

/-- The queue's entries (the module docs): every pending request of each of
`conversations` that has not ended and whose workspace `inProject` holds,
by conversation and then by place. -/
def entries (conversations : Array Conversation) (inProject : Editor.Location → Bool) :
    Array Entry :=
  (conversations.qsort (·.number < ·.number)).flatMap fun conversation =>
    if conversation.ended.isNone && inProject conversation.location then
      (pendingRequests conversation).map fun request =>
        { conversation := conversation.number, request }
    else #[]

/-- The queue's header: its project, how many are pending, and an empty
row. -/
def header (project : String) (count : Nat) : Array String :=
  #[s!"permissions of {project}", if count == 0 then "nothing pending" else s!"{count} pending", ""]

/-- The text of the queue of `project` as `view` lists `entries`, a line a
row, and for each row the conversation and ticket of the request it shows,
if any (the module docs). -/
def render (view : ConversationView) (project : String) (entries : Array Entry) :
    Array String × Array (Option (Nat × Nat)) :=
  Id.run do
    let top := header project entries.size
    let mut lines := top
    let mut map : Array (Option (Nat × Nat)) := top.map fun _ => none
    for entry in entries do
      let shown := Acp.Conversation.rows (view.queued entry.conversation entry.request)
      lines := lines ++ shown
      map := map ++ shown.map fun _ => some (entry.conversation, entry.request.ticket)
    return (lines, map)

/-- The text of the queue: each row ended with a line feed. -/
def text (view : ConversationView) (project : String) (entries : Array Entry) : String :=
  String.join ((render view project entries).1.toList.map (· ++ "\n"))

/-- The first row that shows the request `ticket` of the conversation
`conversation`, if one does. -/
def rowOf (view : ConversationView) (project : String) (entries : Array Entry)
    (conversation ticket : Nat) : Option Nat :=
  (render view project entries).2.findIdx? (· == some (conversation, ticket))

end Acp.Permissions
