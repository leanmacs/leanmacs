import Editor.Config.Registry
import Editor.Ex

/-!
# The ex line's commands and the ex names that ship, as compiled code registers them

What a host is handed so that it has the ex command line (`Editor/Ex.lean`):
the registrations of its commands, and the ex bindings that ship. A host
registers both for the owner `compiled` when its loop starts, before any
config (`Editor/Config/Registry.lean`, "Compiled commands", "Ex bindings"),
so they hold when config fails to load, a reload does not replace them, and
config's binding of a shipped ex name runs in its place until a reload
drops it.

- **`Ex.commands`**: `ex`, a command that is given what it was called with
  (`Action.call`): it opens the ex line, and runs the line it is answered
  (`Ex.exCommand`). A host must be handed the minibuffer's commands too
  (`Editor/Minibuffer/Compiled.lean`) for that prompt to be answered.
- **`Ex.bindings`**: the ex names that ship. None yet.

This module is apart from `Editor/Ex.lean` because it names the registry,
which is the config session's: `Editor.lean` imports the commands, so that
config can call them, and not this.

Pinned by `ModelTest.exChecks`, on the models.
-/

namespace Editor.Ex

/-- The ex line's commands, as a host registers them for the owner
`compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := name, action := .call exCommand }]

/-- The ex names that ship, as a host registers them for the owner
`compiled`. -/
def bindings : Array Binding :=
  #[]

end Editor.Ex
