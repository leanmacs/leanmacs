import Editor.Face

/-!
# The window's appearance

Which of the system's appearances, light or dark, the window draws its own
parts in (its title and its buttons): the one that contrasts with the
paper drawn under them, now that the title bar shows the theme's paper
(`docs/design/text-and-display.md`, "The window, as built").

The paper is the `default` face's background in the theme in force, with
config's own definitions of faces after it (`Theme.paper`, over
`Config.State.theme`). It is classified by its WCAG 2 relative luminance
(`Color.luminance`): the sRGB channels linearised with the 0.04045 knee
and the 2.4 exponent, weighted 0.2126, 0.7152 and 0.0722, with alpha
ignored. A paper is **dark** exactly when white text would contrast with
it more than black text does, `(Y + 0.05)² < 0.0525`, which is `Y` below
about 0.1791 (`Appearance.ofPaper`); otherwise it is **light**. A theme
that states no paper asks for no appearance: Lean does not restate the
base value layout draws with.

This module is pure. The reload reducer asks for the appearance when the
window opens and whenever the classification changes
(`Editor/Config/Reload.lean`), and the display carries the request to the
window (`Display.FrameRequest.appearance`). Tests: `ModelTest.appearanceChecks`.
-/

namespace Editor

/-- The system's appearance a window draws its own parts in. -/
inductive Appearance where
  /-- Dark title and buttons, for a light paper. -/
  | light
  /-- Light title and buttons, for a dark paper. -/
  | dark
  deriving DecidableEq, Repr, Inhabited

/-- One sRGB channel of 0 to 255, linearised as WCAG 2 does. -/
private def linear (channel : UInt32) : Float :=
  let value := channel.toFloat / 255.0
  if value ≤ 0.04045 then value / 12.92 else Float.pow ((value + 0.055) / 1.055) 2.4

/-- The colour's WCAG 2 relative luminance, from 0 for black to 1 for
white. Its alpha is ignored. -/
def Color.luminance (color : Color) : Float :=
  let red := linear ((color.word >>> 24) &&& 0xFF)
  let green := linear ((color.word >>> 16) &&& 0xFF)
  let blue := linear ((color.word >>> 8) &&& 0xFF)
  0.2126 * red + 0.7152 * green + 0.0722 * blue

/-- The appearance whose title and buttons contrast with `paper`: `dark`
exactly when white text contrasts with it more than black text, which is
`(Y + 0.05)² < 0.0525` for its luminance `Y`; `light` otherwise. -/
def Appearance.ofPaper (paper : Color) : Appearance :=
  let shifted := paper.luminance + 0.05
  if shifted * shifted < 0.0525 then .dark else .light

/-- The paper of `theme`: its `default` face's background, merged as layout
merges it; `none` when it states none. -/
def Theme.paper (theme : Theme) : Option Color :=
  (theme.merged ⟨"default"⟩).background

end Editor
