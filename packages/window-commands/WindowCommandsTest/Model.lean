import WindowCommandsTest.Check
import WindowCommandsTest.WindowCommands

/-!
# The test driver of the package `window-commands`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Its one test module mirrors the modules it tests: the checks of
`WindowCommands.lean` and `WindowCommands/Compiled.lean` are in
`WindowCommandsTest/WindowCommands.lean`. They run on the core's test kit.
They were the core's (`ModelTest.windowCommandChecks`) while the window
commands were modules of the core, and moved here with their sentences as
they were.

- `windowCommandChecks`: the window commands (`WindowCommands.lean`), by
  key, on the loop's driver over the editor's models, under the test
  scheme with the keys of the checks' own table and the kit's minibuffer's,
  the kit's ex line's, the kit's quit command and the window commands
  handed: Vim 9.1's `C-w` behaviours under the manual split layout, resizes
  among them, the reorders, zoom and resizes under master-and-stack, focus
  by direction under the three layouts, and the refusals in the echo area;
  and the `Package` value (`WindowCommands/Compiled.lean`) held to the
  contract of `window-commands-api`
  (`WindowCommandsApiTest.contractChecks`), with a check that it bites, and
  what it registers: the thirty-three commands `WindowCommands.names`
  lists, in that order, and nothing else.
-/

/-- Every check of the test driver, in the order they run. -/
def WindowCommandsTest.checks : List WindowCommandsTest.Check :=
  WindowCommandsTest.windowCommandChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← WindowCommandsTest.failures WindowCommandsTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"window-commands-test: {WindowCommandsTest.checks.length} checks passed"
    return 0
  else
    return 1
