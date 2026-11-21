import Completion.Compiled
import CompletionApiTest.Contract
import CompletionTest.Check
import Editor.Config.Packages

/-!
# Model tests: `Completion/Compiled.lean`

The model tests of `Completion/Compiled.lean`: `completionPackageChecks`,
the contract check of the interface package this package implements,
`completion-api` (`CompletionApiTest.contractChecks`), over the `Package`
value, then what the `Package` value registers beyond the contract: the
shipped styles and displays. The test driver's root,
`CompletionTest/Model.lean`, runs them.
-/

namespace CompletionTest

open Editor

/-- The checks of the `completion` package (`Completion/Compiled.lean`):
it registers a style under each name `completion-api` declares, the
contract's checks each one check here; then what it registers is the
shipped styles and displays. -/
def completionPackageChecks : List Check :=
  (CompletionApiTest.contractChecks Completion.package).map
      (fun (name, held) => { name, run := pure held }) ++
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

end CompletionTest
