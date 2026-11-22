/-!
# The interface package `binding-search-api`

The interface package of the binding search
(`docs/design/extension-points.md`, "Three layers"): the contract between
the default package `binding-search`, which implements it, and whatever
reaches the binding search by its name. A name another package reaches is
part of the contract a replacement must keep, so it is declared here, in
the interface package, and a reacher names the constant, never the text
("Reaches by name"). The default config, which binds `SPC ?` to the
binding search (`config/default/Config/Leader.lean`), is in the core until
it moves out, and the core cannot import a package, so it and the core's
tests of it name the name as text. It registers no behaviour.

Its test library publishes a fake (`BindingSearchApiTest.fake`) and the
contract check every implementation runs
(`BindingSearchApiTest.contractChecks`).
-/

namespace BindingSearchApi

/-- The name the binding search is registered under: the command that asks
for one of the key bindings the input scheme reaches and runs it as its
key would. -/
def searchBindingsName : String :=
  "search-bindings"

/-- Every name this interface declares: the names an implementation must
register, which the contract check holds it to. -/
def names : Array String :=
  #[searchBindingsName]

end BindingSearchApi
