import Editor.Config.Packages
import GreetingApi
import GreetingApiTest.Fake
import GreetingLoud.EditorPackage

/-!
# Model tests: `GreetingLoud.lean`

The tests of the fixture package that need no Rust library, on the state a
host handed packages starts from (`Config.State.ofPackages`). Where another
package registers the name this one reaches, it is the fake of the
interface package `greeting-api` (`GreetingApiTest.fake`), never an
implementation. The test driver's root, `GreetingLoudTest/Model.lean`,
runs them.
-/

namespace GreetingLoudTest

open Editor

/-- The owner of the entry `greeting-reply` runs in the state a host handed
`packages` starts from, when there is one. -/
def replyOwner (packages : Array Package) : Option String :=
  let (state, _) : Config.State Unit Unit × Array String := Config.State.ofPackages packages
  (state.registry.find? GreetingApi.replyName).map (·.owner.name)

/-- The checks of the package `greeting-loud`, each with what must hold as
a sentence. -/
def greetingLoudChecks : List (String × Bool) :=
  let (state, refused) : Config.State Unit Unit × Array String :=
    Config.State.ofPackages GreetingLoud.EditorPackage.packages
  [("the package `greeting-loud` is accepted, alone, and registers `greeting-reply`",
      refused == #[] && state.packages == #["greeting-loud"] &&
        state.registry.names == #[GreetingApi.replyName]),
    ("registered after the fake of `greeting-api`, its `greeting-reply` is the one found",
      replyOwner (#[GreetingApiTest.fake] ++ GreetingLoud.EditorPackage.packages) ==
        some "greeting-loud")]

end GreetingLoudTest
