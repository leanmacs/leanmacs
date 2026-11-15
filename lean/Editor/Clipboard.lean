import Editor.Program

/-!
# The clipboard interface

What the editor asks of the system clipboard: the text it holds, and to
hold another. It is a port like the others (`Editor/Program.lean`):
requests, a pure model (`Editor/Clipboard/Model.lean`) and a contract every
implementation is held to (`Editor/Clipboard/Contract.lean`). It is a
sub-port of the editor's port (`Editor/Command.lean`), so a command asks it
as it asks a text.

The clipboard is outside the editor. Another program writes it between two
of the editor's requests, and what the editor writes there stays when a
command is rolled back. So it is not editor state: a register the editor
keeps is (`Editor/State.lean`, "Registers"), and the clipboard is reached
through this port.

## The requests

- **`read`** answers the text the clipboard holds, or no text (`none`) when
  it holds none: it is empty, or what it holds is not text.
- **`write text`** has the clipboard hold `text`, in place of what it held.

## A refusal is a value

A clipboard may not be there: a host with no window system has none, and a
system's clipboard can be held by another program. Each request is then
answered `unavailable` (`ClipboardError`), with nothing changed. The reply
is an `Except`, a value the asker matches on, as a state request's refusal
is (`Editor/State/Request.lean`): nothing is thrown, so a clipboard program
is a `Program` with no error (`ClipboardM`), and what a command does when
the clipboard is not there is the command's to say.

Where no clipboard is handed in, every request is answered so
(`Clipboard.unavailable`, the handler a runner of commands takes by
default, `Editor/Command/Real.lean`).

## Where an addition goes

| Addition | Where |
|---|---|
| Something else asked of the clipboard | A constructor of `ClipboardRequest`, its case in `ClipboardRequest.Reply`, an operation here, its case in the model, and a property of the contract |
| Another way a request is refused | A constructor of `ClipboardError` |
| A binding to a system's clipboard | A handler of these requests over a clipboard of the Rust library's (`Editor/Clipboard/Real.lean`, `crates/editor-ffi/src/clipboard.rs`), held to the contract by `contract-test`; nothing here |
| What a command does with the clipboard | The command; nothing here |

Pinned by the contract, which `model-test` runs against the model, and by
`ModelTest.clipboardChecks` for what only the model shows.
-/

namespace Editor

/-- Why a request of the clipboard was refused. -/
inductive ClipboardError where
  /-- The clipboard could not be reached: there is none, or it did not
  answer. Nothing was read and nothing written. -/
  | unavailable
  deriving DecidableEq, Repr

/-- What may be asked of the clipboard. -/
inductive ClipboardRequest where
  /-- The text the clipboard holds. -/
  | read
  /-- Have the clipboard hold `text`, in place of what it held. -/
  | write (text : String)
  deriving DecidableEq, Repr

/-- The type of the reply to each request: the text held, or `none` when the
clipboard holds no text, for a read, and nothing for a write; each refused
with a `ClipboardError`. -/
def ClipboardRequest.Reply : ClipboardRequest → Type
  | .read => Except ClipboardError (Option String)
  | .write _ => Except ClipboardError Unit

/-- The clipboard port: `ClipboardRequest` and the reply to each request. -/
abbrev clipboardPort : Port :=
  { Request := ClipboardRequest, Reply := ClipboardRequest.Reply }

/-- A program over the clipboard port. It has no error of its own: a request
that is refused is answered so, as a value. -/
abbrev ClipboardM :=
  Program clipboardPort

/-- An answerer of the clipboard port's requests in `IO`: a binding to a
clipboard, or `Clipboard.unavailable` where there is none. A runner of
commands is handed one. -/
abbrev ClipboardHandler :=
  (request : ClipboardRequest) → IO request.Reply

namespace Clipboard

/-- The text the clipboard holds, or `none` when it holds no text. Refused
with `unavailable` when the clipboard cannot be reached. -/
def read : ClipboardM (Except ClipboardError (Option String)) :=
  Program.request (port := clipboardPort) .read

/-- Has the clipboard hold `text`, in place of what it held. Refused, with
nothing written, with `unavailable` when the clipboard cannot be reached. -/
def write (text : String) : ClipboardM (Except ClipboardError Unit) :=
  Program.request (port := clipboardPort) (.write text)

/-- The handler of a host that was handed no clipboard: a read and a write
are each answered `unavailable`, and nothing is kept. -/
def unavailable : ClipboardHandler
  | .read => pure (.error .unavailable)
  | .write _ => pure (.error .unavailable)

end Clipboard

end Editor
