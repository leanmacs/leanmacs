import Editor.Clipboard
import Editor.Command.Control
import Editor.Command.Registry
import Editor.Display
import Editor.Fuzzy
import Editor.State.Request
import Editor.SyntaxTree
import Editor.Watch

/-!
# The editor's port, and the type of a command

A command is a value of `EditorM`: a program over the editor's port that may
be refused. The editor's port is a composite: its requests are a sum of the
requests of its sub-ports, one constructor a sub-port (`EditorRequest`), and
the reply to each is its sub-port's reply. Today it has nine:

- **text** (`Editor/Text.lean`): texts, snapshots, markers, the edit log;
- **display** (`Editor/Display.lean`): publishing a scene, and the two
  questions of layout;
- **watch** (`Editor/Watch.lean`): the interrupt flag and a clock, which the
  command loop asks round the commands it runs;
- **clipboard** (`Editor/Clipboard.lean`): the text the system clipboard
  holds, and having it hold another;
- **fuzzy** (`Editor/Fuzzy.lean`): which of some candidates a pattern
  matches, and in what order;
- **syntax tree** (`Editor/SyntaxTree.lean`): parsing a text with a grammar
  in the library, its queries, and drawing it with a query's captures in
  faces, which setting a major mode with a syntax asks
  (`Editor/Highlight.lean`);
- **state** (`Editor/State/Request.lean`): the editor state's buffers and
  windows, the echo area and the jobs to start;
- **registry** (`Editor/Command/Registry.lean`): the questions to the
  registry and config, such as an ex binding, the language table or a
  config setting;
- **control** (`Editor/Command/Control.lean`): the loop's control of the
  running command: ending it, or running something registered inside it.

The first six keep their own programs (`TextM`, `DisplayM`, `WatchM`,
`ClipboardM`, `FuzzyM`, `SyntaxTreeM`), operations, model and contract,
unchanged.
`TextM.lift`, `DisplayM.lift`, `Watch.lift`, `Clipboard.lift` and
`Fuzzy.lift` embed a sub-port's
programs in a command, and they are `MonadLift` instances, so an operation
of any is used in a command as it is: `do let text ← createText "a";
Display.publish scene` elaborates at `EditorM`. Config is written at `EditorM`, and the lift is
what lets every text operation it calls keep its own type. There is no lift
from `JobM`, so a job is still not a command.

## A snapshot round a command's questions

`TextId.withSnapshot` takes a snapshot of a text, runs a command's program
with it, and releases it. It is here, beside the lifts, because its program
is a command (it may ask the display of the snapshot, so it is no `TextM`),
and because this is the lowest module that has a command's type: the API
(`Target.onArea`, `Editor/Api.lean`) and a vocabulary's motions
(`packages/evil/Evil/Motions.lean`), neither of which imports the other, both
import it. The rule is written once, here:

- **The snapshot is released when the program has ended**, also when it was
  refused, and the refusal is then thrown.
- **A command that is interrupted, gives up or breaks off inside the
  program leaves the snapshot**: the loop ends a command's program at that
  request, and a snapshot a command took is not undone (`Editor/Loop.lean`,
  "Rollback", "What is not undone"). It is one shared version of the text,
  held until the store is dropped.

Pinned through its callers: the API's case of `Target.onArea`
(`Editor/Api/Cases.lean`) and the motions' counts of requests and of
snapshots held (`EvilTest.evilMotionChecks`).

## The state requests are the loop's to answer

A state request reaches nothing outside the editor state, so it has no
model and no binding: its handler is one pure function over `EditorState`
(`EditorState.handle`). The command loop holds the editor state, and it
answers the state requests of each command it runs, in place, before the
command's program reaches a runner (`EditorM.dispatched`,
`Editor/Command/Dispatch.lean`). So the handler is the same function on the
models and against the library by construction, the loop stays the one
writer of the editor state, and neither runner holds a state of its own.

The registry's questions and the control requests are the loop's in the
same way: it answers a question with one pure function of what it was told
of the registry and config (`Loop.Registered.answer`), and acts on a
control request by changing the command's program, both in place and above
both runners. Neither sub-port has a model, a contract or a binding, for
the same reason.

A runner still has to answer every request of the port. Both answer each of
these three sub-ports as an editor with nothing in it would: a state
request as an editor with no buffer and no window (`EditorState.none`), a
question as with nothing registered (`RegistryRequest.bare`), and a
control request with nothing run and nothing ended (`ControlRequest.bare`).
They keep nothing of it: a command run where no loop dispatched it finds no
buffer and no window, and what it adds is gone at its next request. Every
command a host runs goes through the loop; only a test runs one bare. None
of the three reaches the library, and on the models none moves the clock.
`docs/design/lean-runtime.md` ("The editor's port is a composite") says why
the state is not the runners'.

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

A clipboard request is guarded like any request the loop does not answer
in place (the state's, the registry's and the control's): the loop asks the
interrupt flag before it
(`Editor/Command/Dispatch.lean`, "The guard"). What a command wrote to the
clipboard is not taken back when the command is rolled back: the clipboard
is outside the editor.

The fuzzy port refuses nothing, and a fuzzy request is guarded in the same
way. It changes nothing anywhere, so there is nothing of it to roll back.

**The syntax tree's refusal is a value too.** `SyntaxTree.lift` runs a
syntax tree program in a command and hands back its `Except
SyntaxTreeError`, which the command matches on: a grammar the library lacks
or a query that does not compile is nothing the text store refused, so
`TextError` is not widened. Its result type is not the program's, so it is
no `MonadLift` instance: a command calls it by name. A syntax tree request
is guarded like any request the loop does not answer in place, and is not
undone on
rollback: the library parses and draws outside the editor state
(`Editor/Loop.lean`, "What is not undone").

A command runs against the models (`EditorM.runModel`,
`Editor/Command/Model.lean`), whose state is the product of theirs, and
against the text port's real binding with a display handler, a watch
handler, a clipboard handler and a syntax tree handler (`EditorM.runReal`,
`Editor/Command/Real.lean`). The fuzzy matcher has no state, so the models
hold nothing for it, and it needs nothing a host could hand in, so the
runner against the library takes no handler for it: it is answered by its
real binding as a text request is by the text's.
`docs/design/lean-runtime.md` ("The editor's port is a composite") records
why it has this shape.

## Where an addition goes

| Addition | Where |
|---|---|
| A new question about a text, or a new text request | Inside the text port (`Editor/Text.lean`, "Adding to the port"): nothing here changes |
| A new question of layout | Inside the display port (`Editor/Display.lean`): nothing here changes |
| A request about buffers, windows or the rest of the editor state | Inside the state requests (`Editor/State/Request.lean`, "Where an addition goes"): nothing here changes |
| A question to the registry or config | Inside the registry's questions (`Editor/Command/Registry.lean`, "Where an addition goes"): nothing here changes |
| A way to end the command, or to run something registered inside it | Inside the control requests (`Editor/Command/Control.lean`, "Where an addition goes"): nothing here changes |
| A new sub-port | A constructor of `EditorRequest`, its case in `EditorRequest.Reply`, a `Program.embed…`, a lift and its `MonadLift` instance here (or a lift by name, when its refusal is a value of another type, as `SyntaxTree.lift`), and its case in both runners. A sub-port whose requests the loop answers in place, as the state's, the registry's and the control's are, is asked like the state instead: one `ask` in `Editor/Api.lean` (`EditorState.ask`), with no program type, embedding or lift |

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
  /-- A request of the fuzzy port. -/
  | fuzzy (request : FuzzyRequest)
  /-- A request of the syntax tree port. -/
  | syntaxTree (request : SyntaxTreeRequest)
  /-- A request about the editor state, which the loop that runs the
  command answers. -/
  | state (request : StateRequest)
  /-- A question to the registry or config, which the loop that runs the
  command answers. -/
  | registry (request : RegistryRequest)
  /-- A request to end the command or run something registered inside it,
  which the loop that runs the command acts on. -/
  | control (request : ControlRequest)

/-- The type of the reply to each request: its sub-port's reply. -/
def EditorRequest.Reply : EditorRequest → Type
  | .text request => request.Reply
  | .display request => request.Reply
  | .watch request => request.Reply
  | .clipboard request => request.Reply
  | .fuzzy request => request.Reply
  | .syntaxTree request => request.Reply
  | .state request => request.Reply
  | .registry request => request.Reply
  | .control request => request.Reply

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

/-- `program`, a program over the fuzzy port, as one over the editor's port:
each of its requests is the fuzzy constructor's. -/
def embedFuzzy : Program fuzzyPort α → Program editorPort α
  | .done value => .done value
  | .step request next => .step (.fuzzy request) fun reply => embedFuzzy (next reply)

/-- `program`, a program over the syntax tree port, as one over the editor's
port: each of its requests is the syntax tree constructor's. -/
def embedSyntaxTree : Program syntaxTreePort α → Program editorPort α
  | .done value => .done value
  | .step request next => .step (.syntaxTree request) fun reply => embedSyntaxTree (next reply)

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

/-- A program over the fuzzy port as a command. It is never refused. -/
def Fuzzy.lift {α : Type} (program : FuzzyM α) : EditorM α :=
  ExceptT.lift program.embedFuzzy

instance : MonadLift FuzzyM EditorM where
  monadLift := Fuzzy.lift

/-- A program over the syntax tree port as a command, its refusal handed
back as a value: the command is never refused by it, and matches on the
`Except`. No `MonadLift` instance: the result type is not the program's
("The syntax tree's refusal is a value too", in the module docs). -/
def SyntaxTree.lift {α : Type} (program : SyntaxTreeM α) : EditorM (Except SyntaxTreeError α) :=
  ExceptT.lift program.run.embedSyntaxTree

/-- Runs `run` with a snapshot of `text`, taken here. The snapshot is
released when `run` has ended, also when it was refused, and its refusal is
then thrown ("A snapshot round a command's questions", in the module
docs). -/
def TextId.withSnapshot {α : Type} (text : TextId) (run : SnapshotId → EditorM α) : EditorM α := do
  let snapshot ← text.snapshot
  let ended ← observing (run snapshot)
  snapshot.release
  match ended with
  | .ok value =>
    return value
  | .error refusal =>
    throw refusal

end Editor
