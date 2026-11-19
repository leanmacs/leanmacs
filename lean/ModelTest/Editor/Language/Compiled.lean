import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Language
import Editor.Language.Compiled
import Editor.Mode
import Editor.Package
import ModelTest.Check

/-!
# Model tests: `Editor/Language/Compiled.lean`

The model tests of `Editor/Language/Compiled.lean`: `languagePackageChecks`.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the `languages` package (`Editor/Language/Compiled.lean`):
what it registers is the `code` mode and the shipped languages. -/
def languagePackageChecks : List Check :=
  [{  name :=
        "the languages package is named languages and registers the shipped languages, in order, and the code mode, and no command"
      run :=
        let registered := Language.package.registered
        pure
          (Language.package.name == "languages" && registered.languages == Language.shipped &&
            registered.languages.map (·.name) == #["rust", "json", "markdown", "toml", "lean"] &&
            registered.modes.map (·.name) == Language.modes.map (·.name) &&
            registered.modes.map (·.name) == #["code"] &&
            registered.commands.isEmpty) }]

end ModelTest
