import AgentsApi.Event
import Editor.Store
import Editor.Workspace

/-!
# The agent table: one record a session, and a pure reducer over its events

A project's sessions with agents, kept as data (`docs/design/agent-hosting.md`,
"The agent table"): one `AgentRecord` a session, whichever front end runs
it, in the project's store (`Table.store`, the cell `agents-table`). The
table holds a session's identity, its workspace, and its state on two axes;
never its transcript, which stays in the agent's own store.

- **Identity is three fields**: the id the editor mints (`id`, never
  reused: `Table.mint`), the provider's session id (`sessionId`), and a
  display name derived from the session's title (`AgentRecord.name`).
- **Attention** (`AgentRecord.attention`) is `waiting` while a permission
  request is pending, else `working` while a prompt is on its way or a turn
  is in flight, else `finished` (and unread) when a turn or the session
  ended since the last visit, else `idle`. It reads only those four fields.
- **Activity** (`AgentRecord.activity`) is the work in flight, the tool
  calls neither completed nor failed, or `unknown` once a working agent was
  silent past the stall timeout. Activity never feeds attention: an agent
  idle in the conversation may still have work in flight.

The reducer is pure: `AgentRecord.apply` takes a record and a `Change`, and
`Table.apply` applies a `TableEvent`, which names its agent by id, to that
agent's record alone. A `Change` is a session's typed event (`.event`) or a
step of the client's own: a prompt handed over, its reply, an answer taken,
the session opened or resumed, a visit, the stall watchdog's verdict, or a
stop.

- **The stall watchdog** carries the generation it was armed for
  (`heard`, the count of events heard), so a verdict armed before a later
  event, or one that comes while the agent is not working, changes
  nothing.
- **A loaded history** is replayed with `replaying` set, from `.resumed`
  until the next prompt: it adds no work, since nothing of a dead
  process is in flight.
- **Across a restart** (`AgentRecord.afterRestart`, the codec's `keep`):
  what died with the agent's process is cleared, a session cut off while
  waiting or working is marked unread, and one with no ending says the
  editor restarted.

`acp` (packages/acp/) feeds the table, keeps it in the project's store,
registers its codec, lists it and resumes a session on its first visit.
-/

namespace AgentsApi

open Editor (Value Location Store)

/-- Where a session stands for the user: what it wants of them, in the
order a list shows it. -/
inductive Attention where
  /-- A permission request is pending. -/
  | waiting
  /-- A turn or the session ended since the last visit: finished and
  unread. -/
  | finished
  /-- A prompt is on its way or a turn is in flight. -/
  | working
  /-- None of those. -/
  | idle
  deriving DecidableEq, Repr, Inhabited

/-- An attention's place in a list's order: waiting first, then finished and
unread, working and idle. -/
def Attention.rank : Attention → Nat
  | .waiting => 0
  | .finished => 1
  | .working => 2
  | .idle => 3

/-- A piece of work in flight: a tool call neither completed nor failed. -/
structure WorkItem where
  /-- The agent's id for the call. -/
  id : String
  /-- What it does, as the agent words it. -/
  title : String
  /-- Its kind, as the protocol names it. -/
  kind : String
  deriving DecidableEq, Repr, Inhabited

/-- The work item a tool call is. -/
def WorkItem.of (call : ToolCall) : WorkItem :=
  { id := call.id, title := call.title, kind := call.kind }

/-- What a session has in flight: its work items, or unknown once a working
agent was silent past the stall timeout. -/
inductive Activity where
  /-- These items are in flight; none when the array is empty. -/
  | items (work : Array WorkItem)
  /-- Nothing has been heard for longer than the stall timeout. -/
  | unknown
  deriving DecidableEq, Repr, Inhabited

/-- One session of the table (the module docs). -/
structure AgentRecord where
  /-- The id the editor minted for it; it never changes. -/
  id : Nat
  /-- The registered agent's name. -/
  agent : String
  /-- The front end that runs it. -/
  source : String := "acp"
  /-- The workspace it runs in; set once. -/
  location : Location
  /-- The provider's id for the session, once opened. -/
  sessionId : Option String := none
  /-- The session's title, as the agent set it: the display name's source. -/
  title : Option String := none
  /-- The tickets of permission requests awaiting an answer. -/
  pending : Array Nat := #[]
  /-- Whether a prompt is on its way and its reply has not come. -/
  awaiting : Bool := false
  /-- The turn in flight. -/
  turn : Option Nat := none
  /-- The latest turn that ended. -/
  lastEnded : Nat := 0
  /-- Whether a turn or the session ended since the last visit. -/
  unread : Bool := false
  /-- The tool calls in flight, oldest first. -/
  work : Array WorkItem := #[]
  /-- Whether it was silent past the stall timeout while working. -/
  stalled : Bool := false
  /-- How many of its events were heard: the stall watchdog's generation. -/
  heard : Nat := 0
  /-- Whether a loaded history is being replayed. -/
  replaying : Bool := false
  /-- Why its session ended, while none runs. -/
  ended : Option String := none
  deriving DecidableEq, Repr

/-- What happens to a session: one of its events, or a step of the
client's. -/
inductive Change where
  /-- A prompt was handed to the service. -/
  | prompted
  /-- The service answered the prompt: the turn it began, or none when it
  was refused. -/
  | sent (turn : Option Nat)
  /-- The session produced `event`. -/
  | event (event : Event)
  /-- The service took the answer to `ticket`. -/
  | answered (ticket : Nat)
  /-- The session opened, the provider's id `sessionId`. -/
  | opened (sessionId : String)
  /-- The session was loaded from the agent's store, its history to be
  replayed. -/
  | resumed (sessionId : String)
  /-- A visit began to resume it: its ending is forgotten, and the visit
  sees it. -/
  | resuming
  /-- The user visited it. -/
  | seen
  /-- The stall watchdog armed at the generation `heard` ran out. -/
  | stalled (heard : Nat)
  /-- The client stopped it, or it could not go on, for `reason`. -/
  | stopped (reason : String)
  deriving DecidableEq, Repr

/-- A change to the session whose record has the id `agent`. -/
structure TableEvent where
  /-- The id of the agent it is of. -/
  agent : Nat
  /-- The change. -/
  change : Change
  deriving DecidableEq, Repr

namespace AgentRecord

/-- The longest display name, in characters. -/
def nameLimit : Nat :=
  60

/-- Its display name: its title's first line, trimmed and cut at
`nameLimit` characters, or `<agent> <id>` with no title. -/
def name (record : AgentRecord) : String :=
  let fallback := s!"{record.agent} {record.id}"
  match record.title with
  | none => fallback
  | some title =>
    let line := ((title.splitOn "\n").headD "").trimAscii.toString
    if line.isEmpty then fallback else String.ofList (line.toList.take nameLimit)

/-- Its attention (the module docs): it reads only `pending`, `awaiting`,
`turn` and `unread`. -/
def attention (record : AgentRecord) : Attention :=
  if !record.pending.isEmpty then .waiting
  else
    if record.awaiting || record.turn.isSome then .working
    else if record.unread then .finished else .idle

/-- Its activity (the module docs). -/
def activity (record : AgentRecord) : Activity :=
  if record.stalled then .unknown else .items record.work

/-- Its work with `call` taken in: replaced or added while in flight, and
removed once completed or failed. -/
def track (work : Array WorkItem) (call : ToolCall) : Array WorkItem :=
  if call.status == "completed" || call.status == "failed" then work.filter (·.id != call.id)
  else
    if work.any (·.id == call.id) then
      work.map fun item => if item.id == call.id then WorkItem.of call else item
    else work.push (WorkItem.of call)

/-- `record` with nothing of a running process left: no request pending, no
prompt or turn, no work, no stall and no replay. -/
def quiet (record : AgentRecord) : AgentRecord :=
  { record with
    pending := #[], awaiting := false, turn := none, work := #[], stalled := false
    replaying := false }

/-- `record` after its session's event `event`. -/
def heardEvent (record : AgentRecord) (event : Event) : AgentRecord :=
  let record :=
    { record with
      heard := record.heard + 1, stalled := false }
  match event with
  | .permission ticket .. =>
    { record with
      pending :=
        if record.pending.contains ticket then record.pending else record.pending.push ticket }
  | .withdrawn ticket => { record with pending := record.pending.filter (· != ticket) }
  | .toolCall call =>
    if record.replaying then record else { record with work := track record.work call }
  | .title text => { record with title := some text }
  | .turnEnded turn _ =>
    { record with
      turn := if record.turn == some turn then none else record.turn
      lastEnded := max record.lastEnded turn, unread := true }
  | .ended how =>
    { record.quiet with
      ended := some how.describe, unread := true }
  | .chunk .. | .userChunk .. | .usage .. | .mode _ => record

/-- `record` after `change` (the module docs). -/
def apply (record : AgentRecord) : Change → AgentRecord
  | .event event => record.heardEvent event
  | .prompted =>
    { record with
      awaiting := true, unread := false, replaying := false }
  | .sent (some turn) =>
    { record with
      awaiting := false, turn := if record.lastEnded ≥ turn then record.turn else some turn }
  | .sent none => { record with awaiting := false }
  | .answered ticket => { record with pending := record.pending.filter (· != ticket) }
  | .opened sessionId =>
    { record with
      sessionId := some sessionId, ended := none }
  | .resumed sessionId =>
    { record.quiet with
      sessionId := some sessionId, ended := none, replaying := true }
  | .resuming =>
    { record with
      ended := none, unread := false }
  | .seen => { record with unread := false }
  | .stalled heard =>
    if heard == record.heard && record.attention == .working then { record with stalled := true }
    else record
  | .stopped reason => { record.quiet with ended := record.ended.orElse fun _ => some reason }

/-- The words of the ending a record kept across a restart has when it had
none. -/
def restartedWords : String :=
  "the editor restarted"

/-- `record` as it is kept across a restart (the module docs): unread when
it was waiting or working, with nothing of its process left, and an
ending. -/
def afterRestart (record : AgentRecord) : AgentRecord :=
  let cut := record.attention == .waiting || record.attention == .working
  { record.quiet with
    unread := record.unread || cut, heard := 0
    ended := record.ended.orElse fun _ => some restartedWords }

/-! ## As a tree -/

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

/-- A natural number's tree. -/
def nat? : Value → Option Nat
  | .nat value => some value
  | _ => none

/-- A string's tree. -/
def str? : Value → Option String
  | .str value => some value
  | _ => none

/-- A boolean's tree. -/
def bool? : Value → Option Bool
  | .bool value => some value
  | _ => none

/-- A work item as a tree: a list of its id, title and kind. -/
def encodeWork (item : WorkItem) : Value :=
  .list [.str item.id, .str item.title, .str item.kind]

/-- The work item a tree is (`encodeWork`). -/
def decodeWork? : Value → Option WorkItem
  | .list [.str id, .str title, .str kind] => some { id, title, kind }
  | _ => none

/-- A record as a tree. -/
def encode (record : AgentRecord) : Value :=
  .record
    [("id", .nat record.id), ("agent", .str record.agent), ("source", .str record.source),
      ("location", record.location.encode), ("sessionId", optional .str record.sessionId),
      ("title", optional .str record.title), ("pending", .list (record.pending.toList.map .nat)),
      ("awaiting", .bool record.awaiting), ("turn", optional .nat record.turn),
      ("lastEnded", .nat record.lastEnded), ("unread", .bool record.unread),
      ("work", .list (record.work.toList.map encodeWork)), ("stalled", .bool record.stalled),
      ("heard", .nat record.heard), ("replaying", .bool record.replaying),
      ("ended", optional .str record.ended)]

/-- The record a tree is (`encode`), if it is one. -/
def decode : Value → Option AgentRecord
  | .record fields => do
    let id ← nat? (field fields "id")
    let agent ← str? (field fields "agent")
    let source ← str? (field fields "source")
    let location ← Location.decode? (field fields "location")
    let sessionId ← optional? str? (field fields "sessionId")
    let title ← optional? str? (field fields "title")
    let .list pending := field fields "pending" | none
    let pending ← pending.toArray.mapM nat?
    let awaiting ← bool? (field fields "awaiting")
    let turn ← optional? nat? (field fields "turn")
    let lastEnded ← nat? (field fields "lastEnded")
    let unread ← bool? (field fields "unread")
    let .list work := field fields "work" | none
    let work ← work.toArray.mapM decodeWork?
    let stalled ← bool? (field fields "stalled")
    let heard ← nat? (field fields "heard")
    let replaying ← bool? (field fields "replaying")
    let ended ← optional? str? (field fields "ended")
    return {
        id, agent, source, location, sessionId, title, pending, awaiting, turn, lastEnded, unread,
        work, stalled, heard, replaying, ended }
  | _ => none

end AgentRecord

namespace Table

/-- `records` after `event`: the change applied to the record of its agent,
and every other record left; none changes for an id no record has. -/
def apply (records : Array AgentRecord) (event : TableEvent) : Array AgentRecord :=
  records.map fun record => if record.id == event.agent then record.apply event.change else record

/-- `records` with `record` added last, in place of one of its id. -/
def add (records : Array AgentRecord) (record : AgentRecord) : Array AgentRecord :=
  if records.any (·.id == record.id) then
    records.map fun held => if held.id == record.id then record else held
  else records.push record

/-- `records` in a list's order: by attention (`Attention.rank`), then by
id. -/
def ordered (records : Array AgentRecord) : Array AgentRecord :=
  records.qsort fun a b =>
    a.attention.rank < b.attention.rank || a.attention.rank == b.attention.rank && a.id < b.id

/-- The id to mint next: one more than the largest of `ids`, so no id held
anywhere is reused. -/
def mint (ids : Array Nat) : Nat :=
  ids.foldl max 0 + 1

/-- What a table keeps across a restart: each record as
`AgentRecord.afterRestart` keeps it. -/
def keep (records : Array AgentRecord) : Array AgentRecord :=
  records.map AgentRecord.afterRestart

/-- A project's agent table, in its project's store: the cell
`agents-table`. An implementation that keeps it across a restart registers
its codec with `keep` (`Table.store.keptAcrossRestart (keep := Table.keep)`). -/
def store : Store (Array AgentRecord) :=
  { name := "agents-table", version := 1, initial := #[]
    encode := fun records => .list (records.toList.map AgentRecord.encode)
    decode := fun
      | .list items => items.toArray.mapM AgentRecord.decode
      | _ => none }

end Table

end AgentsApi
