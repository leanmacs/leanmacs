import Editor.Config.Packages
import Editor.Language
import Editor.Mode
import Editor.Package
import Languages.Compiled
import LanguagesTest.Check

/-!
# Model tests: `Languages/Compiled.lean`

The model tests of `Languages/Compiled.lean`: `languagePackageChecks`. They
were the core's (`ModelTest.languagePackageChecks`) while the package was a
module of the core, and moved here with their sentence as it was. The test
driver's root, `LanguagesTest/Model.lean`, runs them.
-/

namespace LanguagesTest

open Editor

/-- The checks of the `languages` package (`Languages/Compiled.lean`):
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

end LanguagesTest
