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

- `workspaceFailures` (`WorkspaceTest/Linked/Workspace/Contract.lean`): the
  workspace finder's contract (`Workspace.FinderContract`) over the process
  and file services, each world written out: the main checkout and a
  worktree as one project, with and without an origin, and a marker-only
  directory among them;
- `modeMarkerFailures` (the same module): the mode marker search's contract
  (`Workspace.MarkerContract`) over the file service (each property of the
  two contracts is one of the `N` checks the line counts);
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

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | [_, _] =>
    let workspaces ← IO.FS.realPath workspaceFixtures
    let completion ← IO.FS.realPath completionFixtures
    let running ← Editor.Test.Linked.Services.start
    let services := running.jobs
    let checks := WorkspaceTest.Linked.workspaceListerChecks services completion
    let failed :=
      (← WorkspaceTest.Linked.workspaceFailures services workspaces) ++
        (← WorkspaceTest.Linked.modeMarkerFailures services) ++
        (← WorkspaceTest.failures checks)
    for name in failed do
      IO.eprintln s!"FAILED: {name}"
    -- Each property of the two contracts is a check of this test too.
    let count :=
      checks.length + (Editor.Workspace.FinderContract.properties "/").length +
        (Editor.Workspace.MarkerContract.properties "/").length
    if failed.isEmpty then
      IO.println s!"workspace linked test: {count} checks passed"
    (← IO.getStdout).flush
    Editor.Test.Linked.shutdown
    IO.Process.exit (if failed.isEmpty then 0 else 1)
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
  | _ =>
    IO.eprintln
        "usage: WorkspaceTest-Linked <sysroot> <core olean dir>, or WorkspaceTest-Linked bench-workspace-files <sysroot> <core olean dir> <repository> <samples>"
    return 2
