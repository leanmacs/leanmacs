import Editor
import Editor.RealHost
import Editor.Test.Linked.Services
import WorkspaceTest.Check
import WorkspaceTest.Linked.Workspace.Bench
import WorkspaceTest.Linked.Workspace.Contract
import WorkspaceTest.Linked.Workspace.Lister

/-!
# The linked test of the package `workspace`

The package-set step `run` (`tools/package-set.sh`, in `mise run ffi-test`)
builds this root's executable with the Rust library linked, and runs it in
the package's directory with the Lean toolchain's directory and the core's
`.olean` directory. It prints `workspace linked test: N checks passed`, and
exits 0 when all hold, 1 after naming on stderr the ones that do not, and 2
for a command line it does not take. The exit is explicit, after the
library's services are shut down and its queues quit: a task may still be
blocked in the library.

Its checks run over the library's real process and file services
(`Editor.Test.Linked.Services`), each in a temporary directory of its own,
removed only once those services have worked what was handed to them
(`Editor.Test.Linked.withFlushedBase`), with the fixtures under the
package's `tests/`: `tests/workspaces/git`
standing in for git, and `tests/completion/filter`, a copy of the core's
fixture of the same name, standing in for fzf. Each test module mirrors the
module it tests; they were the contract test's (`ContractTest.<name>`)
while the workspaces were modules of the core:

- `workspaceFinderContractChecks` (`WorkspaceTest/Linked/Workspace/Contract.lean`): the
  workspace finder's contract (`Workspace.FinderContract`) over the process
  and file services, each world written out: the main checkout and a
  worktree as one project, with and without an origin, and a marker-only
  directory among them;
- `modeMarkerContractChecks` (the same module): the mode marker search's contract
  (`Workspace.MarkerContract`) over the file service (each property of the
  two contracts is one check of the `N` the line counts);
- `workspaceListerChecks` (`WorkspaceTest/Linked/Workspace/Lister.lean`):
  git's lister lists a repository's tracked and untracked files and none
  that `.gitignore`, `info/exclude` or the global excludes file ignore, and
  a linked worktree's own files at its root and not at the main
  checkout's; the fallback lists a directory's files without `./` and none
  under a `.git` directory, and, past a directory of mode 000, which makes
  `find` exit 1, still the files it could read. Git is isolated from the
  user's config.

With the opt-in argument `bench-workspace-files` it runs the workspace
finder's benchmark instead (`WorkspaceTest.Linked.WorkspaceBench`,
`WorkspaceTest/Linked/Workspace/Bench.lean`; `mise run find-file-bench`),
which the gate builds and never runs. It hosts an editor over the real
elaborator on the config base `Editor`, which this root imports for the
link alone, as every root that links the elaborator does: the elaborator
imports the base's modules from their `.olean` files at runtime, and each
must already be linked into the executable.

Its checks are a check set (`WorkspaceTest.Linked.checks`, `Editor.CheckGroup`,
`docs/dev-practices/real-thread-checks.md`, "How stress runs the set"):
the lists of its modules of the wiring set in groups of their module, which
the build's `linter.wiringSet` holds true and complete. With `--wiring`
after the two directories it
runs those groups alone, the stress loop's `linked-wiring` suite
(`tools/package-set.sh run --wiring`), and `wiring-modules` prints their
modules, one a line, building nothing.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.WorkspaceTest.Linked : Editor.WiringSet :=
  .edge
    "its main starts the library's services and pump, hands them to the contract modules, and runs the workspace bench"

/-- The fixtures' directory of the workspace finder's checks, under the
package's directory, which the linked test runs in. -/
def workspaceFixtures : System.FilePath :=
  "tests" / "workspaces"

/-- The fixtures' directory of the listers' checks: the fixture that stands
in for fzf. -/
def completionFixtures : System.FilePath :=
  "tests" / "completion"

/-- What every check is handed: the job services `main` starts, and the
fixtures' directories of the finder's checks and of the listers'. -/
abbrev WorkspaceTest.Linked.Context :=
  Editor.Job.Services × System.FilePath × System.FilePath

/-- Every check of the linked test, in the order they run: its check set
(`Editor.CheckGroup`), the two contracts' properties, a check each, then
the listers', each list in a group of its module of the wiring set. -/
def WorkspaceTest.Linked.checks :
    List (Editor.CheckGroup WorkspaceTest.Linked.Context WorkspaceTest.Check) :=
  [.wired "WorkspaceTest.Linked.Workspace.Contract"
      wiringSet.WorkspaceTest.Linked.Workspace.Contract fun (services, workspaces, _) =>
      WorkspaceTest.Linked.workspaceFinderContractChecks services workspaces ++
        WorkspaceTest.Linked.modeMarkerContractChecks services,
    .wired "WorkspaceTest.Linked.Workspace.Lister" wiringSet.WorkspaceTest.Linked.Workspace.Lister
      fun (services, _, completion) =>
      WorkspaceTest.Linked.workspaceListerChecks services completion]

/-- Runs the checks `mode` selects from the check set
(`Editor.CheckGroup.select`) over the real services, started here, and says
which failed, or how many passed. -/
private def WorkspaceTest.Linked.runSelected (mode : Editor.CheckGroup.Mode) : IO UInt32 := do
  let workspaces ← IO.FS.realPath workspaceFixtures
  let completion ← IO.FS.realPath completionFixtures
  let running ← Editor.Test.Linked.Services.start
  let context := (running.jobs, workspaces, completion)
  let checks := Editor.CheckGroup.select mode WorkspaceTest.Linked.checks context
  let failed ← WorkspaceTest.failures checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"workspace linked test: {checks.length} {mode.what} passed"
  (← IO.getStdout).flush
  Editor.Test.Linked.shutdown
  IO.Process.exit (if failed.isEmpty then 0 else 1)

/-- Says the command lines it takes, and exits 2. -/
private def WorkspaceTest.Linked.usage : IO UInt32 := do
  IO.eprintln
      "usage: WorkspaceTest-Linked <sysroot> <core olean dir> [--wiring], WorkspaceTest-Linked wiring-modules, or WorkspaceTest-Linked bench-workspace-files <sysroot> <core olean dir> <repository> <samples>"
  return 2

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["wiring-modules"] =>
    for module in Editor.CheckGroup.modules WorkspaceTest.Linked.checks do
      IO.println module
    return 0
  | ["bench-workspace-files", sysroot, oleanDir, repository, samples] =>
    match samples.toNat? with
    | some samples =>
      let status ←
        try
          WorkspaceTest.Linked.WorkspaceBench.workspaceFiles sysroot oleanDir repository samples
        catch error =>
          IO.eprintln s!"WorkspaceTest-Linked: bench-workspace-files: {error}"
          pure 1
      IO.Process.exit status
    | none =>
      IO.eprintln
          "usage: WorkspaceTest-Linked bench-workspace-files <sysroot> <core olean dir> <repository> <samples>"
      return 2
  | _ :: _ :: rest =>
    match Editor.CheckGroup.Mode.ofArguments? rest with
    | some mode =>
      WorkspaceTest.Linked.runSelected mode
    | none =>
      WorkspaceTest.Linked.usage
  | _ =>
    WorkspaceTest.Linked.usage
