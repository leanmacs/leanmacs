import WindowCommandsApiTest.Contract
import WindowCommandsApiTest.Fake

/-!
# Model tests: `WindowCommandsApi.lean`

The tests of the interface package's names, its fake and its contract
check. The test driver's root, `WindowCommandsApiTest/Model.lean`, runs them.
-/

namespace WindowCommandsApiTest

open Editor

/-- Whether every check of the contract over `package` holds. -/
def keeps (package : Package) : Bool :=
  (contractChecks package).all (·.2)

/-- The checks of `window-commands-api`, each with what must hold as a sentence. -/
def windowCommandsApiChecks : List (String × Bool) :=
  [("the names the interface declares: the thirty-three window commands, in the order the default package registers them",
      WindowCommandsApi.names ==
          #["window-split", "window-split-vertically", "window-new", "window-close", "window-quit",
            "window-only", "window-focus-left", "window-focus-down", "window-focus-up",
            "window-focus-right", "window-focus-next", "window-focus-previous", "window-focus-top",
            "window-focus-bottom", "window-focus-last", "window-exchange", "window-rotate",
            "window-rotate-back", "window-balance", "window-taller", "window-shorter",
            "window-wider", "window-narrower", "window-zoom", "window-promote", "window-demote",
            "window-main-more", "window-main-fewer", "window-edge-left", "window-edge-bottom",
            "window-edge-top", "window-edge-right", "window-float"] &&
        WindowCommandsApi.names.size == 33),
    ("the fake keeps the contract: every check of it holds", keeps fake),
    ("a package that registers nothing fails the contract, with the check for `window-split` false",
      let missing : Package := { name := "missing", setup := pure () }
      !keeps missing &&
        (contractChecks missing).any fun (sentence, held) =>
          !held && (sentence.splitOn "`window-split`").length > 1),
    ("a package that registers another name alone fails the contract",
      !keeps { name := "other", setup := Editor.command "window-splits" (Editor.message "other") })]

end WindowCommandsApiTest
