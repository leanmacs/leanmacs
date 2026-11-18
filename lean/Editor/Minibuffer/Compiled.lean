import Editor.Config.Registry
import Editor.Minibuffer

/-!
# The minibuffer's commands and its mode, as compiled code registers them

What a host is handed so that a prompt can be answered
(`Editor/Minibuffer.lean`): the registrations of its commands, and the
mode. A host registers both for the owner `compiled` when its loop starts,
before any config (`Editor/Config/Registry.lean`, "Compiled commands"), so
they hold when config fails to load, and a reload does not replace them.

- **`Minibuffer.commands`**: `minibuffer-accept`, `minibuffer-cancel`,
  `minibuffer-next`, `minibuffer-previous`, `minibuffer-insert`,
  `minibuffer-delete-backward`,
  `minibuffer-delete-to-start`, `minibuffer-ask` and
  `minibuffer-candidates`, in that order,
  each a command that is given what it was called with (`Action.call`):
  each acts on the open prompt, and the last two read their arguments.
- **`Minibuffer.modes`**: the one mode, `minibuffer`, which the
  minibuffer's buffer is made with.

A host that is not handed them still opens prompts: the minibuffer's mode
then contributes nothing, and nothing accepts, cancels or chooses a
candidate but a command that calls `acceptPrompt`, `cancelPrompt` or
`chooseCandidate` itself.

This module is apart from `Editor/Minibuffer.lean` because it names the
registry, which is the config session's: `Editor.lean` imports the
commands, so that config can call them, and not this.

Pinned by `ModelTest.promptChecks`, on the models, and by
`ConfigTest.promptChecks`, through the headless host.
-/

namespace Editor.Minibuffer

/-- The minibuffer's commands, as a host registers them for the owner
`compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := acceptName, action := .call acceptCommand },
    { name := cancelName, action := .call cancelCommand },
    { name := nextName, action := .call nextCommand },
    { name := previousName, action := .call previousCommand },
    { name := insertName, action := .call insertCommand },
    { name := deleteBackwardName, action := .call deleteBackwardCommand },
    { name := deleteToStartName, action := .call deleteToStartCommand },
    { name := askName, action := .call askCommand },
    { name := candidatesName, action := .call candidatesCommandOf }]

/-- The minibuffer's mode, as a host registers it for the owner
`compiled`. -/
def modes : Array Mode :=
  #[mode]

end Editor.Minibuffer
