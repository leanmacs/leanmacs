import EvilApiTest.Contract
import EvilApiTest.Fake

/-!
# Model tests: `EvilApi.lean`

The tests of the interface package's names, its fake and its contract
check. The test driver's root, `EvilApiTest/Model.lean`, runs them.
-/

namespace EvilApiTest

open Editor

/-- Whether every check of the contract over `package` holds. -/
def keeps (package : Package) : Bool :=
  (contractChecks package).all (·.2)

/-- The checks of `evil-api`, each with what must hold as a sentence. -/
def evilApiChecks : List (String × Bool) :=
  [("the names `insert-newline`, `insert-tab`, `undo` and `redo` are the ones the interface declares, the names completion at point and the Edit menu run",
      EvilApi.insertNewlineName == "insert-newline" && EvilApi.insertTabName == "insert-tab" &&
        EvilApi.undoName == "undo" &&
        EvilApi.redoName == "redo" &&
        EvilApi.names == #["insert-newline", "insert-tab", "undo", "redo"]),
    ("the fake keeps the contract: every check of it holds", keeps fake),
    ("a package that registers nothing fails the contract, with the check for each of the four names false",
      let missing : Package := { name := "missing", setup := pure () }
      !keeps missing &&
        ["`insert-newline`", "`insert-tab`", "`undo`", "`redo`"].all fun quoted =>
          (contractChecks missing).any fun (sentence, held) =>
            !held && (sentence.splitOn quoted).length > 1),
    ("a package that registers three of the four names fails the contract",
      !keeps
          { name := "three"
            setup := do
              Editor.command EvilApi.insertNewlineName (Editor.message "three")
              Editor.command EvilApi.insertTabName (Editor.message "three")
              Editor.command EvilApi.undoName (Editor.message "three") })]

end EvilApiTest
