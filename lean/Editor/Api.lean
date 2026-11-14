import Editor.Command

/-!
# The editor API

The operations a command is written with, beyond the text port's own
(`Editor/Text.lean`): each is a program over the editor's port (`EditorM`,
`Editor/Command.lean`) made of state requests (`Editor/State/Request.lean`)
and text requests. `Editor.lean` imports this module, so config sees them.

## Asking the state

- `EditorState.ask request` makes one state request and returns its reply.
- `editorState` reads the whole state. A question is a pure function over
  it (`EditorState.buffer?`, `target?`, `findBuffer`, `value?`,
  `frame.focused`), so a command reads once and asks as much as it likes.

A reply that can be refused is a value, an `Except` of the operation's
refusal, which the command matches on: nothing here throws a refusal of the
state. What the text store refuses is thrown, as everywhere in `EditorM`.

The loop that runs a command answers its state requests
(`Editor/Command/Dispatch.lean`). Run bare, a command finds an editor with
nothing in it.
-/

namespace Editor

/-- Makes one request of the editor state and returns its reply. It is never
refused: a reply that can be is an `Except`, a value. -/
def EditorState.ask (request : StateRequest) : EditorM request.Reply :=
  ExceptT.lift (Program.request (port := editorPort) (.state request))

/-- The whole editor state, as it is now. -/
def editorState : EditorM EditorState :=
  EditorState.ask .read

end Editor
