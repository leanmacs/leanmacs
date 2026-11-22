import Editor.Config.Packages
import Editor.Ex.Compiled
import ModelTest.Check

/-!
# Model tests: `Editor/Ex/Compiled.lean`

The model tests of `Editor/Ex/Compiled.lean`: `exPackageChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the `ex` package (`Editor/Ex/Compiled.lean`): the ex
names it binds are the files', its own and the buffers', and no feature's
that binds its own. -/
def exPackageChecks : List Check :=
  [{  name :=
        "the package ex binds the files', its own and the buffers' ex names, w, w!, e, e!, autoread, noautoread, q, wq, reload, b, ls and bd, in that order, and no other"
      run :=
        pure
          (Ex.package.registered.ex.map (·.name) ==
            #["w", "w!", "e", "e!", "autoread", "noautoread", "q", "wq", "reload", "b", "ls",
              "bd"]) }]

end ModelTest
