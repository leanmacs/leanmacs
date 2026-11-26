import AgentsApi

/-!
# The crate's text, read into `agents-api`'s values

The crate (`rust/src/event.rs`) hands Lean each reply as text that `acp`
alone defines, and this module reads it into `agents-api`'s types: one
event a line; a line a kind word, then tab-separated `name=value` fields,
each value escaped (`\\`, `\t`, `\n`, `\r`); a list as its items' fields
repeated in order, each item starting with the same field; an optional
field left out when absent.

A line that does not read (a bad escape, an unknown kind, a field missing,
out of order or left over, a number that is not one) is an error, which
the service answers as a refusal, never a panic. The same golden lines are
held as literals in `event.rs`'s tests and in `AcpTest/Acp/Codec.lean`.

It also writes the one text Lean hands the crate: a session's MCP servers,
one a line (`serversText`), as the crate's `servers_of` reads them.
-/

namespace Acp.Codec

open AgentsApi

/-- `value` with its escapes undone, or why it does not read. -/
def unescape (value : String) : Except String String :=
  let rec go : List Char → String → Except String String
    | [], done => .ok done
    | '\\' :: '\\' :: rest, done => go rest (done.push '\\')
    | '\\' :: 't' :: rest, done => go rest (done.push '\t')
    | '\\' :: 'n' :: rest, done => go rest (done.push '\n')
    | '\\' :: 'r' :: rest, done => go rest (done.push '\r')
    | '\\' :: _, _ => .error s!"a bad escape in {repr value}"
    | character :: rest, done => go rest (done.push character)
  go value.toList ""

/-- `value` escaped for a field. -/
def escape (value : String) : String :=
  value.foldl
    (fun escaped character =>
      match character with
      | '\\' => escaped ++ "\\\\"
      | '\t' => escaped ++ "\\t"
      | '\n' => escaped ++ "\\n"
      | '\r' => escaped ++ "\\r"
      | other => escaped.push other)
    ""

/-- A line's fields, in order, their values unescaped. -/
abbrev Fields :=
  List (String × String)

/-- A reader of a line's fields, front to back. -/
abbrev Reader :=
  StateT Fields (Except String)

/-- A line's kind word and its fields, or why it does not read. -/
def split (line : String) : Except String (String × Fields) := do
  match line.splitOn "\t" with
  | [] =>
    throw "an empty line"
  | kind :: parts =>
    let fields ←
      parts.mapM fun part =>
          match part.splitOn "=" with
          | name :: value => return (name, ← unescape ("=".intercalate value))
          | [] => throw s!"a field with no name in {repr line}"
    if parts.any (!·.contains '=') then
      throw s!"a field with no value in {repr line}"
    return (kind, fields)

/-- The field `name`, which must come next. -/
def field (name : String) : Reader String := do
  match ← get with
  | (next, value) :: rest =>
    if next == name then
      set rest
      return value
    else
      throw s!"expected {name}, found {next}"
  | [] =>
    throw s!"expected {name}, found the line's end"

/-- The field `name` if it comes next, and otherwise nothing. -/
def optional (name : String) : Reader (Option String) := do
  match ← get with
  | (next, value) :: rest =>
    if next == name then
      set rest
      return some value
    else
      return none
  | [] =>
    return none

/-- `text` as a natural number. -/
def natOf (name text : String) : Reader Nat :=
  match text.toNat? with
  | some value => pure value
  | none => throw s!"{name} is no number: {repr text}"

/-- The field `name`, a natural number, which must come next. -/
def nat (name : String) : Reader Nat := do
  natOf name (← field name)

/-- The field `name`, a natural number, if it comes next. -/
def optionalNat (name : String) : Reader (Option Nat) := do
  match ← optional name with
  | some text =>
    return some (← natOf name text)
  | none =>
    return none

/-- The field `name`, an integer, which must come next. -/
def int (name : String) : Reader Int := do
  let text ← field name
  match text.toInt? with
  | some value =>
    return value
  | none =>
    throw s!"{name} is no number: {repr text}"

/-- Whether the next field is one of `names`. -/
def startsWith (names : List String) : Reader Bool := do
  return match ← get with
    | (next, _) :: _ => names.contains next
    | [] => false

/-- Items read by `item` while the next field is one of `names`, the field
each item starts with. -/
def many {α : Type} (names : List String) (item : Reader α) : Reader (Array α) := do
  let mut items := #[]
  -- Each item takes at least its first field, so the line's fields bound
  -- the loop.
  for _ in [0:(← get).length] do
    unless ← startsWith names do
      break
    items := items.push (← item)
  return items

/-- That no field is left. -/
def done : Reader Unit := do
  match ← get with
  | [] =>
    pure ()
  | (next, _) :: _ =>
    throw s!"a field left over: {next}"

/-- One item of a tool call's content. -/
def content : Reader ToolContent := do
  match ← optional "content.text" with
  | some text =>
    return .text text
  | none =>
    let path ← field "diff.path"
    let old ← optional "diff.old"
    return .diff path old (← field "diff.new")

/-- A tool call's fields. -/
def call : Reader ToolCall := do
  let id ← field "id"
  let title ← field "title"
  let kind ← field "kind"
  let status ← field "status"
  let locations ←
    many ["location.path"] do
        let path ← field "location.path"
        return (path, ← optionalNat "location.line")
  let content ← many ["content.text", "diff.path"] content
  return { id, title, kind, status, locations, content, rawInput := ← field "rawInput" }

/-- How a session ended. -/
def ending : Reader Ending := do
  match ← field "how" with
  | "exited" =>
    return .exited (← int "code")
  | "signalled" =>
    return .signalled (← int "signal")
  | "lineTooLong" =>
    return .lineTooLong
  | "failed" =>
    return .failed (← field "words")
  | "protocolError" =>
    return .protocolError (← field "words")
  | other =>
    throw s!"no such end: {other}"

/-- The event a line of kind `kind` says. -/
def eventOf (kind : String) : Reader Event := do
  match kind with
  | "chunk" =>
    let message ← optional "message"
    return .chunk message (← field "text")
  | "toolCall" =>
    return .toolCall (← call)
  | "permission" =>
    let ticket ← nat "ticket"
    let turn ← optionalNat "turn"
    let asked ← call
    let options ←
      many ["option.id"] do
          let id ← field "option.id"
          let name ← field "option.name"
          return { id, name, kind := ← field "option.kind" }
    return .permission ticket turn asked options
  | "withdrawn" =>
    return .withdrawn (← nat "ticket")
  | "usage" =>
    let used ← nat "used"
    let size ← nat "size"
    match ← optional "cost.amount" with
    | some amount =>
      return .usage used size (some (amount, ← field "cost.currency"))
    | none =>
      return .usage used size none
  | "title" =>
    return .title (← field "text")
  | "mode" =>
    return .mode (← field "id")
  | "turnEnded" =>
    let turn ← nat "turn"
    return .turnEnded turn (← field "stopReason")
  | "ended" =>
    return .ended (← ending)
  | other =>
    throw s!"no such event: {other}"

/-- `reader` over the fields of `line`, which must be of a kind `kinds`
names and leave no field over. -/
def read {α : Type} (line : String) (reader : String → Reader α) : Except String α := do
  let (kind, fields) ← split line
  let (value, _) ←
    (do
            let value ← reader kind
            done
            return value).run
        fields
  return value

/-- The event `line` says. -/
def event? (line : String) : Except String Event :=
  read line eventOf

/-- The events of a batch's text: its lines, at least one. -/
def batch? (text : String) : Except String Batch := do
  if text.isEmpty then
    throw "an empty batch"
  return { events := ← (text.splitOn "\n").toArray.mapM event? }

/-- The session an `opened` line says. -/
def opened? (line : String) : Except String Opened :=
  read line fun kind => do
    unless kind == "opened" do
      throw s!"not opened: {kind}"
    let session ← nat "session"
    let sessionId ← field "sessionId"
    let mode ← optional "mode"
    let modes ←
      many ["mode.id"] do
          let id ← field "mode.id"
          let name ← field "mode.name"
          return { id, name, description := ← optional "mode.description" }
    return { session, sessionId, mode, modes }

/-- What a `sent` line says. -/
def sent? (line : String) : Except String Sent :=
  read line fun kind => do
    unless kind == "sent" do
      throw s!"not sent: {kind}"
    return { turn := ← optionalNat "turn" }

/-- The reason a `refused` line gives, if it is one. -/
def refusal? (line : String) : Option String :=
  (read line fun kind => do
      unless kind == "refused" do
        throw s!"not refused: {kind}"
      field "reason").toOption

/-- The reply `text` is to `request`: the request's own reply type, or a
refusal, the crate's or one for text that does not read. -/
def reply (request : Request) (text : String) : Editor.PackageReply :=
  match refusal? text with
  | some reason => .error (.refused reason)
  | none =>
    let typed : Except String Dynamic :=
      match request with
      | .open .. => (opened? text).map .mk
      | .next _ => (batch? text).map .mk
      | .send .. => (sent? text).map .mk
    typed.mapError fun reason => .refused s!"acp answered with text it could not read: {reason}"

/-- One MCP server as a line of the crate's. -/
def serverLine (server : McpServer) : String :=
  let fields :=
    [("name", server.name), ("command", server.command)] ++
      server.arguments.toList.map ("arg", ·) ++
      server.environment.toList.flatMap fun (name, value) =>
        [("env.name", name), ("env.value", value)]
  "\t".intercalate ("server" :: fields.map fun (name, value) => s!"{name}={escape value}")

/-- A session's MCP servers, one a line, as the crate reads them. -/
def serversText (servers : Array McpServer) : String :=
  "\n".intercalate (servers.toList.map serverLine)

end Acp.Codec
