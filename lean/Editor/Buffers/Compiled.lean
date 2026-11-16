import Editor.Buffers
import Editor.Config.Registry

/-!
# The buffer commands, as compiled code registers them

What a host is handed so that it has the buffer commands
(`Editor/Buffers.lean`): their registrations. A host registers them for the
owner `compiled` when its loop starts, before any config
(`Editor/Config/Registry.lean`, "Compiled commands").

- **`Buffers.commands`**: `switch-buffer`, `list-buffers` and
  `close-buffer`, each a command that is given what it was called with
  (`Action.call`).
  - `switch-buffer` shows the buffer its first argument, a string, names,
    exactly or by fuzzy match, in the window it was called with
    (`Buffers.switchCommand`). With no string it asks with a prompt whose
    candidates are the open buffers' names, and whose continuation is
    `switch-buffer` itself. A host must be handed the minibuffer's
    commands too (`Editor/Minibuffer/Compiled.lean`) for that prompt to be
    answered.
  - `list-buffers` shows the buffer list, a text view of the open buffers
    (`Buffers.listCommand`).
  - `close-buffer` closes the buffer its first argument names, or the
    buffer of the window it was called with, unless it has unsaved changes
    (`Buffers.closeCommand`).
  - The ex names `b`, `ls` and `bd` are bound to these three
    (`Editor/Ex/Compiled.lean`).

This module is apart from `Editor/Buffers.lean` because it names the
registry, which is the config session's: `Editor.lean` imports the
commands, so that config calls them, and not this.

Pinned by `ModelTest.bufferCommandChecks`, on the models, and by
`ConfigTest.shippedChecks`, which reads what the hosts are handed.
-/

namespace Editor.Buffers

/-- The buffer commands, as a host registers them for the owner
`compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := switchName, action := .call switchCommand },
    { name := listName, action := .call listCommand },
    { name := closeName, action := .call closeCommand }]

end Editor.Buffers
