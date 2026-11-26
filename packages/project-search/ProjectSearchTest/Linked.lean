import Editor.Test.Linked.Services
import ProjectSearchTest.Check
import ProjectSearchTest.Linked.ProjectSearch.Run

/-!
# The linked test of the package `project-search`

The package-set step `run` (`tools/package-set.sh`, in `mise run ffi-test`)
builds this root's executable with the Rust library linked, and runs it in
the package's directory with the Lean toolchain's directory and the core's
`.olean` directory, which it does not need. It prints `project-search
linked test: N checks passed`, and exits 0 when all hold, 1 after naming on
stderr the ones that do not, and 2 for a command line that is not the two
directories, with `--wiring` after them or not, which runs nothing. The exit is explicit, after the library's services are shut
down and its queues quit: a task may still be blocked in the library.

Its checks run on the linked test kit's rig over fakes
(`Editor.Test.Linked.ProjectRig.stepped`), with the command loop over the
real text binding and the files `files-api`'s fake's (`FilesApiTest.fake`):
each job runs to its end on the check's thread. The test module mirrors the
module it tests; its list was the contract test's
(`ContractTest.projectSearchChecks`) while project search was modules of
the core:

- `projectSearchChecks` (`ProjectSearchTest/Linked/ProjectSearch/Run.lean`):
  criteria 2 and 3 of project search over the rig's file and grep fake and
  the real text store: the results hold an open file's unsaved match and a
  closed file's match in its file, not an ignored file's, and a change
  typed over a match in the results changes that file's buffer and not the
  file.

This root imports neither the config base `Editor` nor `Editor.Headless`,
each of which reached evil until evil moved out: its one list runs on the rig alone, so no module of the package,
library or tests, reaches a module of evil (the phase's acceptance
criterion 3).
-/

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | [_, _] =>
    let checks := ProjectSearchTest.Linked.projectSearchChecks
    let failed ← ProjectSearchTest.failures checks
    for name in failed do
      IO.eprintln s!"FAILED: {name}"
    if failed.isEmpty then
      IO.println s!"project-search linked test: {checks.length} checks passed"
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
        "usage: ProjectSearchTest-Linked <sysroot> <core olean dir> [--wiring], or ProjectSearchTest-Linked wiring-modules"
    return 2
