import Editor.Api
import Editor.Package
import ExApiTest.Contract
import ExApiTest.Fake

/-!
# Model tests: `ExApi.lean`

The tests of the interface package's names, its fake and its contract
check. The test driver's root, `ExApiTest/Model.lean`, runs them.
-/

namespace ExApiTest

open Editor

/-- Whether every check of the contract over `package` holds. -/
def keeps (package : Package) : Bool :=
  (contractChecks package).all (·.2)

/-- The sentences of the contract over `package` that do not hold. -/
def failing (package : Package) : List String :=
  ((contractChecks package).filter (!·.2)).map (·.1)

/-- A package that registers a command under each name the interface
declares, whose `ex` says a fixed text and runs nothing. -/
def namesOnly : Package :=
  { name := "names-only"
    setup :=
      for name in ExApi.names do
        command name (message "nothing is run") }

/-- The checks of `ex-api`, each with what must hold as a sentence. -/
def exApiChecks : List (String × Bool) :=
  [("the names the interface declares: ex, and quit, which is the core's quit name",
      ExApi.names == #["ex", "quit"] && ExApi.quitName == Editor.Quit.name),
    ("the fake, the core's test kit's ex line with its quit command, keeps the contract: every check of it holds",
      keeps fake),
    ("a package that registers nothing fails the contract, with the check for `ex` false",
      let missing : Package := { name := "missing", setup := pure () }
      !keeps missing &&
        (contractChecks missing).any fun (sentence, held) =>
          !held && (sentence.splitOn "`ex`").length > 1),
    ("a package that registers the two names but whose ex runs nothing fails the contract on its three checks of the command and no other",
      (failing namesOnly).length == 3 &&
        (failing namesOnly).all fun sentence =>
          (sentence.splitOn "`names-only`'s `ex`").length > 1),
    ("the kit's ex line without its quit command fails the contract on quit's check alone",
      (failing Editor.Test.exLinePackage).length == 1 &&
        (failing Editor.Test.exLinePackage).all fun sentence =>
          (sentence.splitOn "`quit`").length > 1)]

end ExApiTest
