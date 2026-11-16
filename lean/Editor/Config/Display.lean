import Editor.Config.Reload

/-!
# What a reload does to the display

The reload reducer says what the faces look like (`State.theme`,
`Editor/Config/Reload.lean`) and when that changes: when a reload installs,
and when a theme is chosen with no reload (`Effect.themed`), and only
then. The display's real binding holds the theme it sends with a
scene (`Editor/Display/Real.lean`, `RealDisplay.setTheme`). `retheme` is the
one link between the two: the runtime that owns a display calls it with how
to set its display's theme and what `Config.step` gave for an event, on the
editor thread, with the event's other effects.

It is a function of the reducer's result, so the rules "a rejected reload
changes no face" and "choosing a theme nobody registered changes nothing"
are the reducer's, not second decisions made here. The display is handed the
theme's name with it, so a host can say which theme a scene was drawn in.

Its caller is the headless host (`Editor/Headless.lean`, `Running.reduce`),
which hands it its display's `setTheme`: the real binding's in a window and
under `--render`, and one that does nothing for the recorder, which draws no
face. `ModelTest.reloadChecks` pins when it is called, with a recording
`setTheme`; `ConfigTest.faceChecks` and `ConfigTest.themeChecks` check it
through a host over the real binding.
-/

namespace Editor.Config

/-- Whether `effects`, the effects of one event of the reload reducer,
report a reload that installed. -/
def installed {σ : Type} (effects : Array (Effect σ)) : Bool :=
  effects.any fun
    | .report report => report.installed
    | _ => false

/-- Whether `effects`, the effects of one event of the reload reducer, say
the theme in force was switched (`Effect.themed`). -/
def switched {σ : Type} (effects : Array (Effect σ)) : Bool :=
  effects.any fun
    | .themed => true
    | _ => false

/-- Sets the theme of `state` with `setTheme`, a display's, handed the name
of the theme in force and what the faces look like, when `effects`, the
effects `Config.step` gave on the way to `state`, report a reload that
installed or say the theme was switched: the next scene published is drawn
in the faces of the theme in force and the config that is now installed, and
sized in them too, since the real binding's heights answer defines a theme
it has yet to send (`RealDisplay.heights`). Any other event leaves the
display the theme it has. -/
def retheme {σ : Type} (setTheme : String → Theme → BaseIO Unit) (state : State σ)
    (effects : Array (Effect σ)) : BaseIO Unit := do
  if installed effects || switched effects then
    setTheme state.themeName state.theme

end Editor.Config
