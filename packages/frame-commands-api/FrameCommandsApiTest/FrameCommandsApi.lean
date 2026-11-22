import FrameCommandsApiTest.Contract
import FrameCommandsApiTest.Fake

/-!
# Model tests: `FrameCommandsApi.lean`

The tests of the interface package's names, its fake and its contract
check. The test driver's root, `FrameCommandsApiTest/Model.lean`, runs them.
-/

namespace FrameCommandsApiTest

open Editor

/-- Whether every check of the contract over `package` holds. -/
def keeps (package : Package) : Bool :=
  (contractChecks package).all (·.2)

/-- The checks of `frame-commands-api`, each with what must hold as a sentence. -/
def frameCommandsApiChecks : List (String × Bool) :=
  [("the names the interface declares: toggle-fullscreen and minimise-window, in the order the default package registers them",
      FrameCommandsApi.names == #["toggle-fullscreen", "minimise-window"]),
    ("the fake keeps the contract: every check of it holds", keeps fake),
    ("a package that registers nothing fails the contract, with the check for `toggle-fullscreen` false",
      let missing : Package := { name := "missing", setup := pure () }
      !keeps missing &&
        (contractChecks missing).any fun (sentence, held) =>
          !held && (sentence.splitOn "`toggle-fullscreen`").length > 1),
    ("a package that registers another name alone fails the contract",
      !keeps
          { name := "other",
            setup := Editor.command "toggle-fullscreens" (Editor.message "other") })]

end FrameCommandsApiTest
