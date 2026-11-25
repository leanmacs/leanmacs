import LintTest.Lint.RealHost
import LintTest.Lint.Wait
import LintTest.Lint.Wiring

/-!
# Lint tests

The checks of the build's linters (`Lint.lean`), `lake exe lint-test`
(`mise run lean-test`). They call the linters' functions, so they import
the library `Lint`, which imports `Lean`, and so they are an executable of
their own: `model-test` links no module of Lean's frontend
(`.agents/rules/structure.md`, "Core imports"). What the linters refuse in a
module is shown by their fixtures in the other test roots, which the build
loads the linters into as a plugin.

The layout is the other test roots': each module's checks are in the test
module that mirrors its path under `LintTest/`, and this root imports them
and runs them.

- `lintWaitChecks` (`LintTest/Lint/Wait.lean`): the wait linters' rules
  (`Lint/Wait.lean`): what a test module is and which test module mirrors
  which; that a module beside a mirror counts as it only when it declares
  `.wiring`, its name alone making it none; where an inferred wait is
  allowed; the name of a constant's mark; and how a mark's value is read: a
  kind applied to a list of module names written out, or to a constant
  whose value is one, and nothing else.
- `lintRealHostChecks` (`LintTest/Lint/RealHost.lean`): the real-host
  linter's rules (`Lint/RealHost.lean`): the names of a constant's mark
  and of a module's declaration; how a mark's value (`loop`, `service`)
  and a declaration's (a constructor applied to string literals none of
  which is empty) are read; which types are a check's, which a wiring
  module may export unmarked; and which modules are contract roots.
- `lintWiringChecks` (`LintTest/Lint/Wiring.lean`): the wiring-set
  linter's rules (`Lint/Wiring.lean`): which types are a check set, a table
  of scenarios, a check of a root's check type and an IO list producer; a
  check set's value read into its groups in order; a reference counted at
  each place it is written; which modules are under a root's first name
  component; and the names of the bindings' module and of the wiring
  selection.
-/

namespace LintTest

/-- Every check of the build's linters. -/
def checks : List Check :=
  lintWaitChecks ++ lintRealHostChecks ++ lintWiringChecks

end LintTest

/-- Runs the checks: exits 0 when all hold, and 1 after naming on stderr the
ones that do not. -/
def main : IO UInt32 := do
  let failed ← LintTest.failures LintTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    return 1
  IO.println s!"lint-test: {LintTest.checks.length} checks passed"
  return 0
