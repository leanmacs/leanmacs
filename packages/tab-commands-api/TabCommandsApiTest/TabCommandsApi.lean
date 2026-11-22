import TabCommandsApiTest.Contract
import TabCommandsApiTest.Fake

/-!
# Model tests: `TabCommandsApi.lean`

The tests of the interface package's names, its fake and its contract
check. The test driver's root, `TabCommandsApiTest/Model.lean`, runs them.
-/

namespace TabCommandsApiTest

open Editor

/-- Whether every check of the contract over `package` holds. -/
def keeps (package : Package) : Bool :=
  (contractChecks package).all (·.2)

/-- The checks of `tab-commands-api`, each with what must hold as a sentence. -/
def tabCommandsApiChecks : List (String × Bool) :=
  [("the names the interface declares: the eight tab commands, then tab-select-1 to tab-select-9, seventeen in all",
      TabCommandsApi.names ==
          #["tab-new", "tab-close", "tab-next", "tab-previous", "tab-switch", "tab-rename",
            "tab-move-right", "tab-move-left", "tab-select-1", "tab-select-2", "tab-select-3",
            "tab-select-4", "tab-select-5", "tab-select-6", "tab-select-7", "tab-select-8",
            "tab-select-9"] &&
        TabCommandsApi.selectName 3 == "tab-select-3"),
    ("the fake keeps the contract: every check of it holds", keeps fake),
    ("a package that registers nothing fails the contract, with the check for `tab-new` false",
      let missing : Package := { name := "missing", setup := pure () }
      !keeps missing &&
        (contractChecks missing).any fun (sentence, held) =>
          !held && (sentence.splitOn "`tab-new`").length > 1),
    ("a package that registers another name alone fails the contract",
      !keeps { name := "other", setup := Editor.command "tab-newer" (Editor.message "other") })]

end TabCommandsApiTest
