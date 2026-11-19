import Editor.Config.Packages
import Editor.Config.Reload
import Greeting.EditorPackage

/-!
# Model tests: `Greeting.lean`

The tests of the fixture package that need no Rust library, on the state a
host handed its packages starts from (`Config.State.ofPackages`). The test
driver's root, `GreetingTest/Model.lean`, runs them.
-/

namespace GreetingTest

open Editor

/-- The checks of the package `greeting`, each with what must hold as a
sentence. -/
def greetingChecks : List (String × Bool) :=
  let (state, refused) : Config.State Unit × Array String :=
    Config.State.ofPackages Greeting.EditorPackage.packages
  [("the package `greeting` is accepted, alone", refused == #[] && state.packages == #["greeting"]),
    ("it registers `greeting-hello` and `greeting-reply`, in that order",
      state.registry.names == #["greeting-hello", Greeting.replyName]),
    ("each command's owner is `greeting`",
      state.registry.entries.all fun entry => entry.owner.name == "greeting")]

end GreetingTest
