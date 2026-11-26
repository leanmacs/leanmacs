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
directories, with `--wiring` after them or not. Its check set (`ProjectSearchTest.Linked.checks`)
holds no module of the wiring set, so with `--wiring` it selects no check
and exits 0 (`Editor.CheckGroup.running`), and `wiring-modules` prints
none. The exit is explicit, after the library's services are shut
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

/-- The root's check set (`Editor.CheckGroup`): its checks, in a plain
group, since it holds no module of the wiring set. They need no context. -/
def ProjectSearchTest.Linked.checks : List (Editor.CheckGroup Unit ProjectSearchTest.Check) :=
  [.plain fun () => ProjectSearchTest.Linked.projectSearchChecks]

/-- The usage, on stderr, and status 2. -/
private def ProjectSearchTest.Linked.usage : IO UInt32 := do
  IO.eprintln
      "usage: ProjectSearchTest-Linked <sysroot> <core olean dir> [--wiring], or ProjectSearchTest-Linked wiring-modules"
  return 2

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["wiring-modules"] =>
    for module in Editor.CheckGroup.modules ProjectSearchTest.Linked.checks do
      IO.println module
    return 0
  | _ :: _ :: rest =>
    match Editor.CheckGroup.Mode.ofArguments? rest with
    | some mode =>
      Editor.CheckGroup.running mode ProjectSearchTest.Linked.checks do
          let checks := Editor.CheckGroup.select mode ProjectSearchTest.Linked.checks ()
          let failed ← ProjectSearchTest.failures checks
          for name in failed do
            IO.eprintln s!"FAILED: {name}"
          if failed.isEmpty then
            IO.println s!"project-search linked test: {checks.length} {mode.what} passed"
          (← IO.getStdout).flush
          Editor.Test.Linked.shutdown
          IO.Process.exit (if failed.isEmpty then 0 else 1)
    | none =>
      ProjectSearchTest.Linked.usage
  | _ =>
    ProjectSearchTest.Linked.usage
