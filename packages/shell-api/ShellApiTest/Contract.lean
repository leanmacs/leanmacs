import Editor.Config.Packages
import Editor.Test.Hosted
import ShellApi

/-!
# The contract check of `shell-api`

What every implementation of the interface library `shell-api`
(`ShellApi.lean`) runs over its package, in two parts.

- **What it registers**, collected with the pure collector
  (`Package.registered`): a command under each name the interface declares,
  and the codec of the history's store (`Shell.historyStore`), so the
  history is kept across a restart.
- **What it does**, on the loop's driver over the models with the package
  installed as a host installs it (`Editor.Test.hostedDriver`): after
  `shell-command` with a shell text and its ex line, the history of the
  window's buffer's scope holds that line first (`Shell.history`), as the
  ex prompt offers it.

It is a list of sentences, each with whether it holds, as the fixture
interface package `greeting-api`'s (`tests/packages/greeting-api`).
-/

namespace ShellApiTest

open Editor
open Editor.Test

/-- The ex line the contract runs `shell-command` with, and its shell text. -/
def contractLine : String × String :=
  ("!echo contract", "echo contract")

/-- The checks of the contract over `package`, each with what must hold as a
sentence. -/
def contractChecks (package : Package) : List (String × Bool) :=
  let registered := Package.registered package
  let commands := registered.commands.map (·.name)
  let (line, text) := contractLine
  let ran :=
    (hostedDriver #[package]).map fun driver =>
      hostedRan driver { command := ShellApi.commandName, arguments := [.str text, .str line] }
  (ShellApi.names.toList.map fun name =>
      (s!"`{package.name}` registers a command under `{name}`, a name `shell-api` declares",
        commands.contains name)) ++
    [(s!"`{package.name}` registers the codec of the store `{Shell.historyStore.name}`, so the history is kept across a restart",
        registered.codecs.any (·.name == Shell.historyStore.name)),
      (s!"after `{ShellApi.commandName}` of `{package.name}` with a line, the history holds that line first, in the scope of the window's buffer",
        ran.any fun driver =>
          (Shell.history driver.loop.state
                (driver.loop.state.window? ⟨0⟩ |>.map (·.buffer) |>.getD ⟨0⟩))[0]? ==
            some line)]

end ShellApiTest
