import ConfigTest.Check
import ConfigTest.Support.Themes
import Editor.Display.Real
import Editor.Face
import Editor.Ffi.Display
import Editor.Ffi.Document
import Editor.Ffi.Marker
import Editor.Ffi.Snapshot
import Editor.Ffi.Transaction
import Editor.Ffi.Window
import Editor.Menu
import Editor.Scene
import Editor.Text
import Editor.Text.Real
import Editor.Theme.Check
import Editor.Themes.Compiled

/-!
# Config tests: `Editor/Theme/Check.lean`

The tests of `Editor/Theme/Check.lean`: `cursorResolutionChecks`, of
`Themes.effective`. The root module `ConfigTest` runs them; its module doc says
what each shows.
-/

namespace ConfigTest

open Editor

/-- The themes whose cursors `cursorResolutionChecks` lay out, each with
what it is called in a failure: the built-in theme, the fixture themes
(`ConfigTest/Support/Themes.lean`), and two built-in themes
whose `cursor.normal` is redefined to set one colour alone, a background or
a foreground, so the other falls through to the default face's. -/
def resolutionThemes : Array (String × Theme) :=
  let alone (face : Face) : Theme :=
    (Theme.builtin.filter (·.name != ⟨"cursor.normal"⟩)).push { name := ⟨"cursor.normal"⟩, face }
  (#[Themes.defaultTheme] ++ fixtureThemes).map (fun named => (named.name, named.theme)) ++
    #[("a background alone", alone { background := some (Color.rgb 200 0 0) }),
      ("a foreground alone", alone { foreground := some (Color.rgb 0 200 0) })]

/-- The contract check of the completeness check's model of a cursor's
colours (`Themes.effective`, `Editor/Theme/Check.lean`) against the real
layout. For each theme of `resolutionThemes` and each cursor face the check
holds (`Face.cursorNames`), a scene of one view whose block cursor is in
that face is laid out through the display's real binding twice: in the theme
as written, and in a mirror of it whose last definition sets that face's
foreground and background to the colours the model says it has. The two
frames must be equal, and a mirror with the two colours the other way round
must give another frame, so the cursor's paint is in the frame compared. No
frame text is read: what a frame says is layout's. -/
def cursorResolutionChecks (_ : Unit) : List Check :=
  [{
      name :=
        "the completeness check's colours of each cursor face, in the built-in theme, in the fixture themes and in themes whose cursor sets one colour alone, are the ones the real layout paints it in",
      run := do
        let document ← Ffi.Document.new "ab\ncd"
        let .ok selection ←
          document.mark
              (.selection
                {
                  ranges :=
                    #[{ anchor := 0,
                        head := 0 }] }) | throw (IO.userError "the cursor's marker was refused")
        let .ok top ←
          document.mark
              (.anchor
                { offset := 0,
                  bias := .before }) | throw (IO.userError "the scroll marker was refused")
        let table ← Snapshots.new
        let snapshot ← table.add (← document.snapshot)
        let scene (face : FaceName) : Scene :=
          { size := { width := 64, height := 64 }
            views :=
              #[{ id := ⟨1⟩, rect := { x := 0, y := 0, width := 64, height := 48 }, snapshot
                  scroll := { text := ⟨0⟩, index := top.toNat }
                  selections := #[{ text := ⟨0⟩, index := selection.toNat }]
                  cursor := { shape := .block, face }, decorations := #[], status := #[] }]
            focused := some ⟨1⟩, echo := "", pending := "", preedit := none }
        -- The frame text of `scene face` laid out in `theme`, by a display
        -- of its own.
        let frame (theme : Theme) (face : FaceName) : IO String := do
          let real ← RealDisplay.over (← Ffi.Display.newCells 8 16) table.reader theme
          real.publish (scene face)
          real.display.frameText
        let mut failed : Array String := #[]
        for (called, theme) in resolutionThemes do
          for face in Face.cursorNames do
            let (foreground, background) := Themes.effective theme face
            let mirror (foreground background : Option Color) : Theme :=
              theme.push { name := face, face := { foreground, background } }
            let written ← frame theme face
            let modelled ← frame (mirror foreground background) face
            let swapped ← frame (mirror background foreground) face
            unless
              foreground.isSome && background.isSome && written == modelled && written != swapped do
              failed := failed.push s!"{called}: {face.name}"
        -- The document is held until here, past the last publish.
        discard document.read
        if !failed.isEmpty then
          throw (IO.userError s!"the model is not layout's for {failed}")
        return true }]

end ConfigTest
