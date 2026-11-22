import Compile.Contribution
import CompileApi
import CompileApiTest.Listing
import CompileTest.Check
import Editor.Workspace

/-!
# Model tests: `Compile/Contribution.lean`

The model tests of `Compile/Contribution.lean`: `compileOfferChecks`.
The test driver's root, `CompileTest/Model.lean`, runs them; its module doc
says what each shows.
-/

namespace CompileTest

open Editor
open Editor.Test

/-- The checks of the commands the compile mode offers
(`Compile.offers`, `Compile/Contribution.lean`): pure, over the
listing checks' contribution `t-mode` (`tContribution`). -/
def compileOfferChecks : List Check :=
  [{  name :=
        "offers puts a mode's listed commands after its own, a listed name in place of its own, and a project's command in place of a listed one; a listed directory resolves against the root and an absolute one is kept"
      run :=
        let listed (mode : String) (root : System.FilePath) : Array Compile.NamedCommand :=
          if mode == "t-mode" && root == "/t" then
            #[{ name := "build", line := "t-build" }, { name := "fmt", line := "t-fmt" },
              { name := "sub", line := "t-sub", directory := some "sub" },
              { name := "abs", line := "t-abs", directory := some "/elsewhere" }]
          else #[]
        let project : Array Compile.ProjectCommands :=
          #[{ project := .remote "github.com/o/r", mode := "t-mode"
              commands := #[{ name := "fmt", line := "p-fmt" }] }]
        let offer (name line : String) (root : System.FilePath := "/t") : Compile.Offer :=
          { mode := "t-mode", name, line, root }
        pure
          (Compile.offers #[tContribution] project #[{ mode := "t-mode", root := "/t" }] listed ==
              #[offer "build" "t-build", offer "check" "t-check", offer "fmt" "p-fmt",
                offer "sub" "t-sub" "/t/sub", offer "abs" "t-abs" "/elsewhere"] &&
            Compile.offers #[tContribution] #[] #[{ mode := "t-mode", root := "/t2" }] listed ==
              #[offer "build" "t-fixed-build" "/t2", offer "check" "t-check" "/t2"]) }]

end CompileTest
