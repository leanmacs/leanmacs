import CompletionTest.Check
import CompletionTest.Completion.Compiled
import CompletionTest.Completion.Displays
import CompletionTest.Completion.Styles

/-!
# The test driver of the package `completion`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Each test module mirrors the module it tests: the checks of
`Completion/Styles.lean` are in `CompletionTest/Completion/Styles.lean`,
and those of `Completion/Compiled.lean` in
`CompletionTest/Completion/Compiled.lean`. The checks that need the Rust
library are the linked test's (`CompletionTest/Linked.lean`), in test
modules under `CompletionTest/Linked/`, which mirror the same paths. They
run on the core's test kit and test doubles (`Editor.Test.…`, the fuzzy
model, the style and display contracts; `docs/design/packages.md`, "What a
package may import"). They were the core's (`ModelTest.<name>`) while the
styles and displays were modules of the core, and moved here with their
sentences as they were.

- `shippedStyleChecks`: the shipped styles (`Completion/Styles.lean`) over
  the fuzzy model: the path, fuzzy and orderless rules, their names, and
  the style contract on each;
- `minibufferDisplayChecks`: the shipped display
  (`Completion/Displays.lean`): its rule, pure, over listings written
  there, the display contract on it, and its faces in the vocabulary;
- `completionPackageChecks`: the `Package` value
  (`Completion/Compiled.lean`) against the contract check of the interface
  package `completion-api`, each of the contract's checks one check here,
  so the count below holds them; then that it registers the shipped styles
  and displays, in order, and no command or source.
-/

/-- Every check of the test driver, in the order they run. -/
def CompletionTest.checks : List CompletionTest.Check :=
  CompletionTest.shippedStyleChecks ++ CompletionTest.minibufferDisplayChecks ++
    CompletionTest.completionPackageChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← CompletionTest.failures CompletionTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"completion-test: {CompletionTest.checks.length} checks passed"
    return 0
  else
    return 1
