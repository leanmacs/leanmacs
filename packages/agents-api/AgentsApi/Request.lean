import AgentsApi.Agent
import AgentsApi.Event
import AgentsApi.Order
import Editor.PackageService

/-!
# The service `agents`: its requests and its replies

A running job reaches an implementation of agents through one package
service, `agents` (`AgentsApi.serviceName`; `docs/design/packages.md`,
"Behind a port, so it stays replaceable"), in the vocabulary this package
owns: a request is plain `Argument`s (`Request.toPackage`, read back with
`Request.ofPackage?`), and each reply is a type of this package's, which
derives `TypeName` (`Opened`, `Batch`, `Sent`), so no other service's reply
can pass for one.

- **`open`** hands the service a streaming child the job opened, with the
  session's working directory and MCP servers. It is answered once the
  agent has a session: the implementation's number for it (which `next` and
  `send` name), the agent's session id, and the modes the agent reported.
- **`load`** hands the service a streaming child as `open` does, and the
  agent's id of a session it holds in its own store: the agent replays the
  session's history as its first events, and the request is answered as
  `open` is, with that session id, once the agent has loaded it. An agent
  that offers no load, or holds no such session, refuses it.
- **`next`** waits for the session's next events, a batch of at least one.
  It is a long poll: a flush of the service does not wait for it. A second
  `next` of a session while one is pending is refused at its start, and one
  after the session's last event (`Event.ended`) is refused.
- **`send`** hands the session an order, from any job. A prompt is answered
  once it is on its way, with its turn's number; its end is an event
  (`Event.turnEnded`), so an answer to a permission request can go out while
  the prompt is pending. An answer to a ticket that is not parked is
  refused.

A session's child is the job's that opened it, so it ends with that job.
-/

namespace AgentsApi

/-- The service's name, as a request names it. -/
def serviceName : String :=
  "agents"

/-- How many bytes of each of the agent's streams may wait to be read, a
line in progress among them: sixteen mebibytes. A line past it ends the
session (`Ending.lineTooLong`). -/
def lineBound : Nat :=
  16 * 1024 * 1024

/-- A mode a session can be in, as the agent reports it. -/
structure Mode where
  /-- The id an order names. -/
  id : String
  /-- What it is called, for people. -/
  name : String
  /-- What it does, when the agent says. -/
  description : Option String := none
  deriving DecidableEq, Repr, Inhabited

/-- What `open` answers: the session. -/
structure Opened where
  /-- The implementation's number for the session, which `next` and `send`
  name. -/
  session : Nat
  /-- The agent's id for the session. -/
  sessionId : String
  /-- The mode the session is in, when the agent reports modes. -/
  mode : Option String := none
  /-- The modes the agent offers. -/
  modes : Array Mode := #[]
  deriving DecidableEq, Repr, Inhabited, TypeName

/-- What `next` answers: the session's events since the last `next`, at
least one, oldest first. -/
structure Batch where
  /-- The events. -/
  events : Array Event
  deriving DecidableEq, Repr, Inhabited, TypeName

/-- What `send` answers: that the order is on its way, and for a prompt the
turn it began. -/
structure Sent where
  /-- The turn a prompt began; none for any other order. -/
  turn : Option Nat := none
  deriving DecidableEq, Repr, Inhabited, TypeName

/-- A request of the service `agents`. -/
inductive Request where
  /-- Hand over the streaming child `child`, the session to run in `cwd`
  with `servers`. -/
  | «open» (child : Nat) (cwd : String) (servers : Array McpServer)
  /-- Wait for the session's next events. -/
  | next (session : Nat)
  /-- Hand the session an order. -/
  | send (session : Nat) (order : Order)
  /-- Hand over the streaming child `child`, the session `sessionId` to load
  from the agent's own store and run in `cwd` with `servers`. -/
  | load (child : Nat) (cwd : String) (servers : Array McpServer) (sessionId : String)
  deriving DecidableEq, Repr, Inhabited

/-- Why a session's request was not answered. -/
inductive Refusal where
  /-- The agent's child could not be started. -/
  | child (error : Editor.ProcessError)
  /-- The service refused the request, or there was none. -/
  | service (error : Editor.PackageError)
  deriving DecidableEq, Repr, Inhabited

/-- Why a session's request was not answered, in words: a child's start by
the process error's own words, a service's refusal with its reason, and a
missing service by its name. -/
def Refusal.describe : Refusal → String
  | .child error => error.describe
  | .service (.refused reason) => s!"refused: {reason}"
  | .service (.noSuchService name) => s!"no service {name}"

namespace Request

/-- An MCP server as arguments: its name, its command, the count of its
arguments and each, then the count of its variables and each name and
value. -/
def serverArguments (server : McpServer) : List Editor.Argument :=
  [.str server.name, .str server.command, .nat server.arguments.size] ++
    server.arguments.toList.map .str ++
    [.nat server.environment.size] ++
    server.environment.toList.flatMap fun (name, value) => [.str name, .str value]

/-- An order as arguments: its kind's word, then its fields. -/
def orderArguments : Order → List Editor.Argument
  | .prompt text => [.str "prompt", .str text]
  | .cancel => [.str "cancel"]
  | .setMode id => [.str "setMode", .str id]
  | .answer ticket optionId => [.str "answer", .nat ticket, .str optionId]

/-- The request as the job port carries it. -/
def toPackage : Request → Editor.PackageRequest
  | .open child cwd servers =>
    { service := serviceName, operation := "open"
      arguments :=
        [.nat child, .str cwd, .nat servers.size] ++ servers.toList.flatMap serverArguments }
  | .next session => { service := serviceName, operation := "next", arguments := [.nat session] }
  | .send session order =>
    { service := serviceName, operation := "send",
      arguments := .nat session :: orderArguments order }
  | .load child cwd servers sessionId =>
    { service := serviceName, operation := "load"
      arguments :=
        [.nat child, .str cwd, .str sessionId, .nat servers.size] ++
          servers.toList.flatMap serverArguments }

/-- `count` strings off the front of `arguments`, and the rest. -/
def strings : Nat → List Editor.Argument → Option (Array String × List Editor.Argument)
  | 0, rest => some (#[], rest)
  | count + 1, .str text :: rest => do
    let (more, rest) ← strings count rest
    return (#[text] ++ more, rest)
  | _ + 1, _ => none

/-- `count` pairs of strings off the front of `arguments`, and the rest. -/
def pairs : Nat → List Editor.Argument → Option (Array (String × String) × List Editor.Argument)
  | 0, rest => some (#[], rest)
  | count + 1, .str name :: .str value :: rest => do
    let (more, rest) ← pairs count rest
    return (#[(name, value)] ++ more, rest)
  | _ + 1, _ => none

/-- One MCP server off the front of `arguments`, and the rest. -/
def server? : List Editor.Argument → Option (McpServer × List Editor.Argument)
  | .str name :: .str command :: .nat count :: rest => do
    let (arguments, rest) ← strings count rest
    match rest with
    | .nat variables :: rest =>
      let (environment, rest) ← pairs variables rest
      return ({ name, command, arguments, environment }, rest)
    | _ =>
      none
  | _ => none

/-- `count` MCP servers off the front of `arguments`, which must hold
nothing after them. -/
def servers? : Nat → List Editor.Argument → Option (Array McpServer)
  | 0, [] => some #[]
  | 0, _ :: _ => none
  | count + 1, arguments => do
    let (server, rest) ← server? arguments
    return #[server] ++ (← servers? count rest)

/-- The order `arguments` say. -/
def order? : List Editor.Argument → Option Order
  | [.str "prompt", .str text] => some (.prompt text)
  | [.str "cancel"] => some .cancel
  | [.str "setMode", .str id] => some (.setMode id)
  | [.str "answer", .nat ticket, .str optionId] => some (.answer ticket optionId)
  | _ => none

/-- The request `request` carries, if it is one of the service `agents`
written as `toPackage` writes it. -/
def ofPackage? (request : Editor.PackageRequest) : Option Request :=
  if request.service != serviceName then none
  else
    match request.operation, request.arguments with
    | "open", .nat child :: .str cwd :: .nat count :: rest => do
      return .open child cwd (← servers? count rest)
    | "next", [.nat session] => some (.next session)
    | "send", .nat session :: order => do
      return .send session (← order? order)
    | "load", .nat child :: .str cwd :: .str sessionId :: .nat count :: rest => do
      return .load child cwd (← servers? count rest) sessionId
    | _, _ => none

end Request

end AgentsApi
