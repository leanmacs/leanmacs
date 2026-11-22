import Editor.Package
import Minibuffer

/-!
# The `minibuffer` package: the minibuffer's commands and its mode

What a host registers so that a prompt can be answered
(`Minibuffer.lean`): the package `minibuffer` (`Minibuffer.package`, the
core's `lean/Editor/Package.lean`), whose `setup` registers the
minibuffer's commands and its mode, under the names the interface package
`minibuffer-api` declares. A host registers it for the owner `minibuffer`
when its loop starts, before any config (the core's
`lean/Editor/Config/Packages.lean`), so they hold when config fails to
load, and a reload does not replace them.

- **The commands**: `minibuffer-accept`, `minibuffer-cancel`,
  `minibuffer-next`, `minibuffer-previous`, `minibuffer-insert`,
  `minibuffer-delete-backward`,
  `minibuffer-delete-to-start`, `minibuffer-ask` and
  `minibuffer-candidates`, in that order,
  each a command that is given what it was called with (`commandWith`):
  each acts on the open prompt, and the last two read their arguments.
- **The mode**: the one mode, `minibuffer`, which the minibuffer's buffer
  is made with.

A host that is not handed the package still opens prompts: the minibuffer's
mode then contributes nothing, and nothing accepts, cancels or chooses a
candidate but a command that calls `acceptPrompt`, `cancelPrompt` or
`chooseCandidate` itself.

This module is apart from `Minibuffer.lean` because it is what a host is
handed, not what config calls: config names the commands with `import
Minibuffer`, a module of the set's base through the entry module
(`Minibuffer/EditorPackage.lean`), which imports this one.

Pinned by `MinibufferTest.promptModeChecks`, on the models, by
`MinibufferTest.minibufferPackageChecks`, the contract check of
`minibuffer-api` over `package`, and through the editor by the package's
headless fixtures `prompt` and `candidates`. The core's own tests of
prompts (`ModelTest.promptChecks`, `ConfigTest.promptChecks`) run on the
core's test kit's minibuffer (`lean/Editor/Test/Minibuffer.lean`).
-/

namespace Editor.Minibuffer

/-- The package `minibuffer`: the minibuffer's commands and its mode. -/
def package : Package :=
  { name := "minibuffer"
    setup := do
      commandWith acceptName acceptCommand
      commandWith cancelName cancelCommand
      commandWith nextName nextCommand
      commandWith previousName previousCommand
      commandWith insertName insertCommand
      commandWith deleteBackwardName deleteBackwardCommand
      commandWith deleteToStartName deleteToStartCommand
      commandWith askName askCommand
      commandWith candidatesName candidatesCommandOf
      defineMode mode }

end Editor.Minibuffer
