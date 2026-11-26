/-!
# What a session with an agent produces: its plain events

The events a session with a coding agent produces, as plain data in the
editor's own terms (`docs/design/agent-hosting.md`, "ACP"), whatever
protocol the implementation speaks: a chunk of the agent's reply or of the
user's message, a tool
call with its updates already merged, a permission request parked under a
ticket, its withdrawal on a cancel, the session's usage, title and mode,
the end of a prompt turn, and the session's own end.

A tool call is posted whole each time it changes (`Event.toolCall`): an
implementation merges each update into the call it holds, and an update's
content or locations replace the held ones, so a diff is replaced, never
appended. Its raw input is kept as the compact JSON text the agent sent,
shown as is.

What an implementation drops, as no event of this phase: the agent's list
of commands, its configuration options, every `_meta`, the agent's standard
error, and the agent's own non-standard notifications, which it never
formats or logs.
-/

namespace AgentsApi

/-- One item of a tool call's content. -/
inductive ToolContent where
  /-- Text the tool produced. -/
  | text (text : String)
  /-- An edit of the file at `path`: its text before, none for a new file,
  and after. -/
  | diff (path : String) (old : Option String) (new : String)
  deriving DecidableEq, Repr, Inhabited

/-- A tool call, with every update the agent sent of it merged in. -/
structure ToolCall where
  /-- The agent's id for the call. -/
  id : String
  /-- What the call does, as the agent words it. -/
  title : String := ""
  /-- Its kind, as the protocol names it (`read`, `edit`, `execute`, …). -/
  kind : String := "other"
  /-- Its status, as the protocol names it (`pending`, `in_progress`,
  `completed`, `failed`). -/
  status : String := "pending"
  /-- The places it touches: each a path and, when the agent gave one, a
  line. -/
  locations : Array (String × Option Nat) := #[]
  /-- What it produced: text and diffs. -/
  content : Array ToolContent := #[]
  /-- Its raw input, as compact JSON text; empty when the agent sent none. -/
  rawInput : String := ""
  deriving DecidableEq, Repr, Inhabited

/-- One way to answer a permission request, as the agent offers it. -/
structure PermissionOption where
  /-- The id an answer names. -/
  id : String
  /-- What it is called, for people. -/
  name : String
  /-- Its kind, as the protocol names it (`allow_once`, `allow_always`,
  `reject_once`, `reject_always`). -/
  kind : String
  deriving DecidableEq, Repr, Inhabited

/-- How a session ended by itself. -/
inductive Ending where
  /-- The agent exited with this status. -/
  | exited (code : Int)
  /-- The agent was ended by this signal. -/
  | signalled (signal : Int)
  /-- A line the agent wrote was longer than the session's bound
  (`AgentsApi.lineBound`), and its group was killed: skipping a line could
  drop a response and leave a request waiting forever. -/
  | lineTooLong
  /-- A read of the agent failed, with the platform's words. -/
  | failed (words : String)
  /-- The agent broke the protocol, as the implementation says. -/
  | protocolError (words : String)
  deriving DecidableEq, Repr, Inhabited

/-- How a session's ending is said, as a conversation notes it and the agent
table keeps it. -/
def Ending.describe : Ending → String
  | .exited code => s!"the agent exited {code}"
  | .signalled signal => s!"the agent was ended by signal {signal}"
  | .lineTooLong => "a line of the agent's was too long"
  | .failed words => s!"a read of the agent failed: {words}"
  | .protocolError words => s!"the agent broke the protocol: {words}"

/-- One thing a session produced. -/
inductive Event where
  /-- A chunk of the agent's reply, with the agent's id of the message it is
  part of, when it gave one. -/
  | chunk (messageId? : Option String) (text : String)
  /-- A chunk of a message of the user's, with the agent's id of the message
  it is part of, when it gave one: what a loaded session replays of its
  history (`Request.load`), and what an agent may echo of a prompt. -/
  | userChunk (messageId? : Option String) (text : String)
  /-- A tool call, whole, with every update so far merged in. -/
  | toolCall (call : ToolCall)
  /-- The agent asks permission for `call`, parked under `ticket` in the turn
  `turn` (none before the first prompt), to be answered with one of
  `options` (`Order.answer`). -/
  |
  permission (ticket : Nat) (turn : Option Nat) (call : ToolCall) (options : Array PermissionOption)
  /-- The permission request `ticket` was answered `cancelled` by the client,
  on a cancel of its turn: it can no longer be answered. -/
  | withdrawn (ticket : Nat)
  /-- How much of the context window is used, of how much, and what the
  session has cost so far, when the agent says: the amount as decimal text,
  and the currency. -/
  | usage (used size : Nat) (cost : Option (String × String))
  /-- The session's title, as the agent set it. -/
  | title (text : String)
  /-- The session's current mode, as the agent reports it. -/
  | mode (id : String)
  /-- The prompt turn `turn` ended, for the protocol's stop reason
  (`end_turn`, `cancelled`, …). -/
  | turnEnded (turn : Nat) (stopReason : String)
  /-- The session ended by itself: the last event it produces. -/
  | ended (how : Ending)
  deriving DecidableEq, Repr, Inhabited

end AgentsApi
