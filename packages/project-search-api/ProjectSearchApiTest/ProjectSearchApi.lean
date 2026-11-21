import ProjectSearchApiTest.Contract
import ProjectSearchApiTest.Fake

/-!
# Model tests: `ProjectSearchApi.lean`

The tests of the interface package's names, its fake and its contract
check. The test driver's root, `ProjectSearchApiTest/Model.lean`, runs them.
-/

namespace ProjectSearchApiTest

open Editor

/-- Whether every check of the contract over `package` holds. -/
def keeps (package : Package) : Bool :=
  (contractChecks package).all (·.2)

/-- The checks of `project-search-api`, each with what must hold as a
sentence. -/
def projectSearchApiChecks : List (String × Bool) :=
  [("the names `project-search` and `project-search-symbol` are the ones the interface declares, the names the default config binds to SPC /, SPC s p and SPC *",
      ProjectSearchApi.searchName == "project-search" &&
        ProjectSearchApi.symbolName == "project-search-symbol" &&
        ProjectSearchApi.names == #["project-search", "project-search-symbol"]),
    ("the fake keeps the contract: every check of it holds", keeps fake),
    ("a package that registers nothing fails the contract, with the checks for `project-search` and `project-search-symbol` false",
      let missing : Package := { name := "missing", setup := pure () }
      !keeps missing &&
        ["`project-search`", "`project-search-symbol`"].all fun quoted =>
          (contractChecks missing).any fun (sentence, held) =>
            !held && (sentence.splitOn quoted).length > 1),
    ("a package that registers only one of the two names fails the contract",
      !keeps
          { name := "half"
            setup := Editor.command ProjectSearchApi.symbolName (Editor.message "half") })]

end ProjectSearchApiTest
