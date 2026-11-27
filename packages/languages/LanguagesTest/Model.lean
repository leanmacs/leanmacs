import LanguagesTest.Check
import LanguagesTest.Languages.Compiled
import LanguagesTest.Languages.Grammars

/-!
# The test driver of the package `languages`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Each test module mirrors the module it tests: the checks of
`Languages/Compiled.lean` are in `LanguagesTest/Languages/Compiled.lean`,
and those of `Languages/Grammars.lean` in
`LanguagesTest/Languages/Grammars.lean`.

- `languagePackageChecks`: the `Package` value (`Languages/Compiled.lean`):
  what it registers is the `code` mode and the shipped languages, in
  order, and no command. It was the core's (`ModelTest.languagePackageChecks`)
  while the package was a module of the core.
- `grammarPackageChecks`: the `Package` value `languages-grammars`
  (`Languages/Grammars.lean`): what it registers against a staged grammars
  directory, its refusal with none, and the entry module's two packages.
-/

/-- Every check of the test driver, in the order they run. -/
def LanguagesTest.checks : List LanguagesTest.Check :=
  LanguagesTest.languagePackageChecks ++ LanguagesTest.grammarPackageChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← LanguagesTest.failures LanguagesTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"languages-test: {LanguagesTest.checks.length} checks passed"
    return 0
  else
    return 1
