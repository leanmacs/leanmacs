import BindingSearchTest.BindingSearch
import BindingSearchTest.BindingSearch.Compiled
import BindingSearchTest.Check

/-!
# The test driver of the package `binding-search`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Each test module mirrors the module it tests: the checks of
`BindingSearch.lean` are in `BindingSearchTest/BindingSearch.lean`, and
those of `BindingSearch/Compiled.lean` in
`BindingSearchTest/BindingSearch/Compiled.lean`. They run on the core's
test kit (`Editor.Test.…`, a test double the core publishes;
`docs/design/packages.md`, "What a package may import").

- `bindingSearchChecks`: the binding search (`BindingSearch.lean`), on the
  loop's driver over the editor's models and the test scheme, and its
  source held to the completion sources' contract on the kit's runner. It
  was the core's (`ModelTest.bindingSearchChecks`) while the binding
  search was a module of the core, and moved here with its sentences as
  they were;
- `bindingSearchPackageChecks`: the `Package` value
  (`BindingSearch/Compiled.lean`) against the contract check of the
  interface package `binding-search-api`, each of the contract's checks
  one check here, so the count below holds them.
-/

/-- Every check of the test driver, in the order they run. -/
def BindingSearchTest.checks : List BindingSearchTest.Check :=
  BindingSearchTest.bindingSearchChecks ++ BindingSearchTest.bindingSearchPackageChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← BindingSearchTest.failures BindingSearchTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"binding-search-test: {BindingSearchTest.checks.length} checks passed"
    return 0
  else
    return 1
