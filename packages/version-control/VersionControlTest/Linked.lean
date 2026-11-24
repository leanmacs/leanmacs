import Editor.RealHost
import Editor.Test.Linked.Services
import VersionControlTest.Check
import VersionControlTest.Linked.VersionControl.Git

/-!
# The linked test of the package `version-control`

The package-set step `run` (`tools/package-set.sh`, in `mise run ffi-test`)
builds this root's executable with the Rust library linked, and runs it in
the package's directory with the Lean toolchain's directory and the core's
`.olean` directory, which it does not need. It prints `version-control
linked test: N checks passed`, and exits 0 when all hold, 1 after naming
on stderr the ones that do not, and 2 for a command line that is not the
two directories. The exit is explicit, after the library's services are
shut down and its queues quit: a task may still be blocked in the library.

Its checks run over real git, in temporary repositories removed only once
the process and file services have worked what was handed to them
(`VcApiTest.Linked.withRepository`), under a user config asking for what
the git implementation's command lines pin away: the git implementation's
end-to-end checks. The test module mirrors the module it tests; its lists
were the contract test's (`ContractTest.<name>`) while version control was
modules of the core:

- `inLanesChecks` and `versionControlFailures`
  (`VersionControlTest/Linked/VersionControl/Git.lean`): the lanes the
  version-control interface's contract runs in, and that contract
  (`VcApiTest/Contract.lean`) against the git implementation over real git
  (each property is one of the `N` checks the line counts);
- `versionControlChecks` (the same module): what only git makes, a
  branch's change asked from two worktrees, a status read of files added
  with intent to add, what to watch in a linked worktree, and a commit's
  message under a config that strips one.

The buffers' checks over real git (`statusBufferChecks`,
`reviewBufferChecks`, `historyBufferChecks`) and the gutter's through a
host (`gutterChecks`) were here until host-tests-on-fakes phase 4: each
pinned, through real git, a criterion the package's model checks pin over
the git model (`VersionControlTest/VersionControl/*.lean`), while what git
itself does of each request is this contract's, so they went.

The real services are started here (`Editor.Test.Linked.Services.start`),
with the process's one completion pump.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.VersionControlTest.Linked : Editor.WiringSet :=
  .edge "its main starts the library's services and pump and hands them to the contract modules"

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | [_, _] =>
    let services ← Editor.Test.Linked.Services.start
    let jobs := services.jobs
    let checks :=
      VersionControlTest.Linked.inLanesChecks ++ VersionControlTest.Linked.versionControlChecks jobs
    let failed :=
      (← VersionControlTest.failures checks) ++
        (← VersionControlTest.Linked.versionControlFailures jobs)
    for name in failed do
      IO.eprintln s!"FAILED: {name}"
    -- Each property of the contract is a check of this test too.
    let count := checks.length + Editor.VersionControlContract.properties.length
    if failed.isEmpty then
      IO.println s!"version-control linked test: {count} checks passed"
    (← IO.getStdout).flush
    Editor.Test.Linked.shutdown
    IO.Process.exit (if failed.isEmpty then 0 else 1)
  | _ =>
    IO.eprintln "usage: VersionControlTest-Linked <sysroot> <core olean dir>"
    return 2
