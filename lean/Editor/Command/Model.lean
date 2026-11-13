import Editor.Command
import Editor.Display.Model
import Editor.Text.Model

/-!
# The editor's models

The models a command runs against (`Editor/Command.lean`): the text model
and the display model side by side (`EditorModel`), each answering its own
sub-port's requests, so a command's text requests and its display requests
go to the same models they would go to alone.

The display model sees a snapshot's text through its `texts`, and here they
come from the text model: before each display request they are set to the
text of every snapshot the text model holds (`EditorModel.snapshotTexts`).
So a command that takes a snapshot and asks the display about it is
answered from the text the snapshot holds, and a snapshot the command has
released is one the display does not know.
-/

namespace Editor

/-- The state of the editor's models: the text model's and the display
model's. -/
structure EditorModel where
  /-- The text model. -/
  texts : TextModel := {}
  /-- The display model. Its `texts` are filled from `texts` before each
  display request. -/
  display : DisplayModel

namespace EditorModel

/-- Models with no text, and a display in `cells` with nothing published. -/
def over (cells : Display.Cells) : EditorModel :=
  { display := { cells } }

/-- The text of each snapshot the text model holds, under its id. -/
def snapshotTexts (texts : TextModel) : Array (SnapshotId × String) :=
  (texts.snapshots.mapIdx fun index slot =>
        slot.map fun content => (⟨index⟩, content.contents)).filterMap
    id

/-- Answers `request` with its sub-port's model. -/
def handle : (request : EditorRequest) → EditorModel → request.Reply × EditorModel
  | .text request, model =>
    let (reply, texts) := TextModel.handle request model.texts
    (reply, { model with texts })
  | .display request, model =>
    let display := { model.display with texts := snapshotTexts model.texts }
    let (reply, display) := DisplayModel.handle request display
    (reply, { model with display })

end EditorModel

/-- Runs a command against the models `model`: its result, or the refusal it
failed with, and the models after its last request. -/
def EditorM.runModel {α : Type} (command : EditorM α) (model : EditorModel) :
    Except TextError α × EditorModel :=
  Program.run (port := editorPort) EditorModel.handle command.run model

end Editor
