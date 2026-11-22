import Editor.Quit

/-!
# The interface package `ex-api`

The interface package of the ex command line
(`docs/design/extension-points.md`, "Three layers"): the contract between
the default package `ex`, which implements it, and whatever reaches the ex
line by name. A name another package reaches is part of the contract a
replacement must keep, so it is declared here, in the interface package,
and a reacher names the constant, never the text ("Reaches by name"). The
default package `evil` names `name`: the Vim scheme binds `:` to the ex
command (`packages/evil/Evil/Vim/Default.lean`), so `evil` requires this
package.

- **`name`** (`ex`) is the command that asks for a line and runs it.
- **`quitName`** (`quit`) is the command the ex name `q` runs. The name is
  the core's (`Editor.Quit.name`, `lean/Editor/Quit.lean`): the loop runs
  the command registered under it for the system's quit, and the frame
  commands' `s-q` and the window commands' `window-quit` name it. It is
  declared here too because the ex line's implementation is what registers
  it in the default set, so a replacement of `ex` must.

Beside the names, the contract holds an implementation to what other
packages rely on of the command `ex` (`ExApiTest/Contract.lean`): handed a
line whose name is bound, it runs the bound command with the rest of the
line; handed a bang line, it runs `shell-api`'s `shell-command` with the
text and the line; handed no line, it asks for one, with itself as the
continuation. It registers no behaviour.

Its test library publishes a fake (`ExApiTest.fake`) and the contract
check every implementation runs (`ExApiTest.contractChecks`).
-/

namespace ExApi

/-- The name of the command that asks for an ex line and runs it. -/
def name : String :=
  "ex"

/-- The name of the command that asks the editor to quit, which the ex
name `q` runs: the core's (`Editor.Quit.name`). -/
def quitName : String :=
  Editor.Quit.name

/-- Every name this interface declares: the names an implementation must
register, which the contract check holds it to, in the order the default
package registers them. -/
def names : Array String :=
  #[name, quitName]

end ExApi
