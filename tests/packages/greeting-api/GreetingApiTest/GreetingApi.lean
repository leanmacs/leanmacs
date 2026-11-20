import GreetingApiTest.Contract
import GreetingApiTest.Fake

/-!
# Model tests: `GreetingApi.lean`

The tests of the interface package's names, its fake and its contract
check. The test driver's root, `GreetingApiTest/Model.lean`, runs them.
-/

namespace GreetingApiTest

open Editor

/-- Whether every check of the contract over `package` holds. -/
def keeps (package : Package) : Bool :=
  (contractChecks package).all (·.2)

/-- The checks of `greeting-api`, each with what must hold as a
sentence. -/
def greetingApiChecks : List (String × Bool) :=
  [("the name `greeting-reply` is the one the interface declares",
      GreetingApi.replyName == "greeting-reply" && GreetingApi.names == #["greeting-reply"]),
    ("the fake keeps the contract: every check of it holds", keeps fake),
    ("a package that registers nothing fails the contract, with the check for `greeting-reply` false",
      let missing : Package := { name := "missing", setup := pure () }
      !keeps missing &&
        (contractChecks missing).any fun (sentence, held) =>
          !held && (sentence.splitOn "`greeting-reply`").length > 1),
    ("a package that registers the name misspelt fails the contract",
      !keeps
          { name := "misspelt"
            setup := Editor.command "greeting-replies" (Editor.message "misspelt") })]

end GreetingApiTest
