import MinibufferTest.Check
import MinibufferTest.Minibuffer
import MinibufferTest.Minibuffer.Compiled

/-!
# The test driver of the package `minibuffer`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Each test module mirrors the module it tests: the checks of
`Minibuffer.lean` are in `MinibufferTest/Minibuffer.lean`, and those of
`Minibuffer/Compiled.lean` in `MinibufferTest/Minibuffer/Compiled.lean`.
They run on the core's test kit and test doubles (`Editor.Test.…`, the
models, the prompt driver; `docs/design/packages.md`, "What a package may
import"). The first list was the core's (`ModelTest.promptModeChecks`)
while the minibuffer was modules of the core, and moved here with its
sentences as they were.

- `promptModeChecks`: the commands and the mode (`Minibuffer.lean`,
  `Minibuffer/Compiled.lean`) on the loop's driver over the models and
  the test scheme: a prompt asked, typed, accepted and cancelled, an
  initial value, a job that completes while a prompt is open, the scene
  of an open prompt, the commands with no prompt open, a second prompt
  refused, the focus moved away and back, the asking view closed, the
  rules of deleting backward and to the start, a malformed batch, and
  that the package registers its commands and its mode as the core's
  test kit's minibuffer does;
- `minibufferPackageChecks`: the `Package` value (`Minibuffer/Compiled.lean`)
  against the contract check of the interface package `minibuffer-api`,
  each of the contract's checks one check here, so the count below holds
  them.
-/

/-- Every check of the test driver, in the order they run. -/
def MinibufferTest.checks : List MinibufferTest.Check :=
  MinibufferTest.promptModeChecks ++ MinibufferTest.minibufferPackageChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← MinibufferTest.failures MinibufferTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"minibuffer-test: {MinibufferTest.checks.length} checks passed"
    return 0
  else
    return 1
