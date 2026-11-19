import Editor.Config.Lakefile
import ModelTest.Check

/-!
# Model tests: `Editor/Config/Lakefile.lean`

The model tests of `Editor/Config/Lakefile.lean`: `lakefileChecks`. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Config

/-- The checks of what a config's lakefile says of a module
(`Editor/Config/Lakefile.lean`): the library a package's modules are
under, and which require a module belongs to. -/
def lakefileChecks : List Check :=
  [{  name :=
        "the library of a package is its name in upper camel case, cut at each dash and underscore"
      run :=
        pure
          (Lakefile.libraryRoot "greeting" == "Greeting" &&
            Lakefile.libraryRoot "greeting-loud" == "GreetingLoud" &&
            Lakefile.libraryRoot "shipped_themes" == "ShippedThemes" &&
            Lakefile.libraryRoot "editorCore" == "EditorCore" &&
            Lakefile.libraryRoot "" == "") },
    { name :=
        "a module belongs to the require whose library is its first component, the library's own module and a module under it alike"
      run :=
        pure
          (Lakefile.owner? #["default-set", "greeting-loud"] "GreetingLoud" ==
              some "greeting-loud" &&
            Lakefile.owner? #["default-set", "greeting-loud"] "GreetingLoud.Shout.All" ==
              some "greeting-loud") },
    { name :=
        "a module belongs to no require when none has its first component as its library: a module of another package, and one whose name only starts as a library's does"
      run :=
        pure
          (Lakefile.owner? #["greeting"] "Lake" == none &&
            Lakefile.owner? #["greeting"] "GreetingLoud" == none &&
            Lakefile.owner? #[] "Greeting" == none) }]

end ModelTest
