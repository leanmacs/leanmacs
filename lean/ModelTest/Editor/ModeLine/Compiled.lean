import Editor.Config.Packages
import Editor.Config.Registry
import Editor.ModeLine
import Editor.ModeLine.Compiled
import Editor.Package
import Editor.Test.Config
import ModelTest.Check

/-!
# Model tests: `Editor/ModeLine/Compiled.lean`

The model tests of `Editor/ModeLine/Compiled.lean`: `modeLinePackageChecks`.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The checks of the `mode-line` package (`Editor/ModeLine/Compiled.lean`):
what it registers is the shipped segments. -/
def modeLinePackageChecks : List Check :=
  [{  name :=
        "the mode-line package is named mode-line and registers the shipped segments, in order, each with the shipped segment's fields, so the default order resolves over them to the shipped mode line"
      run :=
        let registered := ModeLine.package.registered
        let registry :=
          ({} : Config.Registry).replaceSegments ModeLine.package.owner registered.segments
        let (resolved, unknown) := registry.resolve .standard
        pure
          (ModeLine.package.name == "mode-line" &&
            registered.segments.map (·.name) == ModeLine.shipped.map (·.name) &&
            registered.segments.size == 9 &&
            unknown == #["review"] &&
            resolved.fields loopContext == ModeLine.standard.fields loopContext &&
            registered.commands.isEmpty &&
            registered.modeLines.isEmpty) }]

end ModelTest
