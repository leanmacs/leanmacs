import BindingSearchApiTest.Contract
import BindingSearchApiTest.Fake

/-!
# Model tests: `BindingSearchApi.lean`

The tests of the interface package's names, its fake and its contract
check. The test driver's root, `BindingSearchApiTest/Model.lean`, runs
them.
-/

namespace BindingSearchApiTest

open Editor

/-- Whether every check of the contract over `package` holds. -/
def keeps (package : Package) : Bool :=
  (contractChecks package).all (·.2)

/-- The checks of `binding-search-api`, each with what must hold as a
sentence. -/
def bindingSearchApiChecks : List (String × Bool) :=
  [("the name `search-bindings` is the one the interface declares, the name the default config binds to SPC ?",
      BindingSearchApi.searchBindingsName == "search-bindings" &&
        BindingSearchApi.names == #["search-bindings"]),
    ("the fake keeps the contract: every check of it holds", keeps fake),
    ("a package that registers nothing fails the contract, with the check for `search-bindings` false",
      let missing : Package := { name := "missing", setup := pure () }
      !keeps missing &&
        (contractChecks missing).any fun (sentence, held) =>
          !held && (sentence.splitOn "`search-bindings`").length > 1),
    ("a package that registers the name misspelt fails the contract",
      !keeps
          { name := "misspelt"
            setup := Editor.command "search-binding" (Editor.message "misspelt") })]

end BindingSearchApiTest
