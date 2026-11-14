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

## Buffers

- `createBuffer name contents` makes a text holding `contents`, empty by
  default, and a buffer of that name over it, with a new undo tree. The
  name is checked against a read of the state first, so a name a buffer
  already has is refused (`nameTaken`) with no text made.
- `addBuffer name text` makes a buffer over a text the command already
  has: one it copied, or took in from a job's snapshot.
- `findBuffer name` is the buffer of that name, if there is one. Names are
  unique, so there is at most one.
- `BufferId.remove` removes a buffer no window shows. Its text is released
  by the loop once the command has run to its end (`Editor/Loop.lean`,
  "What a finished command gave up"), so a command that fails afterwards
  is rolled back whole.
- `BufferId.text` is the buffer's text. Reading a buffer is the text
  port's reads on it (`TextId.read`, `rowContent`, `slice`, `byteLength`
  and the rest of `Editor/Text.lean`): there is no read request of the
  state beside them.

## Edits at positions

Every edit here goes through the text port's `apply`, as one transaction
made by the user (`Origin.user`), so it is one revision, one entry of the
edit log, and one step for the buffer's history to be told of.

- `TextId.replaceRange text start stop s` replaces the bytes of `text`
  from `start` up to, not including, `stop` with `s`
  (`Transaction.replacing`). It is refused as the store refuses a
  transaction that does not fit its text, with `badChange`: an offset
  inside a character or past the end, and a range that ends before it
  starts.
- `BufferId.insertAt` and `BufferId.deleteRange` are that on the buffer's
  text: an insertion replaces an empty range, and a deletion replaces a
  range with nothing.

Each operation that makes a text request has a case in
`Editor/Api/Cases.lean`, played on the editor's models and on the real
binding.
-/

namespace Editor

/-- Makes one request of the editor state and returns its reply. It is never
refused: a reply that can be is an `Except`, a value. -/
def EditorState.ask (request : StateRequest) : EditorM request.Reply :=
  ExceptT.lift (Program.request (port := editorPort) (.state request))

/-- The whole editor state, as it is now. -/
def editorState : EditorM EditorState :=
  EditorState.ask .read

/-- Replaces the bytes of `text` from `start` up to, not including, `stop`
with `s`, as one transaction made by the user. Refused, changing nothing,
with `badChange` unless both offsets are character boundaries within the
text and `start ≤ stop`. -/
def TextId.replaceRange (text : TextId) (start stop : Nat) (s : String) : TextM Unit := do
  let length ← text.byteLength
  discard <| text.apply (Transaction.replacing length start stop s) Origin.user

/-- The buffer called `name`, if there is one. -/
def findBuffer (name : String) : EditorM (Option BufferId) :=
  return (← editorState).findBuffer name

/-- Makes a buffer called `name` over `text`, a text the command already
has, with a new undo tree over it, and returns its id. Refused with
`nameTaken` for a name a buffer already has. -/
def addBuffer (name : String) (text : TextId) : EditorM (Except BufferRefusal BufferId) := do
  EditorState.ask (.addBuffer name text (← UndoTree.over text))

/-- Makes a buffer called `name` over a new text holding `contents`, and
returns its id. Refused with `nameTaken` for a name a buffer already has,
with no text made. -/
def createBuffer (name : String) (contents : String := "") :
    EditorM (Except BufferRefusal BufferId) := do
  if (← findBuffer name).isSome then
    return .error (.nameTaken name)
  addBuffer name (← createText contents)

namespace BufferId

/-- The text of the buffer `id`. Refused with `noSuchBuffer` for a buffer
there is none of. -/
def text (id : BufferId) : EditorM (Except BufferRefusal TextId) := do
  match (← editorState).buffer? id with
  | some buffer =>
    return .ok buffer.text
  | none =>
    return .error (.noSuchBuffer id)

/-- Removes the buffer `id`. Refused with `noSuchBuffer` for a buffer there
is none of, and with `shown` while a window shows it. -/
def remove (id : BufferId) : EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.removeBuffer id)

/-- Replaces the bytes of the buffer `id`'s text from `start` up to, not
including, `stop` with `s` (`TextId.replaceRange`). Refused with
`noSuchBuffer` for a buffer there is none of; what the store refuses is
thrown. -/
def replaceRange (id : BufferId) (start stop : Nat) (s : String) :
    EditorM (Except BufferRefusal Unit) := do
  match ← id.text with
  | .ok text =>
    text.replaceRange start stop s
    return .ok ()
  | .error refusal =>
    return .error refusal

/-- Inserts `s` into the buffer `id`'s text at the byte offset `offset`.
Refused with `noSuchBuffer` for a buffer there is none of; the store
refuses, with `badChange`, an offset that is not a character boundary
within the text. -/
def insertAt (id : BufferId) (offset : Nat) (s : String) : EditorM (Except BufferRefusal Unit) :=
  id.replaceRange offset offset s

/-- Deletes the bytes of the buffer `id`'s text from `start` up to, not
including, `stop`. Refused with `noSuchBuffer` for a buffer there is none
of; the store refuses, with `badChange`, offsets that are not character
boundaries within the text and a range that ends before it starts. -/
def deleteRange (id : BufferId) (start stop : Nat) : EditorM (Except BufferRefusal Unit) :=
  id.replaceRange start stop ""

end BufferId

end Editor
