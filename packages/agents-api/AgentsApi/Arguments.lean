import AgentsApi.Request

/-!
# A session's values as command arguments

What a job that runs a session posts to a command of the editor thread
(`Editor.post`): the plain `Argument`s of an event (`Event.toArguments`),
of a batch (`Batch.toArguments`) and of an opened session
(`Opened.toArguments`), and each read back (`ofArguments?`). A job's post
carries `Argument`s only, so a consumer that runs a session in a job and
handles its events on the editor thread writes them with this, and reads
them back in its command. The encoding is this package's, neutral of any
protocol: each value is its kind's word, then its fields, an optional one
written `false`, or `true` and the value, and an array its count and then
each item.

A list that is not one written here, a truncated one or one of an unknown
kind among them, is read as none, never as part of a value.
-/

namespace AgentsApi

open Editor (Argument)

namespace Arguments

/-- An optional string: `false`, or `true` and the string. -/
def optionalString : Option String → List Argument
  | none => [.bool false]
  | some text => [.bool true, .str text]

/-- An optional number: `false`, or `true` and the number. -/
def optionalNat : Option Nat → List Argument
  | none => [.bool false]
  | some value => [.bool true, .nat value]

/-- An optional string off the front of `arguments`, and the rest. -/
def optionalString? : List Argument → Option (Option String × List Argument)
  | .bool false :: rest => some (none, rest)
  | .bool true :: .str text :: rest => some (some text, rest)
  | _ => none

/-- An optional number off the front of `arguments`, and the rest. -/
def optionalNat? : List Argument → Option (Option Nat × List Argument)
  | .bool false :: rest => some (none, rest)
  | .bool true :: .nat value :: rest => some (some value, rest)
  | _ => none

/-- `count` items off the front of `arguments`, each read by `item?`, oldest
first, and the rest: an accumulating loop, so a batch of thousands of events
reads in constant stack. -/
def many {α : Type} (item? : List Argument → Option (α × List Argument)) :
    Nat → List Argument → Array α → Option (Array α × List Argument)
  | 0, rest, done => some (done, rest)
  | count + 1, arguments, done => do
    let (value, rest) ← item? arguments
    many item? count rest (done.push value)

/-- `arguments`, read wholly by `read?`: none when anything is left over. -/
def whole {α : Type} (read? : List Argument → Option (α × List Argument))
    (arguments : List Argument) : Option α := do
  let (value, rest) ← read? arguments
  if rest.isEmpty then
    some value
  else
    none

end Arguments

open Arguments

/-- A tool call's content item as arguments. -/
def ToolContent.toArguments : ToolContent → List Argument
  | .text words => [.str "text", .str words]
  | .diff path old new => [.str "diff", .str path] ++ optionalString old ++ [.str new]

/-- A content item off the front of `arguments`, and the rest. -/
def ToolContent.take? : List Argument → Option (ToolContent × List Argument)
  | .str "text" :: .str words :: rest => some (.text words, rest)
  | .str "diff" :: .str path :: rest => do
    let (old, rest) ← optionalString? rest
    match rest with
    | .str new :: rest =>
      some (.diff path old new, rest)
    | _ =>
      none
  | _ => none

/-- A location as arguments: its path, then its line, when it has one. -/
def location (place : String × Option Nat) : List Argument :=
  .str place.1 :: optionalNat place.2

/-- A location off the front of `arguments`, and the rest. -/
def location? : List Argument → Option ((String × Option Nat) × List Argument)
  | .str path :: rest => do
    let (line, rest) ← optionalNat? rest
    return ((path, line), rest)
  | _ => none

/-- A tool call as arguments: its id, title, kind and status, its locations
and its content, each counted, and its raw input. -/
def ToolCall.toArguments (call : ToolCall) : List Argument :=
  [.str call.id, .str call.title, .str call.kind, .str call.status, .nat call.locations.size] ++
    call.locations.toList.flatMap location ++
    [.nat call.content.size] ++
    call.content.toList.flatMap ToolContent.toArguments ++
    [.str call.rawInput]

/-- A tool call off the front of `arguments`, and the rest. -/
def ToolCall.take? : List Argument → Option (ToolCall × List Argument)
  | .str id :: .str title :: .str kind :: .str status :: .nat count :: rest => do
    let (locations, rest) ← many location? count rest #[]
    let .nat items :: rest := rest | none
    let (content, rest) ← many ToolContent.take? items rest #[]
    let .str rawInput :: rest := rest | none
    return ({ id, title, kind, status, locations, content, rawInput }, rest)
  | _ => none

/-- A permission option as arguments: its id, name and kind. -/
def PermissionOption.toArguments (option : PermissionOption) : List Argument :=
  [.str option.id, .str option.name, .str option.kind]

/-- A permission option off the front of `arguments`, and the rest. -/
def PermissionOption.take? : List Argument → Option (PermissionOption × List Argument)
  | .str id :: .str name :: .str kind :: rest => some ({ id, name, kind }, rest)
  | _ => none

/-- How a session ended, as arguments: its kind's word, then its field. -/
def Ending.toArguments : Ending → List Argument
  | .exited code => [.str "exited", .int code]
  | .signalled signal => [.str "signalled", .int signal]
  | .lineTooLong => [.str "lineTooLong"]
  | .failed words => [.str "failed", .str words]
  | .protocolError words => [.str "protocolError", .str words]

/-- An ending off the front of `arguments`, and the rest. -/
def Ending.take? : List Argument → Option (Ending × List Argument)
  | .str "exited" :: .int code :: rest => some (.exited code, rest)
  | .str "signalled" :: .int signal :: rest => some (.signalled signal, rest)
  | .str "lineTooLong" :: rest => some (.lineTooLong, rest)
  | .str "failed" :: .str words :: rest => some (.failed words, rest)
  | .str "protocolError" :: .str words :: rest => some (.protocolError words, rest)
  | _ => none

/-- An event as arguments: its kind's word, then its fields. -/
def Event.toArguments : Event → List Argument
  | .chunk messageId? text => .str "chunk" :: optionalString messageId? ++ [.str text]
  | .toolCall call => .str "toolCall" :: call.toArguments
  | .permission ticket turn call options =>
    [.str "permission", .nat ticket] ++ optionalNat turn ++ call.toArguments ++
      [.nat options.size] ++
      options.toList.flatMap PermissionOption.toArguments
  | .withdrawn ticket => [.str "withdrawn", .nat ticket]
  | .usage used size cost =>
    [.str "usage", .nat used, .nat size] ++
      match cost with
      | none => [.bool false]
      | some (amount, currency) => [.bool true, .str amount, .str currency]
  | .title text => [.str "title", .str text]
  | .mode id => [.str "mode", .str id]
  | .turnEnded turn stopReason => [.str "turnEnded", .nat turn, .str stopReason]
  | .ended how => .str "ended" :: how.toArguments

/-- An event off the front of `arguments`, and the rest. -/
def Event.take? : List Argument → Option (Event × List Argument)
  | .str "chunk" :: rest => do
    let (messageId?, rest) ← optionalString? rest
    let .str text :: rest := rest | none
    return (.chunk messageId? text, rest)
  | .str "toolCall" :: rest => do
    let (call, rest) ← ToolCall.take? rest
    return (.toolCall call, rest)
  | .str "permission" :: .nat ticket :: rest => do
    let (turn, rest) ← optionalNat? rest
    let (call, rest) ← ToolCall.take? rest
    let .nat count :: rest := rest | none
    let (options, rest) ← many PermissionOption.take? count rest #[]
    return (.permission ticket turn call options, rest)
  | .str "withdrawn" :: .nat ticket :: rest => some (.withdrawn ticket, rest)
  | .str "usage" :: .nat used :: .nat size :: .bool false :: rest =>
    some (.usage used size none, rest)
  | .str "usage" :: .nat used :: .nat size :: .bool true :: .str amount :: .str currency :: rest =>
    some (.usage used size (some (amount, currency)), rest)
  | .str "title" :: .str text :: rest => some (.title text, rest)
  | .str "mode" :: .str id :: rest => some (.mode id, rest)
  | .str "turnEnded" :: .nat turn :: .str stopReason :: rest =>
    some (.turnEnded turn stopReason, rest)
  | .str "ended" :: rest => do
    let (how, rest) ← Ending.take? rest
    return (.ended how, rest)
  | _ => none

/-- The event `arguments` are, wholly (`Event.toArguments`). -/
def Event.ofArguments? (arguments : List Argument) : Option Event :=
  whole Event.take? arguments

/-- A batch as arguments: the count of its events, then each. -/
def Batch.toArguments (batch : Batch) : List Argument :=
  .nat batch.events.size :: batch.events.toList.flatMap Event.toArguments

/-- A batch off the front of `arguments`, and the rest. -/
def Batch.take? : List Argument → Option (Batch × List Argument)
  | .nat count :: rest => do
    let (events, rest) ← many Event.take? count rest #[]
    return ({ events }, rest)
  | _ => none

/-- The batch `arguments` are, wholly (`Batch.toArguments`). -/
def Batch.ofArguments? (arguments : List Argument) : Option Batch :=
  whole Batch.take? arguments

/-- A mode as arguments: its id, its name and its description, when it has
one. -/
def Mode.toArguments (mode : Mode) : List Argument :=
  [.str mode.id, .str mode.name] ++ optionalString mode.description

/-- A mode off the front of `arguments`, and the rest. -/
def Mode.take? : List Argument → Option (Mode × List Argument)
  | .str id :: .str name :: rest => do
    let (description, rest) ← optionalString? rest
    return ({ id, name, description }, rest)
  | _ => none

/-- An opened session as arguments: the service's number, the agent's
session id, the mode it is in, when it has one, then the count of its modes
and each. -/
def Opened.toArguments (opened : Opened) : List Argument :=
  [.nat opened.session, .str opened.sessionId] ++ optionalString opened.mode ++
    [.nat opened.modes.size] ++
    opened.modes.toList.flatMap Mode.toArguments

/-- An opened session off the front of `arguments`, and the rest. -/
def Opened.take? : List Argument → Option (Opened × List Argument)
  | .nat session :: .str sessionId :: rest => do
    let (mode, rest) ← optionalString? rest
    let .nat count :: rest := rest | none
    let (modes, rest) ← many Mode.take? count rest #[]
    return ({ session, sessionId, mode, modes }, rest)
  | _ => none

/-- The opened session `arguments` are, wholly (`Opened.toArguments`). -/
def Opened.ofArguments? (arguments : List Argument) : Option Opened :=
  whole Opened.take? arguments

end AgentsApi
