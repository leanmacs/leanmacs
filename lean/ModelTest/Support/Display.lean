import Editor.Display
import Editor.Display.Model
import Editor.Menu
import Editor.Scene
import Editor.Test.Views
import Editor.Text

/-!
# Model tests: support: Display

Programs over the display port on its model: the scenes and texts it holds, the
rows it answers, and the scroll margin as a property of those rows. Shared by
several test modules under `ModelTest/Editor/`; it holds no checks of its own.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- A scene of two views, with every field of a scene and of a view set: the
first view focused, with two selections, a decoration and two status fields;
the second with none of those. Its content is named by handles only. -/
def twoViews : Scene where
  size := { width := 1600, height := 1200 }
  views :=
    #[{ id := ⟨0⟩, rect := { x := 0, y := 0, width := 800, height := 1160 }, snapshot := ⟨3⟩
        scroll := { text := ⟨1⟩, index := 0 }
        selections := #[{ text := ⟨1⟩, index := 1 }, { text := ⟨1⟩, index := 2 }]
        cursor := { shape := .block, face := ⟨"cursor.normal"⟩ }
        decorations := #[{ start := 4, stop := 9, face := ⟨"search.match"⟩ }]
        status :=
          #[{ text := "notes.txt", face := ⟨"mode-line.buffer"⟩, padding := 4 },
            { text := "1:1", face := ⟨"mode-line.secondary"⟩, side := .right, padding := 4 }] },
      { id := ⟨1⟩, rect := { x := 800, y := 0, width := 800, height := 1160 }, snapshot := ⟨4⟩
        scroll := { text := ⟨2⟩, index := 0 }, selections := #[]
        cursor := { shape := .bar, face := ⟨"cursor.insert"⟩ }, decorations := #[], status := #[] }]
  focused := some ⟨0⟩
  echo := "2 lines yanked"
  pending := "d2"
  preedit := some "´"

/-- A display program's answer, or the refusal it failed with on the left, as
a value with equality. -/
def answered {α : Type} : Except DisplayError α → DisplayError ⊕ α
  | .ok answer => .inr answer
  | .error refusal => .inl refusal

/-- Where the display model over `texts` moves `position` of the first of
them, in a view `width` pixels wide, by `lines` rows aiming for `goal`. -/
def movedBy (texts : List String) (width position : Nat) (lines : Int) (goal : Option Nat)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) : DisplayError ⊕ Display.Moved :=
  answered
    ((Display.linesFrom { snapshot := ⟨0⟩, width, position, lines, goal }).runModel
        (displayOver texts cells)).1

end ModelTest
