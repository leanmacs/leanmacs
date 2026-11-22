import ThemesTest.Check
import ThemesTest.Themes

/-!
# The test driver of the package `themes`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Its one test module mirrors the modules it tests: the checks of
`Themes.lean` and `Themes/Compiled.lean` are in `ThemesTest/Themes.lean`.
They run on the core's test kit. They were the core's
(`ModelTest.themeChecks`) while the themes were modules of the core, and
moved here with their sentences as they were.

- `themeChecks`: the command that loads a theme (`Themes.lean`) on the
  loop's driver over the editor's models and the test scheme, told of two
  registered themes: with no name it asks among them, with a registered
  name the step hands the name back, and a name nobody registered, or a
  prompt already open, is said in the echo area; its completion source
  (`Themes.source`) held to the completion sources' contract; and the
  `Package` value (`Themes/Compiled.lean`) held to the contract of
  `themes-api` (`ThemesApiTest.contractChecks`), with a check that it
  bites, and what it registers: the command, the theme `default`, the
  built-in one, and the source `themes` of the category `theme`.
-/

/-- Every check of the test driver, in the order they run. -/
def ThemesTest.checks : List ThemesTest.Check :=
  ThemesTest.themeChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← ThemesTest.failures ThemesTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"themes-test: {ThemesTest.checks.length} checks passed"
    return 0
  else
    return 1
