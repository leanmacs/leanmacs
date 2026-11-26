import AgentsApi.Policy
import AgentsApi.Request
import Editor.Extension

/-!
# How a conversation is shown: the extension point `ConversationView`

A conversation with an agent is shown as text in a buffer, and how each of
its items reads is a value registered at the extension point
`AgentsApi.ConversationView` (`Extension.add`): a structure of pure
functions, one for each kind of item, each returning the item's lines.

It is a **choice** by name (`docs/design/extension-points.md`, "A hook, or
a choice"): the reader takes the latest value registered under
`defaultName` (`ConversationView.named`, `ConversationView.choose`), so
config's, registered after a package's, replaces it. An implementation of
agents registers one under that name (`acp`'s `Acp.Conversation.defaultView`),
and config may register its own, built from that one with a field changed.

A reader splits any line feed a field's line holds, so a view cannot break
the reader's map of rows.

Besides the conversation's own items, it shows a permission request as the
queue of a project's pending requests lists it (`queued`), so config
restyles a queued request as it restyles a conversation's item.
-/

namespace AgentsApi

/-- Where a permission request stands, as the conversation holds it. -/
inductive PermissionState where
  /-- It is parked, waiting for an answer. -/
  | pending
  /-- A cancel of its turn answered it `cancelled` (`Event.withdrawn`). -/
  | withdrawn
  /-- The client's answer, this option's id, was taken. -/
  | answered (optionId : String)
  /-- Its session ended with it pending, so the protocol's close answered
  it: the agent ended, the session was stopped or its buffer closed. -/
  | closed
  deriving DecidableEq, Repr, Inhabited

/-- How much of the context window a session uses, of how much, and what it
has cost, when the agent says: the amount as decimal text, and the
currency (`Event.usage`). -/
structure Usage where
  /-- The tokens used. -/
  used : Nat
  /-- The window's size. -/
  size : Nat
  /-- What it has cost so far. -/
  cost : Option (String × String) := none
  deriving DecidableEq, Repr, Inhabited

/-- What the header of a conversation shows. -/
structure Header where
  /-- The agent's name. -/
  agent : String
  /-- The root of the workspace the session runs in. -/
  root : String
  /-- The session's title, once the agent sets one. -/
  title : Option String := none
  /-- The mode the session reports, once it reports one. -/
  mode : Option String := none
  /-- The modes the agent offers. -/
  modes : Array Mode := #[]
  /-- The usage the session reports, once it reports any. -/
  usage : Option Usage := none
  deriving DecidableEq, Repr, Inhabited

/-- How each item of a conversation is shown: the extension point, a choice
by `name`. Each field gives an item's lines. -/
structure ConversationView where
  /-- Its name, which a choice finds it by. -/
  name : String
  /-- The conversation's header. -/
  header : Header → Array String
  /-- A prompt the user sent. -/
  prompt : (text : String) → Array String
  /-- A message of the agent's, its chunks joined. -/
  message : (text : String) → Array String
  /-- A tool call, as it stands, folded or not. -/
  toolCall : (call : ToolCall) → (folded : Bool) → Array String
  /-- A permission request and where it stands. -/
  permission :
    (ticket : Nat) →
      (call : ToolCall) →
      (options : Array PermissionOption) → (state : PermissionState) → Array String
  /-- The end of a turn, for its stop reason. -/
  turnEnded : (turn : Nat) → (stopReason : String) → Array String
  /-- A note of the client's: a refusal, the session's end. -/
  note : (text : String) → Array String
  /-- A pending permission request of the conversation `conversation`, as
  the queue of a project's pending requests lists it: the tool call's
  title, its input, its diff and its options. -/
  queued : (conversation : Nat) → (request : PermissionRequest) → Array String
  deriving TypeName

namespace ConversationView

/-- The name a reader chooses the view by. -/
def defaultName : String :=
  "default"

/-- The latest of `views` named `name`, as a choice reads the point: so
config's, registered after a package's, replaces it. -/
def choose (views : Array ConversationView) (name : String := defaultName) :
    Option ConversationView :=
  views.findRev? (·.name == name)

/-- The view registered under `name`, the latest of that name. -/
def named (name : String := defaultName) : Editor.EditorM (Option ConversationView) :=
  Editor.Extension.named ConversationView (·.name) name

end ConversationView

end AgentsApi
