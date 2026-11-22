import FrameCommandsTest.Check
import FrameCommandsTest.FrameCommands

/-!
# The test driver of the package `frame-commands`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Its one test module mirrors the modules it tests: the checks of
`FrameCommands.lean` and `FrameCommands/Compiled.lean` are in
`FrameCommandsTest/FrameCommands.lean`. They run on the core's test kit.
They were the core's (`ModelTest.frameCommandChecks`) while the frame
commands were modules of the core, and moved here with their sentences as
they were.

- `frameCommandChecks`: the frame's commands (`FrameCommands.lean`) and
  the frame's last reported fullscreen state, by key, on the loop's driver
  over the editor's models, under the test scheme, with the frame's
  commands and bindings and the kit's quit command handed: what each
  command asks the display, that `s-q` runs the core's quit rule through
  the command named `quit`, and that config's binding of a chord is the
  one that runs; and the `Package` value (`FrameCommands/Compiled.lean`)
  held to the contract of `frame-commands-api`
  (`FrameCommandsApiTest.contractChecks`), with a check that it bites, and
  what it registers: the two commands `FrameCommandsApi.names` lists, in
  that order, the three bindings, and nothing else.
-/

/-- Every check of the test driver, in the order they run. -/
def FrameCommandsTest.checks : List FrameCommandsTest.Check :=
  FrameCommandsTest.frameCommandChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← FrameCommandsTest.failures FrameCommandsTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"frame-commands-test: {FrameCommandsTest.checks.length} checks passed"
    return 0
  else
    return 1
