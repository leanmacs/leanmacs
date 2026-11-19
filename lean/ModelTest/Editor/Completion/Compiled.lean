import Editor.Completion.Compiled
import Editor.Completion.Displays
import Editor.Completion.Styles
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Package
import ModelTest.Check

/-!
# Model tests: `Editor/Completion/Compiled.lean`

The model tests of `Editor/Completion/Compiled.lean`:
`completionPackageChecks`. The root module `ModelTest` runs them; its module
doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the `completion` package
(`Editor/Completion/Compiled.lean`): what it registers is the shipped styles
and displays. -/
def completionPackageChecks : List Check :=
  [{  name :=
        "the completion package is named completion and registers the shipped styles and the shipped displays, each in order, and no command or source"
      run :=
        let registered := Completion.package.registered
        pure
          (Completion.package.name == "completion" &&
            registered.styles.map (·.name) == Completion.Styles.shipped.map (·.name) &&
            registered.styles.map (·.name) == #["fuzzy", "orderless", "path"] &&
            registered.displays.map (·.name) == Completion.Displays.shipped.map (·.name) &&
            registered.displays.map (·.name) == #["minibuffer"] &&
            registered.commands.isEmpty &&
            registered.sources.isEmpty &&
            registered.styleChoices.isEmpty) }]

end ModelTest
