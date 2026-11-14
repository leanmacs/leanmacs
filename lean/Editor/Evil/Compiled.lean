import Editor.Config.Registry
import Editor.Evil
import Editor.Evil.Motions
import Editor.InputScheme.Vim

/-!
# Evil's commands, as compiled code registers them

What a host is handed so that the Vim scheme's keys do something
(`Editor/Evil.lean`): the registrations of the commands its invocations
name. A host registers them for the owner `compiled` when its loop starts,
before any config (`Editor/Config/Registry.lean`, "Compiled commands"), so
they hold when config fails to load, and a reload does not replace them.

- **`Evil.commands`**, each a command that is given what it was called with
  (`Action.call`):

  | Name | Runs |
  |---|---|
  | `move` (`Vim.moveCommand`) | `Evil.move` over the compiled vocabulary, `Evil.motions` |

A name here and the name the Vim scheme's default tables give a key
(`Editor/InputScheme/Vim/Default.lean`) are changed together: the scheme
yields an invocation of a name, and this is where the name is given a
command.

This module is apart from `Editor/Evil.lean` because it names the registry,
which is the config session's: `Editor.lean` imports the commands, so that
config can call them, and not this.

Pinned by `ModelTest.evilMotionChecks`, on the models.
-/

namespace Editor.Evil

/-- Evil's commands, as a host registers them for the owner `compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := Vim.moveCommand, action := .call (move motions) }]

end Editor.Evil
