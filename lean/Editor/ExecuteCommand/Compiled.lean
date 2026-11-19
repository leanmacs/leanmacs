import Editor.ExecuteCommand
import Editor.Package

/-!
# The `execute-command` package: the command prompt

What a host registers so that it has the command prompt
(`Editor/ExecuteCommand.lean`): the package `execute-command`
(`ExecuteCommand.package`, `Editor/Package.lean`). A host registers it for
the owner `execute-command` when its loop starts, before any config
(`Editor/Config/Packages.lean`), so it holds when config fails to load and
a reload does not replace it.

- **The command**: `execute-command`, a command that is given
  what it was called with (`commandWith`), which runs the command its
  string names or asks for one among the registered ones
  (`ExecuteCommand.executeCommand`). A host must be handed the minibuffer's
  package too (`Editor/Minibuffer/Compiled.lean`) for that prompt to be
  answered.
- **The source**: the completion source of the registered
  commands' names (`ExecuteCommand.source`), so config can ask for it by
  name.

This module is apart from `Editor/ExecuteCommand.lean` because it is what a
host is handed, not what config calls: `Editor.lean` imports the command,
so that config can call it, and not this.

Pinned by `ModelTest.executeCommandChecks` and `ConfigTest.shippedChecks`.
-/

namespace Editor.ExecuteCommand

/-- The package `execute-command`: the command prompt and the completion
source of the registered commands' names. -/
def package : Package :=
  { name := "execute-command"
    setup := do
      commandWith name executeCommand
      defineSource source }

end Editor.ExecuteCommand
