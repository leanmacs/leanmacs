import Editor.Clipboard

/-!
# The clipboard interface's model

A pure model of the clipboard interface (`Editor/Clipboard.lean`): the text
the clipboard holds, if it holds one. A write replaces what is held, and a
read answers it. The contract (`Editor/Clipboard/Contract.lean`) holds it to
what every clipboard does.

One thing is the model's own, for the tests of what a command does with a
refusal:

- **A clipboard a test takes away** (`available`). With it `false` a read
  and a write are each refused with `unavailable`, and the model is as it
  was: the refused write replaces nothing. On a real clipboard a refusal
  cannot be asked for; here a test sets it.

The model starts available and holding nothing, so a read of a new model
answers no text, which is another answer than the empty text.

Pinned by `ModelTest.clipboardChecks`.
-/

namespace Editor

/-- The state of the clipboard interface's model. -/
structure ClipboardModel where
  /-- The text the clipboard holds; `none` when it holds no text. -/
  held : Option String := none
  /-- Whether the clipboard can be reached. With `false` every request is
  refused with `unavailable` and changes nothing. -/
  available : Bool := true
  deriving DecidableEq, Repr

namespace ClipboardModel

/-- Answers `request`, and the model after it: a read answers what is held,
and a write replaces it. A model that is not available refuses both, and is
as it was. -/
def handle : (request : ClipboardRequest) → ClipboardModel → request.Reply × ClipboardModel
  | .read, model => (if model.available then .ok model.held else .error .unavailable, model)
  | .write text, model =>
    if model.available then (.ok (), { model with held := some text })
    else (.error .unavailable, model)

end ClipboardModel

end Editor
