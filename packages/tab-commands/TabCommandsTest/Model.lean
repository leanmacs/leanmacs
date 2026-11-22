import TabCommandsTest.Check
import TabCommandsTest.TabCommands

/-!
# The test driver of the package `tab-commands`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Its one test module mirrors the modules it tests: the checks of
`TabCommands.lean` and `TabCommands/Compiled.lean` are in
`TabCommandsTest/TabCommands.lean`. They run on the core's test kit. They
were the core's (`ModelTest.tabCommandChecks`) while the tab commands were
modules of the core, and moved here with their sentences as they were.

- `tabCommandChecks`: the tab commands (`TabCommands.lean`), by key, on the
  loop's driver over the editor's models, under the test scheme with the
  keys of the checks' own tables and the tab commands handed, the windows
  split and zoomed by the kit's stand-ins: tmux's keys under `C-w`, the
  refusals in the echo area, the prompts of `tab-switch` and `tab-rename`,
  each command acting on the tab of its call's window, and a publish's
  layout reaching the tab in view alone; the tabs' completion source
  (`TabCommands.source`) held to the completion sources' contract; and the
  `Package` value (`TabCommands/Compiled.lean`) held to the contract of
  `tab-commands-api` (`TabCommandsApiTest.contractChecks`), with a check
  that it bites, and what it registers: the seventeen commands
  `TabCommands.names` lists, in that order, and the source `tabs`, the one
  source of the category `tab`.
-/

/-- Every check of the test driver, in the order they run. -/
def TabCommandsTest.checks : List TabCommandsTest.Check :=
  TabCommandsTest.tabCommandChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← TabCommandsTest.failures TabCommandsTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"tab-commands-test: {TabCommandsTest.checks.length} checks passed"
    return 0
  else
    return 1
