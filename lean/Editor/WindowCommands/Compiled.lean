import Editor.Package
import Editor.WindowCommands

/-!
# The `window-commands` package: the window commands

What a host registers so that the frame's windows can be split, closed,
focused and arranged (`Editor/WindowCommands.lean`): the package
`window-commands` (`WindowCommands.package`, `Editor/Package.lean`), whose
`setup` registers the window commands, each a command of its call
(`commandWith`), so it acts on the call's window and reads the count the
call carries. A host registers it for the owner `window-commands` when its
loop starts, before any config (`Editor/Config/Packages.lean`), so they
hold when config fails to load, and config can call them and bind keys to
them. Both of the executable's hosts are handed it
(`PackageSet.lean`).

- **The commands**: every window command, under its name. No
  binding comes with them here: the Vim scheme binds them under `C-w`
  (`Vim.Default.windowKeys`), and a config that wants them in every state
  binds that table with `bindKey`.

This module is apart from `Editor/WindowCommands.lean` because it is what a
host is handed, not what config calls.

Pinned by `ModelTest.windowCommandChecks`, on the models.
-/

namespace Editor.WindowCommands

/-- The package `window-commands`: every window command, under its name. -/
def package : Package :=
  { name := "window-commands"
    setup := do
      commandWith splitName split
      commandWith splitVerticallyName splitVertically
      commandWith newName new
      commandWith closeName close
      commandWith quitName quit
      commandWith onlyName only
      commandWith leftName (focusToward .left)
      commandWith downName (focusToward .bottom)
      commandWith upName (focusToward .top)
      commandWith rightName (focusToward .right)
      commandWith nextName (focusCycled true)
      commandWith previousName (focusCycled false)
      commandWith topName (focusEnd false)
      commandWith bottomName (focusEnd true)
      commandWith lastName focusLast
      commandWith exchangeName (arranging exchange)
      commandWith rotateName (arranging fun _ => .rotate true)
      commandWith rotateBackName (arranging fun _ => .rotate false)
      commandWith balanceName (arranging fun _ => .balance)
      commandWith tallerName (arranging fun count => .resize .rows true (steps count))
      commandWith shorterName (arranging fun count => .resize .rows false (steps count))
      commandWith widerName (arranging fun count => .resize .columns true (steps count))
      commandWith narrowerName (arranging fun count => .resize .columns false (steps count))
      commandWith zoomName (arranging fun _ => .zoom)
      commandWith promoteName (arranging fun _ => .promote)
      commandWith demoteName (arranging fun _ => .demote)
      commandWith mainMoreName (arranging fun count => .mainCount true (steps count))
      commandWith mainFewerName (arranging fun count => .mainCount false (steps count))
      commandWith edgeLeftName (arranging fun _ => .edge .left)
      commandWith edgeBottomName (arranging fun _ => .edge .bottom)
      commandWith edgeTopName (arranging fun _ => .edge .top)
      commandWith edgeRightName (arranging fun _ => .edge .right)
      commandWith floatName (arranging fun _ => .float) }

end Editor.WindowCommands
