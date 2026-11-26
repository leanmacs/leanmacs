import Acp.Conversation.State

/-!
# A conversation as text

The text of a conversation's buffer, pure (`Acp.Conversation.render`): the
view's header, an empty row, then each item's lines as the view gives them,
in order. Every line a field gives is split at its line feeds, so a view
cannot break the map of rows. With the lines comes that map: for each row,
the id of the tool call it shows, if it shows one, which `agent-toggle`
reads to find the call on the cursor's row (`rowOf` gives a call's first
row). A tool call is folded unless its id is among the conversation's
`unfolded`.
-/

namespace Acp.Conversation

open AgentsApi

/-- A field's lines, each split at its line feeds. -/
def rows (lines : Array String) : Array String :=
  lines.flatMap fun line => (line.splitOn "\n").toArray

/-- The lines of `item` in `conversation` as `view` shows it. -/
def itemLines (view : ConversationView) (conversation : Conversation) : Item → Array String
  | .prompt text _ => view.prompt text
  | .message _ text => view.message text
  | .toolCall call => view.toolCall call (!conversation.unfolded.contains call.id)
  | .permission ticket _ call options state => view.permission ticket call options state
  | .turnEnded turn stopReason => view.turnEnded turn stopReason
  | .note text => view.note text
  | .userMessage _ text => view.prompt text

/-- The text of `conversation` as `view` shows it, a line a row, and for each
row the id of the tool call it shows, if any (the module docs). -/
def render (view : ConversationView) (conversation : Conversation) :
    Array String × Array (Option String) :=
  Id.run do
    let header := rows (view.header conversation.header) |>.push ""
    let mut lines := header
    let mut map : Array (Option String) := header.map fun _ => none
    for item in conversation.items do
      let shown := rows (itemLines view conversation item)
      let id :=
        match item with
        | .toolCall call => some call.id
        | _ => none
      lines := lines ++ shown
      map := map ++ shown.map fun _ => id
    return (lines, map)

/-- The text of `conversation` as `view` shows it: each row ended with a line
feed. -/
def text (view : ConversationView) (conversation : Conversation) : String :=
  String.join ((render view conversation).1.toList.map (· ++ "\n"))

/-- The first row that shows the tool call `id`, if one does. -/
def rowOf (view : ConversationView) (conversation : Conversation) (id : String) : Option Nat :=
  (render view conversation).2.findIdx? (· == some id)

end Acp.Conversation
