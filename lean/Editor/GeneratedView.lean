import Editor.Scene

/-!
# A view over generated text

A view of the scene that is no window: the loop writes its text and the
state keeps the handles it is drawn with, as the tab bar
(`Editor/TabBar.lean`) and the candidate list (`EditorState.candidateList`,
`Editor/State.lean`) are kept.

- **What it is** (`GeneratedView`): a text of the text store, an anchor
  marker at its start, a view id taken once from the state's next one, so
  never a window's, and the content the text holds. The publish makes the
  text, the marker and the id the first time the view is drawn and keeps
  them for the editor's life, replacing the text's content when the
  content it is handed differs (`Loop.generatedView`, `Editor/Loop.lean`).
- **What it is not**: in no buffer list, and not focusable: no window, no
  key and no follow.
-/

namespace Editor

/-- A view over generated text once it has been drawn: the view it is drawn
in, the text it shows, that text's scroll anchor, and what the text holds. -/
structure GeneratedView where
  /-- Its view's id, taken once from the state's next one. -/
  view : ViewId
  /-- The text of the text store that holds its content. -/
  text : TextId
  /-- An anchor marker of that text, at its start. -/
  scroll : MarkerId
  /-- What the text holds. -/
  content : String
  deriving DecidableEq, Repr

end Editor
