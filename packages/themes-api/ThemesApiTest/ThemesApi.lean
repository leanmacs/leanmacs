import ThemesApiTest.Contract
import ThemesApiTest.Fake

/-!
# Model tests: `ThemesApi.lean`

The tests of the interface package's name, its fake and its contract
check. The test driver's root, `ThemesApiTest/Model.lean`, runs them.
-/

namespace ThemesApiTest

open Editor

/-- Whether every check of the contract over `package` holds. -/
def keeps (package : Package) : Bool :=
  (contractChecks package).all (·.2)

/-- The checks of `themes-api`, each with what must hold as a sentence. -/
def themesApiChecks : List (String × Bool) :=
  [("the name `load-theme` is the one the interface declares, the name the default config binds to SPC h t",
      ThemesApi.loadName == "load-theme" && ThemesApi.names == #["load-theme"]),
    ("the fake keeps the contract: every check of it holds", keeps fake),
    ("a package that registers nothing fails the contract, with the check for `load-theme` false",
      let missing : Package := { name := "missing", setup := pure () }
      !keeps missing &&
        (contractChecks missing).any fun (sentence, held) =>
          !held && (sentence.splitOn "`load-theme`").length > 1),
    ("a package that registers another name alone fails the contract",
      !keeps { name := "other", setup := Editor.command "load-themes" (Editor.message "other") })]

end ThemesApiTest
