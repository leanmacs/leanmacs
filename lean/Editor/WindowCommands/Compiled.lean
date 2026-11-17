import Editor.Config.Registry
import Editor.WindowCommands

/-!
# The window commands, as compiled code registers them

What a host is handed so that the frame's windows can be split, closed,
focused and arranged (`Editor/WindowCommands.lean`): the registrations of
the window commands, each a command of its call (`.call`), so it acts on
the call's window and reads the count the call carries. A host registers
them for the owner `compiled` when its loop starts, before any config
(`Editor/Config/Registry.lean`, "Compiled commands"), so they hold when
config fails to load, and config can call them and bind keys to them.
`Headless.shippedOver` registers them for both hosts.

- **`WindowCommands.commands`**: every window command, under its name. No
  binding comes with them here: the Vim scheme binds them under `C-w`
  (`Vim.Default.windowKeys`), and a config that wants them in every state
  binds that table with `bindKey`.

This module is apart from `Editor/WindowCommands.lean` because it names the
registry, which is the config session's.

Pinned by `ModelTest.windowCommandChecks`, on the models.
-/

namespace Editor.WindowCommands

/-- The window commands, as a host registers them for the owner
`compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := splitName, action := .call split },
    { name := splitVerticallyName, action := .call splitVertically },
    { name := newName, action := .call new }, { name := closeName, action := .call close },
    { name := quitName, action := .call quit }, { name := onlyName, action := .call only },
    { name := leftName, action := .call (focusToward .left) },
    { name := downName, action := .call (focusToward .bottom) },
    { name := upName, action := .call (focusToward .top) },
    { name := rightName, action := .call (focusToward .right) },
    { name := nextName, action := .call (focusCycled true) },
    { name := previousName, action := .call (focusCycled false) },
    { name := topName, action := .call (focusEnd false) },
    { name := bottomName, action := .call (focusEnd true) },
    { name := lastName, action := .call focusLast },
    { name := exchangeName, action := .call (arranging exchange) },
    { name := rotateName, action := .call (arranging fun _ => .rotate true) },
    { name := rotateBackName, action := .call (arranging fun _ => .rotate false) },
    { name := balanceName, action := .call (arranging fun _ => .balance) },
    { name := tallerName,
      action := .call (arranging fun count => .resize .rows true (steps count)) },
    { name := shorterName,
      action := .call (arranging fun count => .resize .rows false (steps count)) },
    { name := widerName,
      action := .call (arranging fun count => .resize .columns true (steps count)) },
    { name := narrowerName,
      action := .call (arranging fun count => .resize .columns false (steps count)) },
    { name := zoomName, action := .call (arranging fun _ => .zoom) },
    { name := promoteName, action := .call (arranging fun _ => .promote) },
    { name := demoteName, action := .call (arranging fun _ => .demote) },
    { name := mainMoreName,
      action := .call (arranging fun count => .mainCount true (steps count)) },
    { name := mainFewerName,
      action := .call (arranging fun count => .mainCount false (steps count)) },
    { name := edgeLeftName, action := .call (arranging fun _ => .edge .left) },
    { name := edgeBottomName, action := .call (arranging fun _ => .edge .bottom) },
    { name := edgeTopName, action := .call (arranging fun _ => .edge .top) },
    { name := edgeRightName, action := .call (arranging fun _ => .edge .right) }]

end Editor.WindowCommands
