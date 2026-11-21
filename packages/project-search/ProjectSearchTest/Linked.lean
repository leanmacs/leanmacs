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
directories. The exit is explicit, after the library's services are shut
down and its queues quit: a task may still be blocked in the library.

Its checks run over the library's real services
(`Editor.Test.Linked.Services`), on the linked test kit's rig
(`Editor.Test.Linked.Rig`), each in a temporary directory of its own, with
the files `files-api`'s fake's (`FilesApiTest.fake`). The test module
mirrors the module it tests; its list was the contract test's
(`ContractTest.projectSearchChecks`) while project search was modules of
the core:

- `projectSearchChecks` (`ProjectSearchTest/Linked/ProjectSearch/Run.lean`):
  criteria 2 and 3 of project search over the library's grep service, file
  service and text store: the results hold an open file's unsaved match and
  a closed file's on-disk match, not an ignored file's, and a change typed
  over a match in the results changes that file's buffer and not the file.

This root imports neither the config base `Editor`, nor `Editor.Headless`,
nor `EditorCore.EditorPackage`, each of which reaches evil until evil moves
out: its one list runs on the rig alone, so no module of the package,
library or tests, reaches a module of evil (the phase's acceptance
criterion 3).
-/

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | [_, _] =>
    let running ← Editor.Test.Linked.Services.start
    let checks := ProjectSearchTest.Linked.projectSearchChecks running.jobs
    let failed ← ProjectSearchTest.failures checks
    for name in failed do
      IO.eprintln s!"FAILED: {name}"
    if failed.isEmpty then
      IO.println s!"project-search linked test: {checks.length} checks passed"
    (← IO.getStdout).flush
    Editor.Test.Linked.shutdown
    IO.Process.exit (if failed.isEmpty then 0 else 1)
  | _ =>
    IO.eprintln "usage: ProjectSearchTest-Linked <sysroot> <core olean dir>"
    return 2
