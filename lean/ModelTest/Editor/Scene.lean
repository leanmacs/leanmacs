import Editor.Scene
import Editor.Text
import ModelTest.Check
import ModelTest.Support.Display

/-!
# Model tests: `Editor/Scene.lean`

The model tests of `Editor/Scene.lean`: `sceneChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the scene, which is plain data (`Editor/Scene.lean`). -/
def sceneChecks : List Check :=
  [{ name := "a scene of two views reads back every field it was built with",
     run :=
       pure
         (twoViews.size == { width := 1600, height := 1200 } && twoViews.views.size == 2 &&
           (twoViews.views[0]?.map (·.selections.size)) == some 2 &&
           (twoViews.views[0]?.map (·.decorations)) ==
             some #[{ start := 4, stop := 9, face := ⟨"search.match"⟩ }] &&
           (twoViews.views[0]?.map (·.status.map (·.text))) == some #["notes.txt", "1:1"] &&
           (twoViews.views[0]?.map (·.status.map (·.side))) == some #[.left, .right] &&
           (twoViews.views[1]?.map (·.cursor)) ==
             some { shape := .bar, face := ⟨"cursor.insert"⟩ } &&
           (twoViews.views[1]?.map (·.rect.x)) == some 800 &&
           (twoViews.views[1]?.map (·.snapshot)) == some ⟨4⟩ &&
           (twoViews.views[1]?.map (·.scroll)) == some { text := ⟨2⟩, index := 0 } &&
           twoViews.focused == some ⟨0⟩ &&
           twoViews.echo == "2 lines yanked" &&
           twoViews.pending == "d2" &&
           twoViews.preedit == some "´") },
    { name := "two scenes are equal exactly when their fields are"
      run :=
        pure
          (twoViews == twoViews && twoViews != { twoViews with pending := "" } &&
            twoViews != { twoViews with views := twoViews.views.pop }) },
    { name :=
        "a status field is on the left with no padding and a view has no status face, unless they say so"
      run :=
        let field : StatusField := { text := "x", face := ⟨"mode-line.buffer"⟩ }
        let right : StatusField :=
          { field with
            side := .right, padding := 4 }
        match twoViews.views[1]? with
        | some view =>
          pure
            (field.side == .left && field.padding == 0 && right.side == .right &&
              right.padding == 4 &&
              field != right &&
              view.statusFace == none &&
              { view with statusFace := some ⟨"mode-line.inactive"⟩ } != view)
        | none => pure false },
    { name := "a view has no folds unless it says so, and one with a fold reads it back"
      run :=
        let fold : Fold := { start := 3, stop := 9, text := "▸ three lines" }
        match twoViews.views[1]? with
        | some view =>
          pure
            (view.folds == #[] && fold.decorations == #[] &&
              ({ view with folds := #[fold] }).folds == #[fold] &&
              { view with folds := #[fold] } != view)
        | none => pure false },
    { name :=
        "a scene has no divider unless it says so, and one with a divider reads back its rectangle and its face"
      run :=
        let divider : Divider :=
          { rect := { x := 798, y := 0, width := 2, height := 1200 }, face := ⟨"window-divider"⟩ }
        let divided := { twoViews with dividers := #[divider] }
        pure
          (twoViews.dividers.isEmpty && divided != twoViews &&
            divided.dividers.map (·.rect.x) == #[798] &&
            divided.dividers.map (·.face) == #[⟨"window-divider"⟩]) }]

end ModelTest
