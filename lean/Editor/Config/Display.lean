import Editor.Config.Reload

/-!
# What a reload does to the display

The reload reducer says what the faces look like (`State.theme`,
`Editor/Config/Reload.lean`) and when that changes: when a reload installs,
and only then. The display's real binding holds the theme it sends with a
scene (`Editor/Display/Real.lean`, `RealDisplay.setTheme`). `retheme` is the
one link between the two: the runtime that owns a display calls it with how
to set its display's theme and what `Config.step` gave for an event, on the
editor thread, with the event's other effects.

It is a function of the reducer's result, so the rule "a rejected reload
changes no face" is the reducer's, not a second decision made here.

Its caller is the headless host (`Editor/Headless.lean`, `Running.reduce`),
which hands it its display's `setTheme`: the real binding's in a window and
under `--render`, and one that does nothing for the recorder, which draws no
face. `ConfigTest.faceChecks` checks it through a host over the real
binding.
-/

namespace Editor.Config

/-- Whether `effects`, the effects of one event of the reload reducer,
report a reload that installed. -/
def installed {σ : Type} (effects : Array (Effect σ)) : Bool :=
  effects.any fun
    | .report report => report.installed
    | _ => false

/-- Sets the theme of `state` with `setTheme`, a display's, when `effects`,
the effects `Config.step` gave on the way to `state`, report a reload that
installed: the next scene published is drawn in the faces of the config
that is now installed. Any other event leaves the display the theme it
has. -/
def retheme {σ : Type} (setTheme : Theme → BaseIO Unit) (state : State σ)
    (effects : Array (Effect σ)) : BaseIO Unit := do
  if installed effects then
    setTheme state.theme

end Editor.Config
