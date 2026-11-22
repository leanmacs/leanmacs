/-!
# The interface package `working-set-api`

The interface package of the working sets
(`docs/design/extension-points.md`, "Three layers"): the contract between
the default package `working-set`, which implements it, and whatever
reaches the working sets by their names. A name another package reaches is
part of the contract a replacement must keep, so it is declared here, in
the interface package, and a reacher names the constant, never the text
("Reaches by name"). The default config, which binds `SPC k a` to adding a
range and `SPC k o` and `SPC RET` to opening a set
(`config/default/Config/Leader.lean`), is in the core until it moves out,
and the core cannot import a package, so it and the core's tests of it name
the names as text. It registers no behaviour.

Its test library publishes a fake (`WorkingSetApiTest.fake`) and the
contract check every implementation runs (`WorkingSetApiTest.contractChecks`).
-/

namespace WorkingSetApi

/-- The name the command that adds the selected lines, or the cursor's
line, of a file buffer to a named working set is registered under. -/
def addName : String :=
  "working-set-add"

/-- The name the command that opens a named working set's buffer is
registered under. -/
def openName : String :=
  "working-set-open"

/-- Every name this interface declares: the names an implementation must
register, which the contract check holds it to. -/
def names : Array String :=
  #[addName, openName]

end WorkingSetApi
