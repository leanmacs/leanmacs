/-!
# The interface package `window-commands-api`

The interface package of the window commands (`docs/design/extension-points.md`,
"Three layers"): the contract between the default package `window-commands`, which
implements it, and whatever reaches the window commands by name. A name another
package reaches is part of the contract a replacement must keep, so it is
declared here, in the interface package, and a reacher names the constant,
never the text ("Reaches by name"). The Vim scheme's
window table binds them under `C-w` (`Vim.Default.windowKeys`,
`packages/evil/Evil/Vim/Default.lean`), so `evil` requires this package.
The default config, which binds the window commands under its leader
(`config/default/Config/Leader.lean`), is elaborated at run time on
whatever set the editor has, and names them as text, as a user's config
does.
It registers no behaviour.

Its test library publishes a fake (`WindowCommandsApiTest.fake`) and the contract
check every implementation runs (`WindowCommandsApiTest.contractChecks`).
-/

namespace WindowCommandsApi

/-- The name `split` is registered under. -/
def splitName : String :=
  "window-split"

/-- The name `splitVertically` is registered under. -/
def splitVerticallyName : String :=
  "window-split-vertically"

/-- The name `new` is registered under. -/
def newName : String :=
  "window-new"

/-- The name `close` is registered under. -/
def closeName : String :=
  "window-close"

/-- The name `quit` is registered under. -/
def quitName : String :=
  "window-quit"

/-- The name `only` is registered under. -/
def onlyName : String :=
  "window-only"

/-- The name `focusToward .left` is registered under. -/
def leftName : String :=
  "window-focus-left"

/-- The name `focusToward .bottom` is registered under. -/
def downName : String :=
  "window-focus-down"

/-- The name `focusToward .top` is registered under. -/
def upName : String :=
  "window-focus-up"

/-- The name `focusToward .right` is registered under. -/
def rightName : String :=
  "window-focus-right"

/-- The name `focusCycled true` is registered under. -/
def nextName : String :=
  "window-focus-next"

/-- The name `focusCycled false` is registered under. -/
def previousName : String :=
  "window-focus-previous"

/-- The name `focusEnd false` is registered under. -/
def topName : String :=
  "window-focus-top"

/-- The name `focusEnd true` is registered under. -/
def bottomName : String :=
  "window-focus-bottom"

/-- The name `focusLast` is registered under. -/
def lastName : String :=
  "window-focus-last"

/-- The name the exchange is registered under. -/
def exchangeName : String :=
  "window-exchange"

/-- The name the forward rotation is registered under. -/
def rotateName : String :=
  "window-rotate"

/-- The name the backward rotation is registered under. -/
def rotateBackName : String :=
  "window-rotate-back"

/-- The name the balance is registered under. -/
def balanceName : String :=
  "window-balance"

/-- The name growing along rows is registered under. -/
def tallerName : String :=
  "window-taller"

/-- The name shrinking along rows is registered under. -/
def shorterName : String :=
  "window-shorter"

/-- The name growing along columns is registered under. -/
def widerName : String :=
  "window-wider"

/-- The name shrinking along columns is registered under. -/
def narrowerName : String :=
  "window-narrower"

/-- The name the zoom is registered under. -/
def zoomName : String :=
  "window-zoom"

/-- The name the promotion to main is registered under. -/
def promoteName : String :=
  "window-promote"

/-- The name the demotion is registered under. -/
def demoteName : String :=
  "window-demote"

/-- The name one more main window is registered under. -/
def mainMoreName : String :=
  "window-main-more"

/-- The name one fewer main window is registered under. -/
def mainFewerName : String :=
  "window-main-fewer"

/-- The name `arranging fun _ => .edge .left` is registered under. -/
def edgeLeftName : String :=
  "window-edge-left"

/-- The name `arranging fun _ => .edge .bottom` is registered under. -/
def edgeBottomName : String :=
  "window-edge-bottom"

/-- The name `arranging fun _ => .edge .top` is registered under. -/
def edgeTopName : String :=
  "window-edge-top"

/-- The name `arranging fun _ => .edge .right` is registered under. -/
def edgeRightName : String :=
  "window-edge-right"

/-- The name `arranging fun _ => .float` is registered under. -/
def floatName : String :=
  "window-float"

/-- Every name this interface declares: the names an implementation must
register, which the contract check holds it to, in the order
the default package registers them. -/
def names : Array String :=
  #[splitName, splitVerticallyName, newName, closeName, quitName, onlyName, leftName, downName,
    upName, rightName, nextName, previousName, topName, bottomName, lastName, exchangeName,
    rotateName, rotateBackName, balanceName, tallerName, shorterName, widerName, narrowerName,
    zoomName, promoteName, demoteName, mainMoreName, mainFewerName, edgeLeftName, edgeBottomName,
    edgeTopName, edgeRightName, floatName]

end WindowCommandsApi
