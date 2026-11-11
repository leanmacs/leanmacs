import Editor.Ffi
import Editor.Text

/-!
# The real binding of the text port

The text port (`Editor/Text.lean`) answered by the Rust library. This is the
only module of the port that imports `Editor.Ffi`, so only an executable
linked with the library imports it: the editor, to run commands for real, and
`contract-test`, which runs the port's contract against it.

It is a thin adapter. A request is plain data and names a text by an id, so
the binding keeps the table from ids to the library's handles: an id is an
index into it. Each request is one lookup in the table and one call of a
binding. What an edit means, and when it is refused, is the library's
decision, and the contract (`Editor/Text/Contract.lean`) is what says it is
the same as the model's.

A text lives as long as its table. Dropping the table drops the last
reference to each of its documents, and their finalisers free them.
-/

namespace Editor

/-- The table of the real binding: the library's document for each text made
so far. A text's id is its index here. -/
abbrev RealTexts :=
  Array Ffi.Document

namespace RealTexts

/-- The library's answer to an edit of the text `id`, replacing its bytes
from `start` up to `stop` by `s`.

The port's offsets are `Nat` and the library's are machine words. An offset
no word holds is past the end of any text, so it is refused here: converted,
it would wrap round to an offset the library might accept. -/
def edit (id : TextId) (start stop : Nat) (s : String) :
    StateT RealTexts IO (Except TextError Unit) := do
  let some document := (← get)[id.index]? | return .error .noSuchText
  unless start < USize.size ∧ stop < USize.size do
    return .error .badRange
  if ← document.replace start.toUSize stop.toUSize s then
    return .ok ()
  return .error .badRange

/-- The library's answer to each request. -/
def handle : (request : TextRequest) → StateT RealTexts IO request.Reply
  | .create initial => do
    let document ← Ffi.Document.new initial
    modifyGet fun documents => (⟨documents.size⟩, documents.push document)
  | .insert id offset s => edit id offset offset s
  | .delete id start stop => edit id start stop ""
  | .read id => do
    let some document := (← get)[id.index]? | return .error .noSuchText
    return .ok (← document.read)

end RealTexts

/-- Runs a command against the Rust library, with `texts` as the texts made
so far: its result, or the refusal it failed with, and the table after its
last request. -/
def EditorM.runReal {α : Type} (command : EditorM α) (texts : RealTexts) :
    IO (Except TextError α × RealTexts) :=
  (Program.runM (port := textPort) RealTexts.handle command.run).run texts

end Editor
