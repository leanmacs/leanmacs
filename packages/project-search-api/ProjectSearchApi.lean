/-!
# The interface package `project-search-api`

The interface package of project search
(`docs/design/extension-points.md`, "Three layers"): the contract between
the default package `project-search`, which implements it, and whatever
reaches project search by its names. A name another package reaches is
part of the contract a replacement must keep, so it is declared here, in
the interface package, and a reacher names the constant, never the text
("Reaches by name"). The default config, which binds `SPC /` and `SPC s p`
to a search and `SPC *` to a search of the word under the cursor
(`config/default/Config/Leader.lean`), is in the core until it moves out,
and the core cannot import a package, so it and the core's tests of it name
the names as text. It registers no behaviour.

Its test library publishes a fake (`ProjectSearchApiTest.fake`) and the
contract check every implementation runs
(`ProjectSearchApiTest.contractChecks`).
-/

namespace ProjectSearchApi

/-- The name the command that searches a workspace's files for a pattern,
into a results buffer, is registered under. -/
def searchName : String :=
  "project-search"

/-- The name the command that searches a workspace's files for the word
under the cursor is registered under. -/
def symbolName : String :=
  "project-search-symbol"

/-- Every name this interface declares: the names an implementation must
register, which the contract check holds it to. -/
def names : Array String :=
  #[searchName, symbolName]

end ProjectSearchApi
