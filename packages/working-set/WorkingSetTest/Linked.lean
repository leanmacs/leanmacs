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
directories, with `--wiring` after them or not, which runs nothing. The exit is explicit, after the library's services are shut
down and its queues quit: a task may still be blocked in the library.

Its checks run on the linked test kit's rig over fakes
(`Editor.Test.Linked.ProjectRig.stepped`), with the command loop over the
real text binding: each job runs to its end on the check's thread, and the
repository and the state directory are made-up paths the rig's file fake
holds. The test module mirrors the module it tests; its list was the
contract test's (`ContractTest.workingSetChecks`) while the working sets
were modules of the core:

- `workingSetChecks` (`WorkingSetTest/Linked/WorkingSet/Run.lean`): both
  acceptance criteria of navigation-and-windows phase 5 over the rig's file
  fake, the real text store and fuzzy matcher, and `vc-api`'s fake backend,
  through a restart: ranges added and opened as a set's buffer, edited
  through it, written with `HEAD`'s commit, and a fresh editor over the
  file fake's model the first ended with opening them as changed, moved and
  drifted ranges.
-/

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | [_, _] =>
    let checks := WorkingSetTest.Linked.workingSetChecks
    let failed ← WorkingSetTest.failures checks
    for name in failed do
      IO.eprintln s!"FAILED: {name}"
    if failed.isEmpty then
      IO.println s!"working-set linked test: {checks.length} checks passed"
    (← IO.getStdout).flush
    Editor.Test.Linked.shutdown
    IO.Process.exit (if failed.isEmpty then 0 else 1)
  -- No module of the wiring set: it lists none, and its wiring run
  -- (`tools/package-set.sh --wiring run`, the stress loop's
  -- `linked-wiring`) selects no check and passes.
  | [_, _, "--wiring"] =>
    return 0
  | ["wiring-modules"] =>
    return 0
  | _ =>
    IO.eprintln
        "usage: WorkingSetTest-Linked <sysroot> <core olean dir> [--wiring], or WorkingSetTest-Linked wiring-modules"
    return 2
