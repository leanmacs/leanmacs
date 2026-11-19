import Editor.Clipboard
import Editor.Clipboard.Model
import Editor.Command
import Editor.Command.Model
import Editor.Display
import Editor.Fuzzy
import Editor.Fuzzy.Contract
import Editor.Program
import Editor.Scene
import Editor.SyntaxTree
import Editor.SyntaxTree.Contract
import Editor.SyntaxTree.Model
import Editor.SyntaxTree.Model.Query
import Editor.Text
import Editor.Text.Model
import Editor.Watch
import Editor.Watch.Model

/-!
# The test kit: Models

The editor's models (`editorModel`), and programs over the ports run on their
models. Shared by several test modules under `ModelTest/Editor/`; it holds no
checks of its own.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import"). The core's own model tests are written on it.
-/

namespace Editor.Test

open Editor

/-- The editor's models with no text, the display's in cells one pixel each
way, with nothing published. -/
def editorModel : EditorModel :=
  .over { advance := 1, lineHeight := 1 }

/-- A command that makes one text holding `text`. What a registered command
does is observed by running it: commands are programs, and cannot be compared. -/
def makes (text : String) : EditorM Unit :=
  discard <| createText text

/-- The texts `command` leaves when it runs against the editor's models with
no text. -/
def textsOf (command : EditorM Unit) : Array String :=
  (command.runModel editorModel).2.texts.contents

/-- A command's result, or the refusal it failed with on the left, as a
value with equality. -/
def resulted {α : Type} : Except TextError α → TextError ⊕ α
  | .ok value => .inr value
  | .error refusal => .inl refusal

/-- A reply that may be refused, as a sum, which has an equality: the
refusal on the left. -/
def replied {ε α : Type} : Except ε α → ε ⊕ α
  | .ok value => .inr value
  | .error refusal => .inl refusal

/-- The watch model after `program`, run from `model`, and what the program
returned. -/
def watched {α : Type} (program : WatchM α) (model : WatchModel := {}) : α × WatchModel :=
  Program.run (port := watchPort) WatchModel.handle program model

/-- Runs a program over the clipboard port against the clipboard model
`model`: its value and the model after its last request. -/
def clipped {α : Type} (program : ClipboardM α) (model : ClipboardModel := {}) :
    α × ClipboardModel :=
  Program.run (port := clipboardPort) ClipboardModel.handle program model

/-- The names of the fuzzy contract's properties that do not hold of the
matcher `handle`. -/
def fuzzyBroken (handle : (request : FuzzyRequest) → Unit → request.Reply × Unit) :
    IO (List String) :=
  FuzzyContract.failures
    (fun property => pure (Program.run (port := fuzzyPort) handle property.holds ()).1)
    FuzzyContract.properties

/-- The syntax tree model knowing `texts`, as the snapshots `0`, `1` and so
on, and the ids of those snapshots. -/
def syntaxTreeModelOf (texts : Array String) : SyntaxTreeModel × Array SnapshotId :=
  let ids := (Array.range texts.size).map (⟨·⟩)
  ({ texts := ids.zip texts }, ids)

/-- The names of the syntax tree contract's properties that do not hold of
`handle`, run from a model knowing each property's texts. -/
def syntaxTreeBroken
    (handle : (request : SyntaxTreeRequest) → SyntaxTreeModel → request.Reply × SyntaxTreeModel) :
    IO (List String) :=
  SyntaxTreeContract.failures
    (fun property =>
      let (model, ids) := syntaxTreeModelOf property.texts
      pure
        ((Program.run (port := syntaxTreePort) handle (property.holds ids).run model).1 matches
          .ok true))
    SyntaxTreeContract.properties

/-- The editor's models with a watch model that counts: its clock, at 0,
moves on by 1 at each text request and each display request, so its reading
is how many of them a command made. -/
def countingModel (watch : WatchModel := {}) : EditorModel :=
  { editorModel with
    watch :=
      { watch with
        clock := 0, pace := 1 } }

/-- The value of a program over the text port run on a text model with no
text; `none` if it was refused. -/
def onTextModel {α : Type} (program : TextM α) : Option α :=
  match (program.runModel {}).1 with
  | .ok value => some value
  | .error _ => none

end Editor.Test
