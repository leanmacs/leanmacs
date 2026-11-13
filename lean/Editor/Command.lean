import Editor.Display

/-!
# The editor's port, and the type of a command

A command is a value of `EditorM`: a program over the editor's port that may
be refused. The editor's port is a composite: its requests are a sum of the
requests of its sub-ports, one constructor a sub-port (`EditorRequest`), and
the reply to each is its sub-port's reply. Today it has two:

- **text** (`Editor/Text.lean`): texts, snapshots, markers, the edit log;
- **display** (`Editor/Display.lean`): publishing a scene, and the two
  questions of layout.

Each sub-port keeps its own programs (`TextM`, `DisplayM`), operations,
model, real binding and contract, unchanged. `TextM.lift` and
`DisplayM.lift` embed a sub-port's programs in a command, and they are
`MonadLift` instances, so an operation of either is used in a command as it
is: `do let text ← createText "a"; Display.publish scene` elaborates at
`EditorM`. Config is written at `EditorM`, and the lift is what lets every
text operation it calls keep its own type. There is no lift from `JobM`, so
a job is still not a command.

A refusal is a `TextError`. The display's two refusals mean what the text
port's refusals of the same names mean (a snapshot that names nothing, an
offset that is not a position), so `DisplayM.lift` maps each to its
namesake (`DisplayError.toTextError`). A sub-port whose refusal has no
`TextError` counterpart widens the error to a sum, in the phase that adds
it.

A command runs against both models (`EditorM.runModel`,
`Editor/Command/Model.lean`), whose state is the product of theirs, and
against the text port's real binding with a display handler
(`EditorM.runReal`, `Editor/Command/Real.lean`). `docs/design/lean-runtime.md`
("The editor's port is a composite") records why it has this shape.

## Where an addition goes

| Addition | Where |
|---|---|
| A new question about a text, or a new text request | Inside the text port (`Editor/Text.lean`, "Adding to the port"): nothing here changes |
| A new question of layout | Inside the display port (`Editor/Display.lean`): nothing here changes |
| Requests about buffers and windows (command loop, phase 8) | A third constructor, `EditorRequest.state`, whose handler is one pure function over `EditorState`, the same in the model and in the real runner; both runners' state gains an `EditorState` |
| A new sub-port | A constructor of `EditorRequest`, its case in `EditorRequest.Reply`, a `Program.embed…`, a lift and its `MonadLift` instance here, and its case in both runners |

What the composite runners do with each sub-port is pinned by
`ModelTest.commandPortChecks`.
-/

namespace Editor

/-- What a command may ask of the editor: a request of one of its sub-ports.
A new sub-port is a constructor here. -/
inductive EditorRequest where
  /-- A request of the text port. -/
  | text (request : TextRequest)
  /-- A request of the display port. -/
  | display (request : DisplayRequest)

/-- The type of the reply to each request: its sub-port's reply. -/
def EditorRequest.Reply : EditorRequest → Type
  | .text request => request.Reply
  | .display request => request.Reply

/-- The editor's port: `EditorRequest` and the reply to each request. -/
abbrev editorPort : Port :=
  { Request := EditorRequest, Reply := EditorRequest.Reply }

/-- A command: a program over the editor's port that may be refused with a
`TextError`. It may change editor state, and it cannot block: it holds no
`IO`, and no sub-port has a request that waits. -/
abbrev EditorM :=
  ExceptT TextError (Program editorPort)

namespace Program

variable {α : Type}

/-- `program`, a program over the text port, as one over the editor's port:
each of its requests is the text constructor's. -/
def embedText : Program textPort α → Program editorPort α
  | .done value => .done value
  | .step request next => .step (.text request) fun reply => embedText (next reply)

/-- `program`, a program over the display port, as one over the editor's
port: each of its requests is the display constructor's. -/
def embedDisplay : Program displayPort α → Program editorPort α
  | .done value => .done value
  | .step request next => .step (.display request) fun reply => embedDisplay (next reply)

end Program

/-- The text port's refusal of the same name as the display's: both ports
mean the same by each. -/
def DisplayError.toTextError : DisplayError → TextError
  | .noSuchSnapshot => .noSuchSnapshot
  | .badPosition => .badPosition

/-- A program over the text port as a command. -/
def TextM.lift {α : Type} (program : TextM α) : EditorM α :=
  ExceptT.mk program.run.embedText

/-- A program over the display port as a command, its refusal the text
port's of the same name. -/
def DisplayM.lift {α : Type} (program : DisplayM α) : EditorM α :=
  ExceptT.mk ((·.mapError DisplayError.toTextError) <$> program.run.embedDisplay)

instance : MonadLift TextM EditorM where
  monadLift := TextM.lift

instance : MonadLift DisplayM EditorM where
  monadLift := DisplayM.lift

end Editor
