import BuffersTest.Buffers
import BuffersTest.Buffers.Compiled
import BuffersTest.Check

/-!
# The test driver of the package `buffers`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Each test module mirrors the module it tests: the checks of `Buffers.lean`
are in `BuffersTest/Buffers.lean`, and those of `Buffers/Compiled.lean` in
`BuffersTest/Buffers/Compiled.lean`; the support they share is in
`BuffersTest/Support/Buffers.lean`. They were the core's
(`ModelTest.<name>`) while the buffer commands were modules of the core,
and moved here with their sentences as they were.

- `bufferCommandChecks`: the buffer commands (`Buffers.lean`) on the loop's
  driver over the editor's models: switching by name, exactly or by fuzzy
  match, and with a prompt; the buffer list; closing a buffer, one with
  unsaved changes refused; the order buffers were last used in; the buffer
  source held to the completion source contract;
- `buffersPackageChecks`: the `Package` value (`Buffers/Compiled.lean`)
  held to the contract of the interface library `buffers-api`
  (`BuffersApiTest.contractChecks`), and a check that the contract bites.
-/

/-- Every check of the test driver, in the order they run. -/
def BuffersTest.checks : List BuffersTest.Check :=
  BuffersTest.bufferCommandChecks ++ BuffersTest.buffersPackageChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← BuffersTest.failures BuffersTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"buffers-test: {BuffersTest.checks.length} checks passed"
    return 0
  else
    return 1
