import Editor.Config.Registry
import Editor.TabCommands

/-!
# The tab commands, as compiled code registers them

What a host is handed so that the frame's tabs can be opened, closed,
selected, renamed and moved (`Editor/TabCommands.lean`): the registrations
of the tab commands, each a command of its call (`.call`), so it acts on
the tab of the call's window and reads the count the call carries. A host
registers them for the owner `compiled` when its loop starts, before any
config (`Editor/Config/Registry.lean`, "Compiled commands"), so they hold
when config fails to load, and config can call them and bind keys to them.
`Headless.shippedOver` registers them for both hosts.

- **`TabCommands.commands`**: every tab command, under its name. No binding
  comes with them here: the Vim scheme binds them under `C-w` with tmux's
  keys (`Vim.Default.tabKeys`), and a config that wants them in every state
  binds that table with `bindKey`. `tab-rename` and the moves have no
  default key.

This module is apart from `Editor/TabCommands.lean` because it names the
registry, which is the config session's.

Pinned by `ModelTest.tabCommandChecks`, on the models.
-/

namespace Editor.TabCommands

/-- The tab commands, as a host registers them for the owner `compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := newName, action := .call new }, { name := closeName, action := .call close },
      { name := nextName, action := .call next },
      { name := previousName, action := .call previous },
      { name := switchName, action := .call switch },
      { name := renameName, action := .call rename },
      { name := moveRightName, action := .call (moveBy true) },
      { name := moveLeftName, action := .call (moveBy false) }] ++
    (Array.range 9).map fun index =>
      { name := selectName (index + 1), action := .call (selectNumbered (index + 1)) }

/-- The tab completion source, as a host registers it for the owner
`compiled`, so config can ask for it by name. -/
def sources : Array Completion.Source :=
  #[source]

end Editor.TabCommands
