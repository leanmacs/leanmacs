import Acp.Conversation.State
import Editor.Value

/-!
# The audit log's outbox

What the writer of the audit log (`Acp/Permissions.lean`) decides, as pure
transitions: the records' lines not yet written, oldest first, and how many
of the first of them the write in flight holds, if one is. The writer keeps
the outbox in an unscoped store, hands each `Outbox.Write` it is given to one
job, `agent-audit`, and feeds the job's result back; it decides nothing
itself.

- **One write at a time.** `enqueue` adds lines and starts a write of every
  waiting line only when none is in flight; a line added while one is in
  flight waits for it.
- **A write that lands drops what it held.** `wrote count` drops the first
  `count` lines, the ones the write held, and starts a write of the lines
  that came in meanwhile, if any.
- **A refused write loses nothing.** `refused` keeps every line, the
  refused write's among them, and starts nothing: the next lines added
  start one write of them all, so a log that cannot be written is tried
  again once per record, never in a loop. Only the first refusal since a
  write landed is to be said (`said`), so a log that stays unwritable says
  so once.

So the writes reach the file service one at a time, in the order the lines
were added, and a line leaves the outbox only once a write of it has
landed. Lines kept after a refusal live as long as the store does: an
editor that quits before a write lands loses them, and the refusal it said
is the user's word of it. The outbox's tree (`encode`, `decode`) is what the store keeps.
-/

namespace Acp.Permissions

open Editor (Value)

/-- The audit log's outbox (the module docs). -/
structure Outbox where
  /-- The lines not yet written, oldest first. -/
  lines : Array String := #[]
  /-- How many of `lines` the write in flight holds; none when no write is
  in flight. -/
  writing : Option Nat := none
  /-- Whether a refusal was said since the last write that landed. -/
  said : Bool := false
  deriving DecidableEq, Repr, Inhabited

/-- A write the writer is to start: the text of the first `count` lines of
the outbox, each ended by a line feed. -/
structure Outbox.Write where
  /-- The lines' text. -/
  text : String
  /-- How many lines it holds. -/
  count : Nat
  deriving DecidableEq, Repr

namespace Outbox

/-- A write of every waiting line, and the outbox with it in flight; none
while a write is in flight or when nothing waits. -/
def start (outbox : Outbox) : Outbox × Option Write :=
  if outbox.writing.isSome || outbox.lines.isEmpty then (outbox, none)
  else
    ({ outbox with writing := some outbox.lines.size },
      some
        { text := String.join (outbox.lines.toList.map (· ++ "\n")), count := outbox.lines.size })

/-- `lines` added after the waiting ones, and a write of them all started
unless one is in flight (`start`). -/
def enqueue (outbox : Outbox) (lines : Array String) : Outbox × Option Write :=
  start { outbox with lines := outbox.lines ++ lines }

/-- The write in flight, of `count` lines, landed: the first `count` lines
dropped, no write in flight, no refusal said since, and a write of the
lines that came in meanwhile started (`start`). -/
def wrote (outbox : Outbox) (count : Nat) : Outbox × Option Write :=
  start { lines := outbox.lines.extract count outbox.lines.size }

/-- The write in flight was refused, or its job could not start: no write in
flight, every line kept for the write the next `enqueue` starts, and
whether to say it, only for the first refusal since a write landed. -/
def refused (outbox : Outbox) : Outbox × Bool :=
  ({ outbox with
      writing := none, said := true },
    !outbox.said)

/-- The outbox as a tree, as the store keeps it. -/
def encode (outbox : Outbox) : Value :=
  .record
    [("lines", .list (outbox.lines.toList.map .str)),
      ("writing", Acp.Conversation.optional .nat outbox.writing), ("said", .bool outbox.said)]

/-- The outbox a tree is (`encode`), if it is one. -/
def decode : Value → Option Outbox
  | .record fields => do
    let .list lines := Acp.Conversation.field fields "lines" | none
    let lines ← lines.toArray.mapM Acp.Conversation.str?
    let writing ←
      Acp.Conversation.optional? Acp.Conversation.nat? (Acp.Conversation.field fields "writing")
    let .bool said := Acp.Conversation.field fields "said" | none
    return { lines, writing, said }
  | _ => none

end Outbox

end Acp.Permissions
