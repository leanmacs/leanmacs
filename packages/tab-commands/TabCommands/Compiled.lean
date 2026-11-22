import Editor.Package
import TabCommands

/-!
# The `tab-commands` package: the tab commands

What a host registers so that the frame's tabs can be opened, closed,
selected, renamed and moved (`TabCommands.lean`): the package
`tab-commands` (`TabCommands.package`, `lean/Editor/Package.lean`), whose
`setup` registers the tab commands, each a command of its call
(`commandWith`), so it acts on the tab of the call's window and reads the
count the call carries, and the tab completion source. A host registers it
for the owner `tab-commands` when its loop starts, before any config
(`lean/Editor/Config/Packages.lean`), so they hold when config fails to
load, and config can call them and bind keys to them. Both of the
executable's hosts are handed it, through the entry module of the Lake
package `tab-commands` (`TabCommands/EditorPackage.lean`).

- **The commands**: every tab command, under its name. No binding
  comes with them here: the Vim scheme binds them under `C-w` with tmux's
  keys (`Vim.Default.tabKeys`), and a config that wants them in every state
  binds that table with `bindKey`. `tab-rename` and the moves have no
  default key.

This module is apart from `TabCommands.lean` because it is what a host is
handed, not what config calls.

Pinned by `TabCommandsTest.tabCommandChecks`, on the models.
-/

namespace Editor.TabCommands

/-- The package `tab-commands`: every tab command, under its name, the nine
that select a tab by its number among them, and the tab completion
source. -/
def package : Package :=
  { name := "tab-commands"
    setup := do
      commandWith newName new
      commandWith closeName close
      commandWith nextName next
      commandWith previousName previous
      commandWith switchName switch
      commandWith renameName rename
      commandWith moveRightName (moveBy true)
      commandWith moveLeftName (moveBy false)
      for index in List.range 9 do
        commandWith (selectName (index + 1)) (selectNumbered (index + 1))
      defineSource source }

end Editor.TabCommands
