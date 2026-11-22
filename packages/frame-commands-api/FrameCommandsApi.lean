/-!
# The interface package `frame-commands-api`

The interface package of the frame commands (`docs/design/extension-points.md`,
"Three layers"): the contract between the default package `frame-commands`, which
implements it, and whatever reaches the frame commands by name. A name another
package reaches is part of the contract a replacement must keep, so it is
declared here, in the interface package, and a reacher names the constant,
never the text ("Reaches by name"). The default package
`menu` names them: its Window menu's Minimise and Enter Full Screen run
them (`packages/menu/Menu/Compiled.lean`), so `menu` requires this
package.
It registers no behaviour.

Its test library publishes a fake (`FrameCommandsApiTest.fake`) and the contract
check every implementation runs (`FrameCommandsApiTest.contractChecks`).
-/

namespace FrameCommandsApi

/-- The name of the command that enters or leaves the system's fullscreen. -/
def toggleFullscreenName : String :=
  "toggle-fullscreen"

/-- The name of the command that minimises the window. -/
def minimiseName : String :=
  "minimise-window"

/-- Every name this interface declares: the names an implementation must
register, which the contract check holds it to, in the order
the default package registers them. -/
def names : Array String :=
  #[toggleFullscreenName, minimiseName]

end FrameCommandsApi
