import AtPointApiTest.Contract
import AtPointApiTest.Fake
import Editor.Test.AtPoint

/-!
# Model tests: `AtPointApi.lean`

The tests of the interface package's names, its fake and its contract
check. The test driver's root, `AtPointApiTest/Model.lean`, runs them.

The checks catch an omission as well as a rename: the names are pinned
whole against the core's test kit's (`Editor.Test.AtPoint.names`), which
the core's Vim-table tests hold the insert table to, so a name left out
of either, or spelt otherwise in either, fails here; and a package that
registers every name but one, or one misspelt, fails the contract.
-/

namespace AtPointApiTest

open Editor

/-- Whether every check of the contract over `package` holds. -/
def keeps (package : Package) : Bool :=
  (contractChecks package).all (·.2)

/-- Whether the contract over `package` has a check that names `name` and
does not hold. -/
def failsOn (package : Package) (name : String) : Bool :=
  (contractChecks package).any fun (sentence, held) =>
    !held && (sentence.splitOn s!"`{name}`").length > 1

/-- A package named `name` that registers a command, saying nothing, under
each of `names`. -/
def registering (name : String) (names : Array String) : Package :=
  { name
    setup :=
      for command in names do
        Editor.command command (pure ()) }

/-- The checks of `at-point-api`, each with what must hold as a
sentence. -/
def atPointApiChecks : List (String × Bool) :=
  [("the names the interface declares are the nine the core's test kit registers, in its order: the seven the Vim scheme's insert table binds and the two the core runs at a trigger and a pause, so a name left out of either list fails",
      AtPointApi.names == Editor.Test.AtPoint.names &&
        AtPointApi.names ==
          #["at-point-complete", "at-point-next", "at-point-previous", "at-point-tab",
            "at-point-backtab", "at-point-return", "at-point-quit", "at-point-triggered",
            "at-point-paused"]),
    ("the names of the commands the core runs at a trigger and a pause are the core's own constants",
      AtPointApi.triggeredName == Completion.AtPoint.triggeredCommand &&
        AtPointApi.pausedName == Completion.AtPoint.pausedCommand),
    ("the fake keeps the contract: every check of it holds", keeps fake),
    ("the contract holds of the core's test kit's implementation, Editor.Test.AtPoint.package, the same value as the fake",
      keeps Editor.Test.AtPoint.package),
    ("a package that registers nothing fails the contract, with the check for each name false",
      let missing := registering "missing" #[]
      AtPointApi.names.all (failsOn missing)),
    ("a package that registers every name but at-point-quit fails the contract, with the check for `at-point-quit` false and the others true",
      let lacking := registering "lacking" (AtPointApi.names.filter (· != AtPointApi.quitName))
      !keeps lacking && failsOn lacking AtPointApi.quitName &&
        (AtPointApi.names.filter (· != AtPointApi.quitName)).all fun name => !failsOn lacking name),
    ("a package that registers every name but one misspelt fails the contract",
      !keeps
          (registering "misspelt"
            (AtPointApi.names.map fun name =>
              if name == AtPointApi.pausedName then "at-point-pause" else name)))]

end AtPointApiTest
