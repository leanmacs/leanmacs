import Acp.Conversation.Diff
import AgentsApi.View

/-!
# The default view of a conversation

How `acp` shows each item of a conversation (`Acp.Conversation.defaultView`),
registered at `agents-api`'s extension point `AgentsApi.ConversationView`
under its default name, which config replaces by registering a view of that
name, built from this one with a field changed if it likes
(`{ Acp.Conversation.defaultView with toolCall := … }`).

- **The header**: `<agent> in <root>`, `title: <title>` (`(untitled)`
  before the agent sets one), `mode: <name> (<id>)`, the id alone when no
  offered mode names it and `-` before the agent reports one, and
  `usage: <used> of <size>`, with `, <amount> <currency>` when the agent
  says what it cost, `-` before it reports any.
- **A prompt**: `> <text>`. **A message**: its text.
- **A tool call**: `[+] <kind>: <title> (<status>) <first location>`,
  folded; unfolded, `[-] …` and then each item of its content, indented by
  two spaces: its text, or a diff as its path and then the change
  (`Acp/Conversation/Diff.lean`), indented by two more.
- **A permission request**: `? permission <ticket>: <title> [<option
  names>]`, followed by ` (withdrawn)`, ` (answered <option name>)` or
  ` (closed)` once it is.
- **The end of a turn**: `-- turn <n>: <stop reason>`. **A note**:
  `-- <text>`.
- **A queued request**, as the queue of a project's pending requests lists
  it: `? <agent> in <root>, conversation <n>, ticket <t>: <title>`, then
  `  input: <raw input>` (`(none)` when the agent sent none), each item of
  the call's content as an unfolded call shows it, so a diff is its path
  and its change, and `  options: <id> (<name>), …`.
-/

namespace Acp.Conversation

open AgentsApi

/-- The header's mode line's value: the mode's name and id, its id alone
when no offered mode names it, or `-` before the agent reports one. -/
def modeText (header : Header) : String :=
  match header.mode with
  | none => "-"
  | some id =>
    match header.modes.find? (·.id == id) with
    | some mode => s!"{mode.name} ({id})"
    | none => id

/-- The header's usage line's value, or `-` before the agent reports any. -/
def usageText (header : Header) : String :=
  match header.usage with
  | none => "-"
  | some usage =>
    let cost :=
      match usage.cost with
      | some (amount, currency) => s!", {amount} {currency}"
      | none => ""
    s!"{usage.used} of {usage.size}{cost}"

/-- A location as the folded row shows it: its path, and its line when the
agent gave one. -/
def placeText (place : String × Option Nat) : String :=
  match place.2 with
  | some line => s!"{place.1}:{line}"
  | none => place.1

/-- A tool call's first row. -/
def callRow (call : ToolCall) (folded : Bool) : String :=
  let mark := if folded then "[+]" else "[-]"
  let place :=
    match call.locations[0]? with
    | some place => s!" {placeText place}"
    | none => ""
  s!"{mark} {call.kind}: {call.title} ({call.status}){place}"

/-- One content item of an unfolded call, indented by two spaces. -/
def contentLines : ToolContent → Array String
  | .text words => (words.splitOn "\n").toArray.map ("  " ++ ·)
  | .diff path old new => #[s!"  {path}"] ++ (diffLines old new).map ("    " ++ ·)

/-- A permission request's row. -/
def permissionRow (ticket : Nat) (call : ToolCall) (options : Array PermissionOption)
    (state : PermissionState) : String :=
  let names := ", ".intercalate (options.toList.map (·.name))
  let suffix :=
    match state with
    | .pending => ""
    | .withdrawn => " (withdrawn)"
    | .closed => " (closed)"
    | .answered optionId =>
      let chosen :=
        (options.find? fun (option : PermissionOption) => option.id == optionId).map
          PermissionOption.name
      s!" (answered {chosen.getD optionId})"
  s!"? permission {ticket}: {call.title} [{names}]{suffix}"

/-- A queued permission request's lines (the module docs). -/
def queuedLines (conversation : Nat) (request : PermissionRequest) : Array String :=
  let input := if request.call.rawInput.isEmpty then "(none)" else request.call.rawInput
  let options :=
    ", ".intercalate (request.options.toList.map fun option => s!"{option.id} ({option.name})")
  #[s!"? {request.agent} in {request.root}, conversation {conversation}, ticket {request.ticket}: {request.call.title}",
      s!"  input: {input}"] ++
    request.call.content.flatMap contentLines ++
    #[s!"  options: {options}"]

/-- How `acp` shows a conversation (the module docs). -/
def defaultView : ConversationView where
  name := ConversationView.defaultName
  header header :=
    #[s!"{header.agent} in {header.root}", s!"title: {header.title.getD "(untitled)"}",
      s!"mode: {modeText header}", s!"usage: {usageText header}"]
  prompt text := #[s!"> {text}"]
  message text := #[text]
  toolCall call folded :=
    if folded then #[callRow call true]
    else #[callRow call false] ++ call.content.flatMap contentLines
  permission ticket call options state := #[permissionRow ticket call options state]
  turnEnded turn stopReason := #[s!"-- turn {turn}: {stopReason}"]
  note text := #[s!"-- {text}"]
  queued := queuedLines

end Acp.Conversation
