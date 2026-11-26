import AgentsApi.Arguments
import AgentsApi.View
import Editor.Value
import Editor.Workspace

/-!
# A conversation with an agent: its state

What `acp`'s conversation keeps of one session (`Conversation`), and how
each thing that happens to it changes it, pure (`docs/design/agent-hosting.md`,
"Sessions and the conversation, as built"):

- **The session's events** (`Conversation.apply`, `applyBatch`): a chunk
  is appended to the message of its id, a tool call replaces the item of
  its id whole (an update's diff replaces the held one, never appends to
  it), a permission request is added pending, its withdrawal marks it
  withdrawn, the usage, title and mode are kept, the end of a turn is added
  and clears the turn in flight, and the session's end is kept.
- **The client's own steps**: a prompt is added when `agent-prompt` runs
  (`Conversation.prompted`), so a turn's events that come before the send's
  reply still follow it, and labelled with its turn by the reply
  (`Conversation.sent`); an answer that the service took marks its ticket
  answered (`Conversation.answered`); a note is added for a refusal or the
  session's end (`Conversation.noted`).
- **A ticket's state** changes in exactly two ways: `withdrawn`, from the
  service's `.withdrawn` event, and `answered`, once acp's own answer to it
  was taken. Both are final, and the end of a turn marks no ticket, so an
  answered ticket is never relabelled. `Conversation.pending` is the tickets
  still pending.

A conversation is kept in an unscoped store (`Acp.Conversation.store`,
`Acp/Conversation.lean`) as a tree (`Conversation.encode`, `decode`); its
items' fields are written with `agents-api`'s argument encoding
(`AgentsApi/Arguments.lean`), each argument a leaf of the tree.
-/

namespace Acp.Conversation

open AgentsApi
open Editor (Argument Value Location)

/-- One thing a conversation shows, in order. -/
inductive Item where
  /-- A prompt the user sent, with the turn it began once the service said. -/
  | prompt (text : String) (turn : Option Nat)
  /-- A message of the agent's, its chunks joined, with the agent's id for
  it when it gave one. -/
  | message (id : Option String) (text : String)
  /-- A tool call as it stands, every update merged in. -/
  | toolCall (call : ToolCall)
  /-- A permission request, its turn, the call it is for, its options and
  where it stands. -/
  |
  permission (ticket : Nat) (turn : Option Nat) (call : ToolCall) (options : Array PermissionOption)
    (state : PermissionState)
  /-- The end of a turn, for its stop reason. -/
  | turnEnded (turn : Nat) (stopReason : String)
  /-- A note of the client's: a refusal, the session's start or end. -/
  | note (text : String)
  deriving DecidableEq, Repr, Inhabited

end Acp.Conversation

namespace Acp

open AgentsApi
open Editor (Argument Value Location)
open Acp.Conversation (Item)

/-- One conversation with an agent (the module docs). -/
structure Conversation where
  /-- Its number, which its jobs, its key and its posts name. -/
  number : Nat
  /-- The name of the agent it runs. -/
  agent : String
  /-- The location of the workspace it runs in. -/
  location : Location
  /-- The number of its buffer, found by number and never by name. -/
  buffer : Option Nat := none
  /-- The service's number for its session, once opened. -/
  session : Option Nat := none
  /-- The agent's id for its session, once opened. -/
  sessionId : Option String := none
  /-- The mode the session reports. -/
  mode : Option String := none
  /-- The modes the agent offers. -/
  modes : Array Mode := #[]
  /-- The session's title, once the agent sets one. -/
  title : Option String := none
  /-- The usage the session last reported. -/
  usage : Option Usage := none
  /-- What it shows, in order. -/
  items : Array Item := #[]
  /-- The ids of the tool calls the user unfolded: every other is folded. -/
  unfolded : Array String := #[]
  /-- The turn in flight, once the service said which. -/
  turn : Option Nat := none
  /-- Whether a prompt was handed to the service and its reply has not
  come. -/
  awaiting : Bool := false
  /-- How its session ended, once it has. -/
  ended : Option String := none
  deriving DecidableEq, Repr

namespace Conversation

/-- The index of the last of `items` that `holds` of. -/
def lastIndex? (items : Array Item) (holds : Item → Bool) : Option Nat :=
  ((List.range items.size).reverse).find? fun index => items[index]?.any holds

/-- The root of its workspace, as text. -/
def root (conversation : Conversation) : String :=
  ((conversation.location.root?).map (·.toString)).getD conversation.location.describe

/-- Its header, as a view shows it. -/
def header (conversation : Conversation) : Header :=
  { agent := conversation.agent, root := conversation.root, title := conversation.title
    mode := conversation.mode, modes := conversation.modes, usage := conversation.usage }

/-- `conversation` with `item` added last. -/
def push (conversation : Conversation) (item : Item) : Conversation :=
  { conversation with items := conversation.items.push item }

/-- `conversation` with the note `text` added. -/
def noted (conversation : Conversation) (text : String) : Conversation :=
  conversation.push (.note text)

/-- The index of the last message of `id`, when the chunk of `id` continues
it: for an id, the last message of that id; for none, the last item when it
is a message with none. -/
def messageOf? (conversation : Conversation) : Option String → Option Nat
  | some id =>
    lastIndex? conversation.items fun item =>
      match item with
      | .message (some held) _ => held == id
      | _ => false
  | none =>
    match conversation.items.back? with
    | some (.message none _) => some (conversation.items.size - 1)
    | _ => none

/-- `conversation` with the ticket `ticket` moved to `state`, when it is
pending: both other states are final. -/
def settle (conversation : Conversation) (ticket : Nat) (state : PermissionState) : Conversation :=
  { conversation with
    items :=
      conversation.items.map fun item =>
        match item with
        | .permission held turn call options .pending =>
          if held == ticket then .permission held turn call options state else item
        | _ => item }

/-- How a session's ending is said. -/
def describeEnding : Ending → String
  | .exited code => s!"the agent exited {code}"
  | .signalled signal => s!"the agent was ended by signal {signal}"
  | .lineTooLong => "a line of the agent's was too long"
  | .failed words => s!"a read of the agent failed: {words}"
  | .protocolError words => s!"the agent broke the protocol: {words}"

/-- `conversation` after the session's event `event` (the module docs). -/
def apply (conversation : Conversation) : Event → Conversation
  | .chunk id text =>
    match conversation.messageOf? id with
    | some index =>
      { conversation with
        items :=
          conversation.items.modify index fun item =>
            match item with
            | .message held before => .message held (before ++ text)
            | _ => item }
    | none => conversation.push (.message id text)
  | .toolCall call =>
    match
      conversation.items.findIdx? fun item =>
        match item with
        | .toolCall held => held.id == call.id
        | _ => false with
    | some index => { conversation with items := conversation.items.set! index (.toolCall call) }
    | none => conversation.push (.toolCall call)
  | .permission ticket turn call options =>
    conversation.push (.permission ticket turn call options .pending)
  | .withdrawn ticket => conversation.settle ticket .withdrawn
  | .usage used size cost => { conversation with usage := some { used, size, cost } }
  | .title text => { conversation with title := some text }
  | .mode id => { conversation with mode := some id }
  | .turnEnded turn stopReason =>
    let conversation := conversation.push (.turnEnded turn stopReason)
    if conversation.turn == some turn then { conversation with turn := none } else conversation
  | .ended how =>
    { conversation with
      ended := some (describeEnding how), turn := none }

/-- `conversation` after each event of `batch`, in order. -/
def applyBatch (conversation : Conversation) (batch : Batch) : Conversation :=
  batch.events.foldl apply conversation

/-- `conversation` once its session is open, as `opened` says. -/
def opened (conversation : Conversation) (opened : Opened) : Conversation :=
  { conversation with
    session := some opened.session, sessionId := some opened.sessionId, mode := opened.mode
    modes := opened.modes }

/-- `conversation` with the prompt `text` handed to the service. -/
def prompted (conversation : Conversation) (text : String) : Conversation :=
  { (conversation.push (.prompt text none)) with awaiting := true }

/-- Whether the turn `turn` has ended in `conversation`. -/
def turnOver (conversation : Conversation) (turn : Nat) : Bool :=
  conversation.items.any fun item =>
    match item with
    | .turnEnded held _ => held == turn
    | _ => false

/-- `conversation` once the service said the prompt handed to it began
`turn`: the last prompt with no turn is labelled, and the turn is in flight
unless its end came first. -/
def sent (conversation : Conversation) (turn : Nat) : Conversation :=
  let items :=
    match
      lastIndex? conversation.items fun item =>
        match item with
        | .prompt _ none => true
        | _ => false with
    | some index =>
      conversation.items.modify index fun item =>
        match item with
        | .prompt text _ => .prompt text (some turn)
        | _ => item
    | none => conversation.items
  { conversation with
    items, awaiting := false
    turn := if conversation.turnOver turn then conversation.turn else some turn }

/-- `conversation` once the service took the answer `optionId` to `ticket`. -/
def answered (conversation : Conversation) (ticket : Nat) (optionId : String) : Conversation :=
  conversation.settle ticket (.answered optionId)

/-- The tickets still pending, oldest first. -/
def pending (conversation : Conversation) : Array Nat :=
  conversation.items.filterMap fun item =>
    match item with
    | .permission ticket _ _ _ .pending => some ticket
    | _ => none

/-- The permission request `ticket`, if the conversation holds it: its
call, its options and where it stands. -/
def permission? (conversation : Conversation) (ticket : Nat) :
    Option (ToolCall × Array PermissionOption × PermissionState) :=
  conversation.items.findSome? fun item =>
    match item with
    | .permission held _ call options state =>
      if held == ticket then some (call, options, state) else none
    | _ => none

/-- Whether a prompt may not be sent: one is on its way, or a turn is in
flight. -/
def busy (conversation : Conversation) : Bool :=
  conversation.awaiting || conversation.turn.isSome

/-- `conversation` with the tool call `id` folded if it was unfolded, and
unfolded otherwise. -/
def toggled (conversation : Conversation) (id : String) : Conversation :=
  { conversation with
    unfolded :=
      if conversation.unfolded.contains id then conversation.unfolded.filter (· != id)
      else conversation.unfolded.push id }

/-! ## As a tree -/

/-- An argument as a leaf of a tree. -/
def leaf : Argument → Value
  | .nat value => .nat value
  | .int value => .int value
  | .str value => .str value
  | .bool value => .bool value

/-- The argument a leaf is. -/
def ofLeaf? : Value → Option Argument
  | .nat value => some (.nat value)
  | .int value => some (.int value)
  | .str value => some (.str value)
  | .bool value => some (.bool value)
  | _ => none

/-- Arguments as a tree: a list of leaves. -/
def leaves (arguments : List Argument) : Value :=
  .list (arguments.map leaf)

/-- The arguments a tree of leaves is. -/
def ofLeaves? : Value → Option (List Argument)
  | .list items => items.mapM ofLeaf?
  | _ => none

/-- A permission's state as arguments. -/
def stateArguments : PermissionState → List Argument
  | .pending => [.str "pending"]
  | .withdrawn => [.str "withdrawn"]
  | .answered optionId => [.str "answered", .str optionId]

/-- An item as arguments: its kind's word, then its fields. -/
def itemArguments : Item → List Argument
  | .prompt text turn => [.str "prompt", .str text] ++ Arguments.optionalNat turn
  | .message id text => .str "message" :: Arguments.optionalString id ++ [.str text]
  | .toolCall call => .str "toolCall" :: call.toArguments
  | .permission ticket turn call options state =>
    [.str "permission", .nat ticket] ++ Arguments.optionalNat turn ++ call.toArguments ++
      [.nat options.size] ++
      options.toList.flatMap PermissionOption.toArguments ++
      stateArguments state
  | .turnEnded turn stopReason => [.str "turnEnded", .nat turn, .str stopReason]
  | .note text => [.str "note", .str text]

/-- The item `arguments` are, wholly. -/
def item? (arguments : List Argument) : Option Item :=
  Arguments.whole read arguments
where
  /-- An item off the front of the arguments, and the rest. -/
  read : List Argument → Option (Item × List Argument)
    | .str "prompt" :: .str text :: rest => do
      let (turn, rest) ← Arguments.optionalNat? rest
      return (.prompt text turn, rest)
    | .str "message" :: rest => do
      let (id, rest) ← Arguments.optionalString? rest
      let .str text :: rest := rest | none
      return (.message id text, rest)
    | .str "toolCall" :: rest => do
      let (call, rest) ← ToolCall.take? rest
      return (.toolCall call, rest)
    | .str "permission" :: .nat ticket :: rest => do
      let (turn, rest) ← Arguments.optionalNat? rest
      let (call, rest) ← ToolCall.take? rest
      let .nat count :: rest := rest | none
      let (options, rest) ← Arguments.many PermissionOption.take? count rest #[]
      match rest with
      | .str "pending" :: rest =>
        some (.permission ticket turn call options .pending, rest)
      | .str "withdrawn" :: rest =>
        some (.permission ticket turn call options .withdrawn, rest)
      | .str "answered" :: .str optionId :: rest =>
        some (.permission ticket turn call options (.answered optionId), rest)
      | _ =>
        none
    | .str "turnEnded" :: .nat turn :: .str stopReason :: rest =>
      some (.turnEnded turn stopReason, rest)
    | .str "note" :: .str text :: rest => some (.note text, rest)
    | _ => none

/-- An optional value as a tree: null, or the value's tree. -/
def optional {α : Type} (encode : α → Value) : Option α → Value
  | none => .null
  | some value => encode value

/-- The field `name` of `fields`, null when there is none. -/
def field (fields : List (String × Value)) (name : String) : Value :=
  ((fields.find? (·.1 == name)).map (·.2)).getD .null

/-- An optional value read from a tree with `decode`: null is none. -/
def optional? {α : Type} (decode : Value → Option α) : Value → Option (Option α)
  | .null => some none
  | tree => (decode tree).map some

/-- The usage as arguments. -/
def usageArguments (usage : Usage) : List Argument :=
  [.nat usage.used, .nat usage.size] ++
    match usage.cost with
    | none => [.bool false]
    | some (amount, currency) => [.bool true, .str amount, .str currency]

/-- The usage arguments are (`usageArguments`). -/
def usage? : List Argument → Option Usage
  | [.nat used, .nat size, .bool false] => some { used, size }
  | [.nat used, .nat size, .bool true, .str amount, .str currency] =>
    some { used, size, cost := some (amount, currency) }
  | _ => none

/-- A conversation as a tree. -/
def encode (conversation : Conversation) : Value :=
  .record
    [("number", .nat conversation.number), ("agent", .str conversation.agent),
      ("location", conversation.location.encode), ("buffer", optional .nat conversation.buffer),
      ("session", optional .nat conversation.session),
      ("sessionId", optional .str conversation.sessionId),
      ("mode", optional .str conversation.mode),
      ("modes", .list (conversation.modes.toList.map fun mode => leaves mode.toArguments)),
      ("title", optional .str conversation.title),
      ("usage", optional (fun usage => leaves (usageArguments usage)) conversation.usage),
      ("items", .list (conversation.items.toList.map fun item => leaves (itemArguments item))),
      ("unfolded", .list (conversation.unfolded.toList.map .str)),
      ("turn", optional .nat conversation.turn), ("awaiting", .bool conversation.awaiting),
      ("ended", optional .str conversation.ended)]

/-- A natural number's tree. -/
def nat? : Value → Option Nat
  | .nat value => some value
  | _ => none

/-- A string's tree. -/
def str? : Value → Option String
  | .str value => some value
  | _ => none

/-- The conversation a tree is (`encode`), if it is one. -/
def decode : Value → Option Conversation
  | .record fields => do
    let number ← nat? (field fields "number")
    let agent ← str? (field fields "agent")
    let location ← Location.decode? (field fields "location")
    let buffer ← optional? nat? (field fields "buffer")
    let session ← optional? nat? (field fields "session")
    let sessionId ← optional? str? (field fields "sessionId")
    let mode ← optional? str? (field fields "mode")
    let .list modes := field fields "modes" | none
    let modes ←
      modes.toArray.mapM fun tree => do
          Arguments.whole Mode.take? (← ofLeaves? tree)
    let title ← optional? str? (field fields "title")
    let usage ←
      optional?
          (fun tree => do
            usage? (← ofLeaves? tree))
          (field fields "usage")
    let .list items := field fields "items" | none
    let items ←
      items.toArray.mapM fun tree => do
          item? (← ofLeaves? tree)
    let .list unfolded := field fields "unfolded" | none
    let unfolded ← unfolded.toArray.mapM str?
    let turn ← optional? nat? (field fields "turn")
    let .bool awaiting := field fields "awaiting" | none
    let ended ← optional? str? (field fields "ended")
    return {
        number, agent, location, buffer, session, sessionId, mode, modes, title, usage, items,
        unfolded, turn, awaiting, ended }
  | _ => none

end Conversation

end Acp
