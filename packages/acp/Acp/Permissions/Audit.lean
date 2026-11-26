import Acp.Codec
import Acp.Permissions.Policy

/-!
# The audit log's records

Every permission request and its answer are appended to an audit log
(`docs/design/agent-hosting.md`, "Permissions, as built"), one record a
line, as the crate's lines are written (`Acp/Codec.lean`): a kind word,
then tab-separated `name=value` fields, each value escaped
(`Acp.Codec.escape`), so a line feed in an input or a diff never splits a
record and `Acp.Codec.split` reads a line back. In the order things happen:

- `asked`: a request arrived, with its project, root, agent, session id,
  conversation, ticket, turn (when it has one), title, kind and raw input,
  each content item (`text`, or `diff` with `old` and `new`), and each
  option (`option`, `optionKind`, `optionName`);
- `decided`: the policy's decision, right after its `asked`: the policy's
  name and `ask` or the chosen option's id;
- `answered`: the service took an answer, and who gave it (`by`, `user` or
  `policy`);
- `refused`: the service refused an answer, with its words;
- `withdrawn`: a cancel answered it `cancelled`;
- `closed`: its conversation ended with it pending, so the protocol's close
  answers it.

So every request has an answer record: `answered`, `withdrawn` or
`closed`. There is no time stamp: the job port has no wall clock, and the
order of the lines is the order of the events. This module is pure; the
writer is `Acp/Permissions.lean`'s.
-/

namespace Acp.Permissions

open AgentsApi

/-- Who gave an answer. -/
inductive Origin where
  /-- The user, from `agent-answer` or the queue. -/
  | user
  /-- The policy, as the request arrived. -/
  | policy
  deriving DecidableEq, Repr, Inhabited

/-- An origin's word, as a record and `agent-send`'s arguments carry it. -/
def Origin.word : Origin → String
  | .user => "user"
  | .policy => "policy"

/-- The origin a word names. -/
def Origin.ofWord? : String → Option Origin
  | "user" => some .user
  | "policy" => some .policy
  | _ => none

/-- One record of the audit log (the module docs). -/
inductive Record where
  /-- The request `request` of the conversation `conversation` arrived, in
  the project `project`. -/
  | asked (project : String) (conversation : Nat) (request : PermissionRequest)
  /-- The policy `policy` decided `decision`, an option's id, or none to ask. -/
  | decided (conversation ticket : Nat) (policy : String) (decision : Option String)
  /-- The service took the answer `optionId`, given by `origin`. -/
  | answered (conversation ticket : Nat) (optionId : String) (origin : Origin)
  /-- The service refused the answer `optionId`, given by `origin`, saying
  `reason`. -/
  | refused (conversation ticket : Nat) (optionId : String) (origin : Origin) (reason : String)
  /-- A cancel answered the request `cancelled`. -/
  | withdrawn (conversation ticket : Nat)
  /-- The conversation ended, for `reason`, with the request pending. -/
  | closed (conversation ticket : Nat) (reason : String)
  deriving DecidableEq, Repr

/-- A line of the kind `kind` and the fields `fields`, each value escaped. -/
def lineOf (kind : String) (fields : List (String × String)) : String :=
  String.join (kind :: fields.map fun (name, value) => s!"\t{name}={Acp.Codec.escape value}")

/-- A content item's fields. -/
def contentFields : ToolContent → List (String × String)
  | .text text => [("text", text)]
  | .diff path old new =>
    [("diff", path)] ++ (old.map fun old => [("old", old)]).getD [] ++ [("new", new)]

/-- The fields that name a request: its conversation and ticket. -/
def named (conversation ticket : Nat) : List (String × String) :=
  [("conversation", toString conversation), ("ticket", toString ticket)]

/-- The record as one line, with no line feed. -/
def Record.line : Record → String
  | .asked project conversation request =>
    lineOf "asked"
      ([("project", project), ("root", request.root), ("agent", request.agent),
          ("session", request.sessionId)] ++
        named conversation request.ticket ++
        (request.turn.map fun turn => [("turn", toString turn)]).getD [] ++
        [("title", request.call.title), ("kind", request.call.kind),
          ("input", request.call.rawInput)] ++
        request.call.content.toList.flatMap contentFields ++
        request.options.toList.flatMap fun option =>
          [("option", option.id), ("optionKind", option.kind), ("optionName", option.name)])
  | .decided conversation ticket policy decision =>
    lineOf "decided"
      (named conversation ticket ++ [("policy", policy), ("decision", decision.getD "ask")])
  | .answered conversation ticket optionId origin =>
    lineOf "answered" (named conversation ticket ++ [("option", optionId), ("by", origin.word)])
  | .refused conversation ticket optionId origin reason =>
    lineOf "refused"
      (named conversation ticket ++ [("option", optionId), ("by", origin.word), ("reason", reason)])
  | .withdrawn conversation ticket => lineOf "withdrawn" (named conversation ticket)
  | .closed conversation ticket reason =>
    lineOf "closed" (named conversation ticket ++ [("reason", reason)])

/-- The records of `batch` applied to `conversation`, the conversation after
it, in the project `project`, in event order: each request's `asked`, then
its decision by the policy `policy` when `decided` holds one, and each
withdrawal's `withdrawn`. -/
def recordsOf (project : String) (conversation : Conversation) (batch : Batch) (policy : String)
    (decided : Array (PermissionRequest × Option PermissionOption)) : Array Record :=
  batch.events.flatMap fun event =>
    match event with
    | .permission ticket turn call options =>
      let asked :=
        Record.asked project conversation.number (requestOf conversation ticket turn call options)
      match decided.find? (·.1.ticket == ticket) with
      | some (_, answer) => #[asked, .decided conversation.number ticket policy (answer.map (·.id))]
      | none => #[asked]
    | .withdrawn ticket => #[.withdrawn conversation.number ticket]
    | _ => #[]

/-- A `closed` record, for `reason`, for each ticket of `conversation` still
pending as it ends. -/
def closedRecords (conversation : Conversation) (reason : String) : Array Record :=
  conversation.pending.map fun ticket => .closed conversation.number ticket reason

end Acp.Permissions
