import Editor.Test.Linked.Services
import WorkingSetTest.Check
import WorkingSetTest.Linked.WorkingSet.Run

/-!
# The linked test of the package `working-set`

The package-set step `run` (`tools/package-set.sh`, in `mise run ffi-test`)
builds this root's executable with the Rust library linked, and runs it in
the package's directory with the Lean toolchain's directory and the core's
`.olean` directory, which it does not need. It prints `working-set linked
test: N checks passed`, and exits 0 when all hold, 1 after naming on stderr
the ones that do not, and 2 for a command line that is not the two
directories. The exit is explicit, after the library's services are shut
down and its queues quit: a task may still be blocked in the library.

Its checks run over the library's real services
(`Editor.Test.Linked.Services`), on the linked test kit's rig
(`Editor.Test.Linked.Rig`), each in a temporary directory of its own. The
test module mirrors the module it tests; its list was the contract test's
(`ContractTest.workingSetChecks`) while the working sets were modules of
the core:

- `workingSetChecks` (`WorkingSetTest/Linked/WorkingSet/Run.lean`): both
  acceptance criteria of navigation-and-windows phase 5 over the library's
  file service, text store and fuzzy matcher and real git, through a
  restart: ranges added and opened as a set's buffer, edited through it,
  written with `HEAD`'s commit, and a fresh editor over the same files
  opening them as changed, moved and drifted ranges.
-/

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | [_, _] =>
    let running ← Editor.Test.Linked.Services.start
    let checks := WorkingSetTest.Linked.workingSetChecks running.jobs
    let failed ← WorkingSetTest.failures checks
    for name in failed do
      IO.eprintln s!"FAILED: {name}"
    if failed.isEmpty then
      IO.println s!"working-set linked test: {checks.length} checks passed"
    (← IO.getStdout).flush
    Editor.Test.Linked.shutdown
    IO.Process.exit (if failed.isEmpty then 0 else 1)
  | _ =>
    IO.eprintln "usage: WorkingSetTest-Linked <sysroot> <core olean dir>"
    return 2
