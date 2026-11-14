import Editor.Config.Reload
import Editor.Display.Real

/-!
# What a reload does to the display

The reload reducer says what the faces look like (`State.theme`,
`Editor/Config/Reload.lean`) and when that changes: when a reload installs,
and only then. The display's real binding holds the theme it sends with a
scene (`Editor/Display/Real.lean`). `retheme` is the one link between the
two: the runtime that owns a display calls it with what `Config.step` gave
for an event, on the editor thread, with the event's other effects.

It is a function of the reducer's result, so the rule "a rejected reload
changes no face" is the reducer's, not a second decision made here.

Nothing calls it from a loop yet: the headless loop (`Editor/Headless.lean`)
has no display, and the loop over the real display is the display
pipeline's last phase. Until then its one caller is the check that a face
changed in config changes the next frame (`ConfigTest.faceChecks`), which
runs a reload as the loop does and hands this function the result.

It links the Rust library, through the binding, so `Editor` never imports
it.
-/

namespace Editor.Config

/-- Whether `effects`, the effects of one event of the reload reducer,
report a reload that installed. -/
def installed {σ : Type} (effects : Array (Effect σ)) : Bool :=
  effects.any fun
    | .report report => report.installed
    | _ => false

/-- Hands `real` the theme of `state` when `effects`, the effects `Config.step`
gave on the way to `state`, report a reload that installed: the next scene
published is drawn in the faces of the config that is now installed. Any
other event leaves the display the theme it has. -/
def retheme {σ : Type} (real : RealDisplay) (state : State σ) (effects : Array (Effect σ)) :
    BaseIO Unit := do
  if installed effects then
    real.setTheme state.theme

end Editor.Config
