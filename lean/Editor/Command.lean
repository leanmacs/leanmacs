import Editor.Clipboard
import Editor.Display
import Editor.State.Request
import Editor.Watch

/-!
# The editor's port, and the type of a command

A command is a value of `EditorM`: a program over the editor's port that may
be refused. The editor's port is a composite: its requests are a sum of the
requests of its sub-ports, one constructor a sub-port (`EditorRequest`), and
the reply to each is its sub-port's reply. Today it has five:

- **text** (`Editor/Text.lean`): texts, snapshots, markers, the edit log;
- **display** (`Editor/Display.lean`): publishing a scene, and the two
  questions of layout;
- **watch** (`Editor/Watch.lean`): the interrupt flag and a clock, which the
  command loop asks round the commands it runs;
- **clipboard** (`Editor/Clipboard.lean`): the text the system clipboard
  holds, and having it hold another;
- **state** (`Editor/State/Request.lean`): the editor state's buffers and
  windows, the echo area and the jobs to start.

The first four keep their own programs (`TextM`, `DisplayM`, `WatchM`,
`ClipboardM`), operations, model and contract, unchanged. `TextM.lift`,
`DisplayM.lift`, `Watch.lift` and `Clipboard.lift` embed a sub-port's
programs in a command, and they are `MonadLift` instances, so an operation
of any is used in a command as it is: `do let text ← createText "a";
Display.publish scene` elaborates at `EditorM`. Config is written at `EditorM`, and the lift is
what lets every text operation it calls keep its own type. There is no lift
from `JobM`, so a job is still not a command.

## The state requests are the loop's to answer

A state request reaches nothing outside the editor state, so it has no
model and no binding: its handler is one pure function over `EditorState`
(`EditorState.handle`). The command loop holds the editor state, and it
answers the state requests of each command it runs, in place, before the
command's program reaches a runner (`EditorM.dispatched`,
`Editor/Command/Dispatch.lean`). So the handler is the same function on the
models and against the library by construction, the loop stays the one
writer of the editor state, and neither runner holds a state of its own.

A runner still has to answer every request of the port. Both answer a state
request as an editor with no buffer and no window would
(`EditorState.none`), and keep nothing of it: a command run where no loop
dispatched it finds no buffer and no window, and what it adds is gone at
its next request. Every command a host runs goes through the loop; only a
test runs one bare. A state request does not reach the library, and on the
models it does not move the clock. `docs/design/lean-runtime.md` ("The
editor's port is a composite") says why the state is not the runners'.

A refusal is a `TextError`. The display's two refusals mean what the text
port's refusals of the same names mean (a snapshot that names nothing, an
offset that is not a position), so `DisplayM.lift` maps each to its
namesake (`DisplayError.toTextError`). A sub-port whose refusal has no
`TextError` counterpart widens the error to a sum, in the phase that adds
it. The watch port refuses nothing. **The clipboard's refusal is a value**,
the reply to its request, as a state request's is: a clipboard that cannot
be reached is nothing the text store refused, so the error is not widened
and a command matches on the reply (`Editor/Clipboard.lean`, "A refusal is
a value").

A clipboard request is guarded like any request that is not the state's:
the loop asks the interrupt flag before it
(`Editor/Command/Dispatch.lean`, "The guard"). What a command wrote to the
clipboard is not taken back when the command is rolled back: the clipboard
is outside the editor.

A command runs against the four models (`EditorM.runModel`,
`Editor/Command/Model.lean`), whose state is the product of theirs, and
against the text port's real binding with a display handler, a watch
handler and a clipboard handler (`EditorM.runReal`,
`Editor/Command/Real.lean`).
`docs/design/lean-runtime.md` ("The editor's port is a composite") records
why it has this shape.

## Where an addition goes

| Addition | Where |
|---|---|
| A new question about a text, or a new text request | Inside the text port (`Editor/Text.lean`, "Adding to the port"): nothing here changes |
| A new question of layout | Inside the display port (`Editor/Display.lean`): nothing here changes |
| A request about buffers, windows or the rest of the editor state | Inside the state requests (`Editor/State/Request.lean`, "Where an addition goes"): nothing here changes |
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
  /-- A request of the watch port. -/
  | watch (request : WatchRequest)
  /-- A request of the clipboard port. -/
  | clipboard (request : ClipboardRequest)
  /-- A request about the editor state, which the loop that runs the
  command answers. -/
  | state (request : StateRequest)

/-- The type of the reply to each request: its sub-port's reply. -/
def EditorRequest.Reply : EditorRequest → Type
  | .text request => request.Reply
  | .display request => request.Reply
  | .watch request => request.Reply
  | .clipboard request => request.Reply
  | .state request => request.Reply

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

/-- `program`, a program over the watch port, as one over the editor's port:
each of its requests is the watch constructor's. -/
def embedWatch : Program watchPort α → Program editorPort α
  | .done value => .done value
  | .step request next => .step (.watch request) fun reply => embedWatch (next reply)

/-- `program`, a program over the clipboard port, as one over the editor's
port: each of its requests is the clipboard constructor's. -/
def embedClipboard : Program clipboardPort α → Program editorPort α
  | .done value => .done value
  | .step request next => .step (.clipboard request) fun reply => embedClipboard (next reply)

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

/-- A program over the watch port as a command. It is never refused. -/
def Watch.lift {α : Type} (program : WatchM α) : EditorM α :=
  ExceptT.lift program.embedWatch

instance : MonadLift DisplayM EditorM where
  monadLift := DisplayM.lift

instance : MonadLift WatchM EditorM where
  monadLift := Watch.lift

/-- A program over the clipboard port as a command. It is never refused: a
clipboard request that is refused is answered so, as a value. -/
def Clipboard.lift {α : Type} (program : ClipboardM α) : EditorM α :=
  ExceptT.lift program.embedClipboard

instance : MonadLift ClipboardM EditorM where
  monadLift := Clipboard.lift

end Editor
