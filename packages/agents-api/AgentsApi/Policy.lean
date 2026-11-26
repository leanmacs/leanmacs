import AgentsApi.Event
import Editor.Extension

/-!
# The permission policy: a choice that cannot invent an answer

When an agent asks permission for a tool call, the request offers the
options the agent built for it (`docs/design/agent-hosting.md`,
"Permissions": `allow_once`, `allow_always`, `reject_once`, sometimes
others, never a fixed set). A **policy** is a function from a request to
one of those options or "ask the user", registered at the extension point
`AgentsApi.PermissionPolicy` (`Extension.add`).

- **Its type admits no invented answer.** A decision (`Decision request`)
  is `ask`, or `choose` with an index into that request's own options, a
  `Fin request.options.size`: there is no constructor that takes an option
  or an id, so a policy can only point at an option the request offered.
  `AgentsApiTest/AgentsApi/Policy/Theorems.lean` states it as a theorem
  (`answer_offered`).
- **It is a choice** by name (`docs/design/extension-points.md`, "A hook,
  or a choice"): the reader takes the latest value registered under
  `defaultName` (`PermissionPolicy.named`, `PermissionPolicy.choose`), so
  config's, registered after a package's, replaces it. An implementation
  of agents registers `PermissionPolicy.ask`, which asks, under that name,
  and a reader falls back to it when nobody registered one.
- **Config needs no proof.** `Decision.ofKind` and `Decision.ofId` choose
  the first offered option of a protocol kind or of an id, and ask when
  none is offered.

When the policy runs, and what is done with its answer, is the
implementation's (`acp`'s `Acp/Permissions/Policy.lean`).
-/

namespace AgentsApi

/-- A permission request, as a policy is handed it: who asks, in which
session and workspace, for which tool call, offering which options. A new
field a policy may read is a field here, filled by the implementation. -/
structure PermissionRequest where
  /-- The agent's name. -/
  agent : String
  /-- The root of the workspace the session runs in, as text. -/
  root : String
  /-- The agent's id for the session. -/
  sessionId : String
  /-- The ticket the request is parked under. -/
  ticket : Nat
  /-- The turn it was asked in, none before the first prompt. -/
  turn : Option Nat
  /-- The tool call it asks for. -/
  call : ToolCall
  /-- The options the agent offered, in its order. -/
  options : Array PermissionOption
  deriving DecidableEq, Repr, Inhabited

/-- What a policy decides of `request`: to ask the user, or one of the
request's own options, by its index. -/
inductive Decision (request : PermissionRequest) where
  /-- Ask the user: the request waits in the queue. -/
  | ask
  /-- Answer with the option at `index` of the request's options. -/
  | choose (index : Fin request.options.size)

namespace Decision

/-- The option the decision answers with, none when it asks. -/
def option? {request : PermissionRequest} : Decision request → Option PermissionOption
  | .ask => none
  | .choose index => some request.options[index]

/-- Chooses the first option `request` offered whose protocol kind is
`kind` (`allow_once`, …), and asks when none is. -/
def ofKind (request : PermissionRequest) (kind : String) : Decision request :=
  match request.options.findFinIdx? (·.kind == kind) with
  | some index => .choose index
  | none => .ask

/-- Chooses the option `request` offered whose id is `id`, and asks when
none is. -/
def ofId (request : PermissionRequest) (id : String) : Decision request :=
  match request.options.findFinIdx? (·.id == id) with
  | some index => .choose index
  | none => .ask

end Decision

/-- A permission policy: the extension point, a choice by `name`. -/
structure PermissionPolicy where
  /-- Its name, which a choice finds it by. -/
  name : String
  /-- What it decides of each request. -/
  decide : (request : PermissionRequest) → Decision request
  deriving TypeName

namespace PermissionPolicy

/-- The name a reader chooses the policy by. -/
def defaultName : String :=
  "default"

/-- The default policy: it asks the user, always. -/
def ask : PermissionPolicy :=
  { name := defaultName, decide := fun _ => .ask }

/-- What `policy` answers `request` with: an option the request offered, or
none, which asks. -/
def answer (policy : PermissionPolicy) (request : PermissionRequest) : Option PermissionOption :=
  (policy.decide request).option?

/-- The latest of `policies` named `name`, as a choice reads the point: so
config's, registered after a package's, replaces it. -/
def choose (policies : Array PermissionPolicy) (name : String := defaultName) :
    Option PermissionPolicy :=
  policies.findRev? (·.name == name)

/-- The policy registered under `name`, the latest of that name, or `ask`
when nobody registered one. -/
def named (name : String := defaultName) : Editor.EditorM PermissionPolicy := do
  return (← Editor.Extension.named PermissionPolicy (·.name) name).getD ask

end PermissionPolicy

end AgentsApi
