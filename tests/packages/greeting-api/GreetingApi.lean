/-!
# The fixture interface package `greeting-api`

An interface package, used by tests alone
(`docs/design/extension-points.md`, "Three layers"): the contract between
the fixture package `greeting`, which implements it, and `greeting-loud`,
which reaches a command by a name declared here. A name another package
reaches is part of the contract a replacement must keep, so it is declared
here, in the interface package, and a reacher names the constant, never the
text ("Reaches by name"). It registers no behaviour.

Its test library publishes a fake (`GreetingApiTest.fake`) and the contract
check every implementation runs (`GreetingApiTest.contractChecks`).
-/

namespace GreetingApi

/-- The name of the command `greeting` registers and `greeting-loud`
reaches. -/
def replyName : String :=
  "greeting-reply"

/-- Every name this interface declares: the names an implementation must
register, which the contract check holds it to. -/
def names : Array String :=
  #[replyName]

end GreetingApi
