import Editor.Config.Registry
import Editor.ExecuteCommand

/-!
# The command prompt, as compiled code registers it

What a host is handed so that it has the command prompt
(`Editor/ExecuteCommand.lean`). A host registers it for the owner
`compiled` when its loop starts, before any config
(`Editor/Config/Registry.lean`, "Compiled commands"), so it holds when
config fails to load and a reload does not replace it.

- **`ExecuteCommand.commands`**: `execute-command`, a command that is given
  what it was called with (`Action.call`), which runs the command its
  string names or asks for one among the registered ones
  (`ExecuteCommand.executeCommand`). A host must be handed the minibuffer's
  commands too (`Editor/Minibuffer/Compiled.lean`) for that prompt to be
  answered.
- **`ExecuteCommand.sources`**: the completion source of the registered
  commands' names (`ExecuteCommand.source`), so config can ask for it by
  name.

This module is apart from `Editor/ExecuteCommand.lean` because it names the
registry, which is the config session's: `Editor.lean` imports the command,
so that config can call it, and not this.

Pinned by `ModelTest.executeCommandChecks` and `ConfigTest.shippedChecks`.
-/

namespace Editor.ExecuteCommand

/-- The command prompt, as a host registers it for the owner `compiled`. -/
def commands : Array Config.Registration :=
  #[{ name, action := .call executeCommand }]

/-- The command completion source, as a host registers it for the owner
`compiled`, so config can ask for it by name. -/
def sources : Array Completion.Source :=
  #[source]

end Editor.ExecuteCommand
