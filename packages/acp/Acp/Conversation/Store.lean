import Acp.Conversation.State
import Acp.Conversation.View
import AgentsApi.View
import Editor.Api

/-!
# Where the conversations are kept

Every conversation in an unscoped store (`Acp.Conversation.store`), so they
survive a reload of config, and how the editor side reads and keeps them:
every conversation, one by its number or by its buffer, and one kept in
place of the one of its number; and the view they are shown with, the one
chosen at `AgentsApi.ConversationView` or the default view. The
conversation's commands (`Acp/Conversation.lean`) and the queue of a
project's permission requests (`Acp/Permissions.lean`) both read them here.
-/

namespace Acp.Conversation

open Editor
open AgentsApi

/-- Every conversation, in the unscoped store. -/
def store : Store (Array Conversation) :=
  { name := "acp-conversations", version := 1, initial := #[]
    encode := fun all => .list (all.toList.map Conversation.encode)
    decode := fun
      | .list items => items.toArray.mapM Conversation.decode
      | _ => none }

/-- Every conversation, oldest first. -/
def conversations : EditorM (Array Conversation) := do
  return (← editorState).workspaces.getUnscoped store

/-- The conversation `number`, if there is one. -/
def conversation? (number : Nat) : EditorM (Option Conversation) := do
  return (← conversations).find? (·.number == number)

/-- The conversation the buffer `buffer` shows, if it is one's. -/
def ofBuffer? (buffer : BufferId) : EditorM (Option Conversation) := do
  return (← conversations).find? (·.buffer == some buffer.index)

/-- Keeps `conversation` in the store, in place of the one of its number. -/
def save (conversation : Conversation) : EditorM Unit := do
  let all ← conversations
  let all :=
    if all.any (·.number == conversation.number) then
      all.map fun held => if held.number == conversation.number then conversation else held
    else all.push conversation
  Workspace.setUnscoped store all

/-- The view a conversation is shown with: the one chosen at the extension
point, or the default view when none is registered. -/
def chosenView : EditorM ConversationView := do
  return (← ConversationView.named).getD defaultView

end Acp.Conversation
