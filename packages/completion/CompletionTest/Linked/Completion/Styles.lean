import Completion.Styles
import Editor.Completion.StyleContract
import Editor.Fuzzy
import Editor.Program

/-!
# Linked tests: `Completion/Styles.lean`

The tests of the styles that ship (`Completion/Styles.lean`) over the
library's matcher: `shippedStyleFailures`, the completion styles' contract
on the fuzzy style and the path style over the real fuzzy binding. The
linked test's root, `CompletionTest/Linked.lean`, runs them, handing the
real binding in: a module under the root imports no real binding of a
port (`docs/design/packages.md`, "What a package may import"). They were
the core's (`ContractTest.shippedStyleFailures`) while the styles were
modules of the core, and moved here with their sentences as they were.
-/

namespace CompletionTest

open Editor

/-- The shipped styles held to the contract over the real fuzzy binding,
each with how its failures are named. -/
def linkedStyles : List (String × Completion.Style) :=
  [("the fuzzy style", Completion.Styles.fuzzy), ("the path style", Completion.Styles.path)]

/-- The names of the completion styles' contract properties that do not hold
of the fuzzy style or of the path style over `fuzzy`, the real fuzzy
binding, beside `completion-test`'s on the fuzzy model
(`shippedStyleChecks`). -/
def shippedStyleFailures (fuzzy : FuzzyHandler) : IO (List String) :=
  linkedStyles.flatMapM fun (subject, style) => do
    let failed ← Completion.StyleContract.failures (Program.runM (port := fuzzyPort) fuzzy) style
    return failed.map (s!"{subject} over the real fuzzy binding: {·}")

end CompletionTest
