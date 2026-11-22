import WorkingSetApiTest.Contract
import WorkingSetApiTest.Fake

/-!
# Model tests: `WorkingSetApi.lean`

The tests of the interface package's names, its fake and its contract
check. The test driver's root, `WorkingSetApiTest/Model.lean`, runs them.
-/

namespace WorkingSetApiTest

open Editor

/-- Whether every check of the contract over `package` holds. -/
def keeps (package : Package) : Bool :=
  (contractChecks package).all (·.2)

/-- The checks of `working-set-api`, each with what must hold as a
sentence. -/
def workingSetApiChecks : List (String × Bool) :=
  [("the names `working-set-add` and `working-set-open` are the ones the interface declares, the names the default config binds to SPC k a, SPC k o and SPC RET",
      WorkingSetApi.addName == "working-set-add" && WorkingSetApi.openName == "working-set-open" &&
        WorkingSetApi.names == #["working-set-add", "working-set-open"]),
    ("the fake keeps the contract: every check of it holds", keeps fake),
    ("a package that registers nothing fails the contract, with the checks for `working-set-add` and `working-set-open` false",
      let missing : Package := { name := "missing", setup := pure () }
      !keeps missing &&
        ["`working-set-add`", "`working-set-open`"].all fun quoted =>
          (contractChecks missing).any fun (sentence, held) =>
            !held && (sentence.splitOn quoted).length > 1),
    ("a package that registers only one of the two names fails the contract",
      !keeps
          { name := "half"
            setup := Editor.command WorkingSetApi.addName (Editor.message "half") })]

end WorkingSetApiTest
