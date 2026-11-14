import Editor.Command
import Editor.Display.Model
import Editor.Text.Model
import Editor.Watch.Model

/-!
# The editor's models

The models a command runs against (`Editor/Command.lean`): the text model,
the display model and the watch model side by side (`EditorModel`), each
answering its own sub-port's requests, so a command's requests of each go
to the same model they would go to alone.

The display model sees a snapshot's text through its `texts`, and here they
come from the text model: before each display request they are set to the
text of every snapshot the text model holds (`EditorModel.snapshotTexts`).
So a command that takes a snapshot and asks the display about it is
answered from the text the snapshot holds, and a snapshot the command has
released is one the display does not know.

On the models time passes only with requests, which is all a command can
do: each text request and each display request moves the watch model's
clock on by its pace (`WatchModel.paced`), and a watch request moves
nothing. So a command of six requests takes six paces, and a test of the
loop says how long a command took by how much it asked.
-/

namespace Editor

/-- The state of the editor's models: the text model's, the display model's
and the watch model's. -/
structure EditorModel where
  /-- The text model. -/
  texts : TextModel := {}
  /-- The display model. Its `texts` are filled from `texts` before each
  display request. -/
  display : DisplayModel
  /-- The watch model: the interrupt flag and the clock. Its clock moves on
  by its pace at each text request and each display request. -/
  watch : WatchModel := {}

namespace EditorModel

/-- Models with no text, and a display in `cells` with nothing published. -/
def over (cells : Display.Cells) : EditorModel :=
  { display := { cells } }

/-- The text of each snapshot the text model holds, under its id. -/
def snapshotTexts (texts : TextModel) : Array (SnapshotId × String) :=
  (texts.snapshots.mapIdx fun index slot =>
        slot.map fun content => (⟨index⟩, content.contents)).filterMap
    id

/-- Answers `request` with its sub-port's model. A text request and a
display request each move the watch model's clock on by its pace. -/
def handle : (request : EditorRequest) → EditorModel → request.Reply × EditorModel
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

end EditorModel

/-- Runs a command against the models `model`: its result, or the refusal it
failed with, and the models after its last request. -/
def EditorM.runModel {α : Type} (command : EditorM α) (model : EditorModel) :
    Except TextError α × EditorModel :=
  Program.run (port := editorPort) EditorModel.handle command.run model

end Editor
