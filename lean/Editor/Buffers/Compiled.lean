import Editor.Buffers
import Editor.Extension
import Editor.Package

/-!
# The `buffers` package: the buffer commands

What a host registers so that it has the buffer commands
(`Editor/Buffers.lean`): the package `buffers` (`Buffers.package`,
`Editor/Package.lean`), whose `setup` registers them and the buffer source.
A host registers it for the owner `buffers` when its loop starts, before
any config (`Editor/Config/Packages.lean`).

- **The commands**: `switch-buffer`, `list-buffers` and
  `close-buffer`, each a command that is given what it was called with
  (`commandWith`).
  - `switch-buffer` shows the buffer its first argument, a string, names,
    exactly or by fuzzy match, in the window it was called with
    (`Buffers.switchCommand`). With no string it asks with a prompt whose
    candidates are the open buffers' names, and whose continuation is
    `switch-buffer` itself. A host must be handed the minibuffer's
    commands too (`packages/minibuffer/Minibuffer/Compiled.lean`) for that prompt to be
    answered.
  - `list-buffers` shows the buffer list, a text view of the open buffers
    (`Buffers.listCommand`).
  - `close-buffer` closes the buffer its first argument names, or the
    buffer of the window it was called with, unless it has unsaved changes
    (`Buffers.closeCommand`).
  - The ex names `b`, `ls` and `bd` are bound to these three
    (`Editor/Ex/Compiled.lean`).

- **The source**: the buffer completion source, so config can ask for it
  by name.
- **The value** of the interface library `buffers-api`'s choice
  `BuffersApi.Buffers`, named `buffers`: `close`, which version control's
  commit closes its message buffer with.

This module is apart from `Editor/Buffers.lean` because it is what a host
is handed, not what config calls: `Editor.lean` imports the commands, so
that config calls them, and not this.

Pinned by `ModelTest.bufferCommandChecks`, on the models, and by
`ConfigTest.shippedChecks`, which reads what the hosts are handed.
-/

namespace Editor.Buffers

/-- The package `buffers`: the buffer commands and the buffer completion
source. -/
def package : Package :=
  { name := "buffers"
    setup := do
      Extension.add ({ name := BuffersApi.implementationName, close } : BuffersApi.Buffers)
      commandWith switchName switchCommand
      commandWith listName listCommand
      commandWith closeName closeCommand
      defineSource source }

end Editor.Buffers
