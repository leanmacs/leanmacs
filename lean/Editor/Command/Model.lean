import Editor.Clipboard.Model
import Editor.Command
import Editor.Display.Model
import Editor.Fuzzy.Model
import Editor.SyntaxTree.Model
import Editor.Text.Model
import Editor.Watch.Model

/-!
# The editor's models

The models a command runs against (`Editor/Command.lean`): the text model,
the display model, the watch model and the clipboard model side by side
(`EditorModel`), each answering its own sub-port's requests, so a command's
requests of each go to the same model they would go to alone.

The display model sees a snapshot's text through its `texts`, and here they
come from the text model: before each display request they are set to the
text of every snapshot the text model holds (`EditorModel.snapshotTexts`).
So a command that takes a snapshot and asks the display about it is
answered from the text the snapshot holds, and a snapshot the command has
released is one the display does not know.

On the models time passes only with requests, which is all a command can
do: each text request, each display request, each clipboard request and
each fuzzy request moves the watch model's clock on by its pace
(`WatchModel.paced`), and a watch request moves nothing. So a command of six
requests takes six paces, and a test of the loop says how long a command
took by how much it asked.

A fuzzy request is answered by the fuzzy model (`FuzzyModel.rank`), which
has no state, so there is no field for it here.

The syntax tree model sees a snapshot's text through its `texts`, as the
display model does: before each syntax tree request they are set to the
text of every snapshot the text model holds, and its `documents` to the
text each was taken of (`snapshotDocuments`), so two snapshots of one text
share its parse there as they do in the library. A syntax tree request moves
the clock by a pace, as a text request does. A test reads what a command
attached and highlighted from the model (`SyntaxTreeModel.highlighted`).

The clipboard model is a field here, so a test reads what a command left
on the clipboard from the models the command ran against, and takes the
clipboard away (`ClipboardModel.available`) to see what a command does
with a refusal.

There is no model of the editor state here. A state request is the loop's
to answer, from the state the loop holds (`Editor/Command.lean`, "The state
requests are the loop's to answer"), and a command the loop runs has none
left when it reaches these models. One that does reach them, from a command
run bare, is answered as an editor with no buffer and no window would
(`EditorState.none`), with nothing kept and the clock where it was.
-/

namespace Editor

/-- The state of the editor's models: the text model's, the display model's,
the watch model's and the clipboard model's. -/
structure EditorModel where
  /-- The text model. -/
  texts : TextModel := {}
  /-- The display model. Its `texts` are filled from `texts` before each
  display request. -/
  display : DisplayModel
  /-- The watch model: the interrupt flag and the clock. Its clock moves on
  by its pace at each text request, each display request, each clipboard
  request and each fuzzy request. -/
  watch : WatchModel := {}
  /-- The clipboard model: available, and holding nothing, unless a test
  says otherwise. -/
  clipboard : ClipboardModel := {}
  /-- The syntax tree model. Its `texts` are filled from `texts` before
  each syntax tree request. -/
  syntaxTree : SyntaxTreeModel := {}

namespace EditorModel

/-- Models with no text, and a display in `cells` with nothing published. -/
def over (cells : Display.Cells) : EditorModel :=
  { display := { cells } }

/-- The text of each snapshot the text model holds, under its id. -/
def snapshotTexts (texts : TextModel) : Array (SnapshotId × String) :=
  (texts.snapshots.mapIdx fun index slot =>
        slot.map fun content => (⟨index⟩, content.contents)).filterMap
    id

/-- The text each snapshot the text model holds was taken of, under the
snapshot's id: what tells the syntax tree model two snapshots of one text
from two texts. -/
def snapshotDocuments (texts : TextModel) : Array (SnapshotId × Nat) :=
  (texts.snapshotOf.mapIdx fun index text => text.map fun id => (⟨index⟩, id.index)).filterMap id

/-- Answers `request` with its sub-port's model. A text request, a display
request, a clipboard request, a fuzzy request and a syntax tree request each
move the watch model's clock on by its pace. A state request is answered from an editor with
nothing in it, and changes nothing. -/
def handle : (request : EditorRequest) → EditorModel → request.Reply × EditorModel
  | .state request, model => ((EditorState.none.handle request).1, model)
  | .registry request, model => (request.bare, model)
  | .text request, model =>
    let (reply, texts) := TextModel.handle request model.texts
    (reply,
      { model with
        texts, watch := model.watch.paced })
  | .display request, model =>
    let display := { model.display with texts := snapshotTexts model.texts }
    let (reply, display) := DisplayModel.handle request display
    (reply,
      { model with
        display, watch := model.watch.paced })
  | .watch request, model =>
    let (reply, watch) := WatchModel.handle request model.watch
    (reply, { model with watch })
  | .clipboard request, model =>
    let (reply, clipboard) := ClipboardModel.handle request model.clipboard
    (reply,
      { model with
        clipboard, watch := model.watch.paced })
  | .fuzzy request, model =>
    ((FuzzyModel.handle request ()).1, { model with watch := model.watch.paced })
  | .syntaxTree request, model =>
    let syntaxTree :=
      { model.syntaxTree with
        texts := snapshotTexts model.texts, documents := snapshotDocuments model.texts }
    let (reply, syntaxTree) := SyntaxTreeModel.handle request syntaxTree
    (reply,
      { model with
        syntaxTree, watch := model.watch.paced })

end EditorModel

/-- Runs a command against the models `model`: its result, or the refusal it
failed with, and the models after its last request. -/
def EditorM.runModel {α : Type} (command : EditorM α) (model : EditorModel) :
    Except TextError α × EditorModel :=
  Program.run (port := editorPort) EditorModel.handle command.run model

end Editor
