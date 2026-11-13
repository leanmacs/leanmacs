import Editor.Display

/-!
# The display model

The pure model of the display interface (`Editor/Display.lean`): it records
every scene published to it, in order, and answers the queries by laying the
text of a snapshot out in fixed-size cells (`Display.Cells`). It is a model
for tests, not a copy of layout kept at run time: the editor asks the real
display every time.

It sees a snapshot's text through `texts`, which a test fills, and which the
command loop fills from the text model when it runs both ports together.
-/

namespace Editor

/-- The state of the display model. -/
structure DisplayModel where
  /-- The cells it lays text out in. -/
  cells : Display.Cells
  /-- The text of each snapshot it knows. -/
  texts : Array (SnapshotId × String) := #[]
  /-- The scenes published to it, oldest first. -/
  published : Array Scene := #[]

namespace DisplayModel

/-- The scenes published so far, oldest first. -/
def scenes (model : DisplayModel) : Array Scene :=
  model.published

/-- The text of `snapshot`, if the model knows it. -/
def text? (model : DisplayModel) (snapshot : SnapshotId) : Option String :=
  (model.texts.find? (·.1 == snapshot)).map (·.2)

/-- The rows a view shows. -/
def rows (_ : DisplayModel) (_ : Display.RowsQuery) : Except DisplayError (Array Display.Row) :=
  .error .noSuchSnapshot

/-- Where a position goes. -/
def move (_ : DisplayModel) (_ : Display.MoveQuery) : Except DisplayError Display.Moved :=
  .error .noSuchSnapshot

/-- Answers `request`: a scene is recorded, and a query is answered from the
model as it is. -/
def handle : (request : DisplayRequest) → DisplayModel → request.Reply × DisplayModel
  | .publish scene, model => ((), { model with published := model.published.push scene })
  | .rows query, model => (model.rows query, model)
  | .move query, model => (model.move query, model)

end DisplayModel

/-- Runs a display program against the model `model`: its result, or the
refusal it failed with, and the model after its last request. -/
def DisplayM.runModel {α : Type} (program : DisplayM α) (model : DisplayModel) :
    Except DisplayError α × DisplayModel :=
  Program.run (port := displayPort) DisplayModel.handle program.run model

end Editor
