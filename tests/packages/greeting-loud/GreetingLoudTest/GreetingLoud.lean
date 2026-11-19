import Editor.Config.Packages
import Greeting.EditorPackage
import GreetingLoud.EditorPackage

/-!
# Model tests: `GreetingLoud.lean`

The tests of the fixture package that need no Rust library, on the state a
host handed packages starts from (`Config.State.ofPackages`). The test
driver's root, `GreetingLoudTest/Model.lean`, runs them.
-/

namespace GreetingLoudTest

open Editor

/-- The owner of the entry `greeting-reply` runs in the state a host handed
`packages` starts from, when there is one. -/
def replyOwner (packages : Array Package) : Option String :=
  let (state, _) : Config.State Unit Unit × Array String := Config.State.ofPackages packages
  (state.registry.find? Greeting.replyName).map (·.owner.name)

/-- The checks of the package `greeting-loud`, each with what must hold as
a sentence. -/
def greetingLoudChecks : List (String × Bool) :=
  let (state, refused) : Config.State Unit Unit × Array String :=
    Config.State.ofPackages GreetingLoud.EditorPackage.packages
  [("the package `greeting-loud` is accepted, alone, and registers `greeting-reply`",
      refused == #[] && state.packages == #["greeting-loud"] &&
        state.registry.names == #[Greeting.replyName]),
    ("registered after `greeting`'s packages, its `greeting-reply` is the one found",
      replyOwner (Greeting.EditorPackage.packages ++ GreetingLoud.EditorPackage.packages) ==
        some "greeting-loud"),
    ("its reply is not `greeting`'s", GreetingLoud.replyText != Greeting.replyText)]

end GreetingLoudTest
