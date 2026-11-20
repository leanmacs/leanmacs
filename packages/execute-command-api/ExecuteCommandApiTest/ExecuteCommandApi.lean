import ExecuteCommandApiTest.Contract
import ExecuteCommandApiTest.Fake

/-!
# Model tests: `ExecuteCommandApi.lean`

The tests of the interface package's names, its fake and its contract
check. The test driver's root, `ExecuteCommandApiTest/Model.lean`, runs
them.
-/

namespace ExecuteCommandApiTest

open Editor

/-- Whether every check of the contract over `package` holds. -/
def keeps (package : Package) : Bool :=
  (contractChecks package).all (·.2)

/-- The checks of `execute-command-api`, each with what must hold as a
sentence. -/
def executeCommandApiChecks : List (String × Bool) :=
  [("the name `execute-command` is the one the interface declares, the name the default config binds to SPC :",
      ExecuteCommandApi.executeCommandName == "execute-command" &&
        ExecuteCommandApi.names == #["execute-command"]),
    ("the fake keeps the contract: every check of it holds", keeps fake),
    ("a package that registers nothing fails the contract, with the check for `execute-command` false",
      let missing : Package := { name := "missing", setup := pure () }
      !keeps missing &&
        (contractChecks missing).any fun (sentence, held) =>
          !held && (sentence.splitOn "`execute-command`").length > 1),
    ("a package that registers the name misspelt fails the contract",
      !keeps
          { name := "misspelt"
            setup := Editor.command "execute-commands" (Editor.message "misspelt") })]

end ExecuteCommandApiTest
