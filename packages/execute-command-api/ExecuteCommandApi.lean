/-!
# The interface package `execute-command-api`

The interface package of the command prompt
(`docs/design/extension-points.md`, "Three layers"): the contract between
the default package `execute-command`, which implements it, and whatever
reaches the command prompt by its name. A name another package reaches is
part of the contract a replacement must keep, so it is declared here, in
the interface package, and a reacher names the constant, never the text
("Reaches by name"). The default config, which binds `SPC :` to the
command prompt (`config/default/Config/Leader.lean`), is in the core until
it moves out, and the core cannot import a package, so it and the core's
tests of it name the name as text. It registers no behaviour.

Its test library publishes a fake (`ExecuteCommandApiTest.fake`) and the
contract check every implementation runs
(`ExecuteCommandApiTest.contractChecks`).
-/

namespace ExecuteCommandApi

/-- The name the command prompt is registered under: the command that asks
for a registered command's name and runs it. -/
def executeCommandName : String :=
  "execute-command"

/-- Every name this interface declares: the names an implementation must
register, which the contract check holds it to. -/
def names : Array String :=
  #[executeCommandName]

end ExecuteCommandApi
