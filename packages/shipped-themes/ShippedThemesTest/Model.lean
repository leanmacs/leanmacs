import ShippedThemesTest.Check
import ShippedThemesTest.ShippedThemes
import ShippedThemesTest.ShippedThemes.FairyFloss
import ShippedThemesTest.ShippedThemes.Solarized

/-!
# The test driver of the package `shipped-themes`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Each test module mirrors the module it tests: the checks of
`ShippedThemes.lean` are in `ShippedThemesTest/ShippedThemes.lean`, and
those of `ShippedThemes/Solarized.lean` in
`ShippedThemesTest/ShippedThemes/Solarized.lean`. The checks that need the
Rust library are the linked test's (`ShippedThemesTest/Linked.lean`), in
test modules under `ShippedThemesTest/Linked/`, which mirror the same
paths.

- `shippedThemesChecks`: the package alone is accepted and registers its
  three themes and nothing else; every theme passes the core's
  completeness check (`Themes.problems`), pads the mode line and the echo
  area, and defines the tab bar's faces; and each paper is light or dark
  as the theme's name says;
- `solarizedChecks`: Solarized's sixteen published values, the light
  swap, and the table of choices of `ShippedThemes/Solarized.lean`;
- `fairyFlossChecks`: Fairy Floss's nineteen published values, the
  source's commit, and the table of choices of
  `ShippedThemes/FairyFloss.lean`.
-/

/-- Every check of the test driver, in the order they run. -/
def ShippedThemesTest.checks : List ShippedThemesTest.Check :=
  ShippedThemesTest.shippedThemesChecks ++ ShippedThemesTest.solarizedChecks ++
    ShippedThemesTest.fairyFlossChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← ShippedThemesTest.failures ShippedThemesTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"shipped-themes-test: {ShippedThemesTest.checks.length} checks passed"
    return 0
  else
    return 1
