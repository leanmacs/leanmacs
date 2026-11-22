import Editor.Api
import Editor.Command.Call
import Editor.Package

/-!
# The test kit: Windows

Stand-ins for the window and tab commands a check of the core needs,
written over the core's API (`ViewId.split`, `ViewId.focus`,
`ViewId.arrange`, `ViewId.newTab`, `changeTab`; `Editor/Api.lean`), so a
check whose subject is the core's frame, its layouts or what is kept of
them makes windows and tabs without naming the packages `window-commands`
and `tab-commands`. Each command is registered under a name of the kit's
own, which starts `test-`, so none is taken for a package's.

- **`splitName`**, **`splitVerticallyName`**: a new window above, or left
  of, the call's window, focused.
- **`focusNextName`**: the next window of the frame's list, wrapping,
  focused.
- **`widerName`**, **`zoomName`**, **`edgeLeftName`**, **`floatName`**: one
  arrangement of the call's window (`Arrange`): a column wider, zoomed,
  docked at the left edge, floating.
- **`newTabName`**: a new tab after the tab in view, its one window on the
  call's window's buffer, focused.
- **`nextTabName`**, **`previousTabName`**: the tab after, or before, the
  tab in view, wrapping.

A command the frame refuses gives up with the refusal's sentence
(`orGiveUp`), as a package's does.

`Windows.package` registers them all, as a package named `test-windows`.

It holds no checks. It is pinned by the checks that run on it; what the
packages' own commands do is theirs to check.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import").
-/

namespace Editor.Test.Windows

open Editor

/-- The stand-in that splits the call's window, the new one above. -/
def splitName : String :=
  "test-window-split"

/-- The stand-in that splits the call's window, the new one to the left. -/
def splitVerticallyName : String :=
  "test-window-split-vertically"

/-- The stand-in that focuses the next window of the frame. -/
def focusNextName : String :=
  "test-window-focus-next"

/-- The stand-in that makes the call's window a column wider. -/
def widerName : String :=
  "test-window-wider"

/-- The stand-in that zooms the call's window. -/
def zoomName : String :=
  "test-window-zoom"

/-- The stand-in that docks the call's window at the left edge. -/
def edgeLeftName : String :=
  "test-window-edge-left"

/-- The stand-in that floats the call's window. -/
def floatName : String :=
  "test-window-float"

/-- The stand-in that opens a new tab. -/
def newTabName : String :=
  "test-tab-new"

/-- The stand-in that goes to the next tab. -/
def nextTabName : String :=
  "test-tab-next"

/-- The stand-in that goes to the previous tab. -/
def previousTabName : String :=
  "test-tab-previous"

/-- Splits the call's window by `placement` and focuses the new window. -/
def split (placement : Placement) (call : Call) : EditorM Unit := do
  let made ← orGiveUp (← call.target.window.id.split placement)
  orGiveUp (← made.focus)

/-- Focuses the next window of the frame's list after the call's,
wrapping; nothing where there is none. -/
def focusNext (call : Call) : EditorM Unit := do
  if let some view := (← editorState).cycled call.target.window.id true 0 then
    orGiveUp (← view.focus)

/-- Makes the change `change` on the call's window. -/
def arranging (change : Arrange) (call : Call) : EditorM Unit := do
  orGiveUp (← call.target.window.id.arrange change)

/-- Opens a new tab after the tab in view, its one window on the call's
window's buffer, and focuses it. -/
def newTab (call : Call) : EditorM Unit := do
  let made ← orGiveUp (← call.target.window.id.newTab)
  orGiveUp (← made.focus)

/-- Selects the tab `forward` of the tab in view, or the one before it,
wrapping. -/
def stepTab (forward : Bool) (_ : Call) : EditorM Unit := do
  let frame := (← editorState).frame
  let size := frame.tabs.size
  orGiveUp (← changeTab (.select ((frame.tabIndex + (if forward then 1 else size - 1)) % size)))

/-- The kit's stand-ins for the window and tab commands (the module
docs), as a package named `test-windows`. -/
def package : Package :=
  { name := "test-windows"
    setup := do
      commandWith splitName (split { before := true })
      commandWith splitVerticallyName (split { axis := .columns, before := true })
      commandWith focusNextName focusNext
      commandWith widerName (arranging (.resize .columns true 1))
      commandWith zoomName (arranging .zoom)
      commandWith edgeLeftName (arranging (.edge .left))
      commandWith floatName (arranging .float)
      commandWith newTabName newTab
      commandWith nextTabName (stepTab true)
      commandWith previousTabName (stepTab false) }

end Editor.Test.Windows
