import Editor
import Editor.Test.AtPoint
import Editor.Test.Linked.Host
import Editor.Test.Linked.Services
import Editor.Test.Minibuffer
import Editor.Test.Shipped
import EditorCore.EditorPackage
import FilesApiTest.Fake
import VersionControl.EditorPackage
import VersionControlTest.Check
import VersionControlTest.Linked.VersionControl.Git
import VersionControlTest.Linked.VersionControl.Gutter
import VersionControlTest.Linked.VersionControl.Log
import VersionControlTest.Linked.VersionControl.Review
import VersionControlTest.Linked.VersionControl.Status

/-!
# The linked test of the package `version-control`

The package-set step `run` (`tools/package-set.sh`, in `mise run ffi-test`)
builds this root's executable with the Rust library linked, and runs it in
the package's directory with the Lean toolchain's directory and the core's
`.olean` directory. It prints `version-control linked test: N checks
passed`, and exits 0 when all hold, 1 after naming on stderr the ones that
do not, and 2 for a command line that is not the two directories. The exit
is explicit, after the library's services are shut down and its queues
quit: a task may still be blocked in the library.

Its checks run over real git, in temporary repositories, under a user
config asking for what the git implementation's command lines pin away.
Each test module mirrors the module it tests; `gutterChecks` was the config
test's (`ConfigTest.gutterChecks`) and the others the contract test's
(`ContractTest.<name>`) while version control was modules of the core:

- `inLanesChecks` and `versionControlFailures`
  (`VersionControlTest/Linked/VersionControl/Git.lean`): the lanes the
  version-control interface's contract runs in, and that contract
  (`VcApiTest/Contract.lean`) against the git implementation over real git
  (each property is one of the `N` checks the line counts);
- `versionControlChecks` (the same module): what only git makes, a
  branch's change asked from two worktrees, a status read of files added
  with intent to add, what to watch in a linked worktree, and a commit's
  message under a config that strips one;
- `statusBufferChecks`, `reviewBufferChecks` and `historyBufferChecks`
  (`…/Status.lean`, `…/Review.lean`, `…/Log.lean`): the status buffer, the
  worktree list, `vc-show`, staging a hunk and the message buffer; the
  review buffer; and the log, the blame and the change since the last
  review, each over the library's services on the rig;
- `gutterChecks` (`…/Gutter.lean`): the gutter through the headless host
  over real git, the library's watch service and its diff engine.

The rig's checks and the hosts share one table of waits and one pump
(`Editor.Test.Linked.HostContext.fileWaits`, under `Services.over`). The
hosts are made over the real elaborator (`Editor.Test.Linked.HostContext.run`)
on the config base `Editor`, found in the core's `.olean` directory, with
the packages a set that holds this Lake package hands its editor
(`setPackages`). It imports the config base for the link alone, as every
root that links the elaborator does.
-/

/-- The packages a set that holds this Lake package hands its editor, as
the config tests' hosts were handed them: the core's, then this package's
two, then `files-api`'s fake for the file commands, the core's test kit's
stand-ins for the default packages `mode-line` and `languages`
(`Editor.Test.Shipped.packages`), and its implementations of `at-point`'s
and `minibuffer`'s commands. -/
def setPackages : Array Editor.Package :=
  EditorCore.EditorPackage.packages ++ VersionControl.EditorPackage.packages ++
    #[FilesApiTest.fake] ++
    Editor.Test.Shipped.packages ++
    #[Editor.Test.AtPoint.package, Editor.Test.Minibuffer.package]

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | [sysroot, oleans] =>
    let failed ←
      Editor.Test.Linked.HostContext.run sysroot oleans setPackages fun context => do
          let services ← Editor.Test.Linked.Services.over (← context.fileWaits)
          let jobs := services.jobs
          let checks :=
            VersionControlTest.Linked.inLanesChecks ++
              VersionControlTest.Linked.versionControlChecks jobs ++
              VersionControlTest.Linked.statusBufferChecks jobs ++
              VersionControlTest.Linked.reviewBufferChecks jobs ++
              VersionControlTest.Linked.historyBufferChecks jobs ++
              VersionControlTest.Linked.gutterChecks context
          let failed :=
            (← VersionControlTest.failures checks) ++
              (← VersionControlTest.Linked.versionControlFailures jobs)
          for name in failed do
            IO.eprintln s!"FAILED: {name}"
          -- Each property of the contract is a check of this test too.
          let count := checks.length + Editor.VersionControlContract.properties.length
          if failed.isEmpty then
            IO.println s!"version-control linked test: {count} checks passed"
          return failed
    (← IO.getStdout).flush
    Editor.Test.Linked.shutdown
    IO.Process.exit (if failed.isEmpty then 0 else 1)
  | _ =>
    IO.eprintln "usage: VersionControlTest-Linked <sysroot> <core olean dir>"
    return 2
