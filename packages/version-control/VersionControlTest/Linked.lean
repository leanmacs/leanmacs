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
linked test: N checks passed, the contract's P properties in L lanes`, and
exits 0 when all hold, 1 after naming on stderr the ones that do not, and 2
for a command line it does not take. The exit is explicit, after the library's services are
shut down and its queues quit: a task may still be blocked in the library.

Its checks run over real git, in temporary repositories removed only once
the process and file services have worked what was handed to them
(`VcApiTest.Linked.withRepository`), under a user config asking for what
the git implementation's command lines pin away: the git implementation's
end-to-end checks. The test module mirrors the module it tests; its lists
were the contract test's (`ContractTest.<name>`) while version control was
modules of the core:

- `inLanesChecks` (`VersionControlTest/Linked/VersionControl/Lanes.lean`):
  the lanes the version-control interface's contract runs in, over plain
  numbers;
- `versionControlContractChecks`
  (`VersionControlTest/Linked/VersionControl/Git.lean`): that contract
  (`VcApiTest/Contract.lean`) against the git implementation over real git,
  one check of the `N`, its `P` properties run `L` at a time;
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

Its checks are a check set (`VersionControlTest.Linked.checks`, `Editor.CheckGroup`,
`docs/dev-practices/real-thread-checks.md`, "How stress runs the set"):
the lists of its modules of the wiring set in groups of their module, which
the build's `linter.wiringSet` holds true and complete. A run prints, after
its count, `wiring-set: ran version-control <module> <n> checks` for each module of
the wiring set it ran, which the gate's once-check reads
(`tools/wiring-ledger.sh`). With `--wiring` after the two directories it
runs those groups alone, the stress loop's `linked-wiring` suite
(`tools/package-set.sh run --wiring`), and `wiring-modules` prints their
modules, one a line, building nothing.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.VersionControlTest.Linked : Editor.WiringSet :=
  .edge "its main starts the library's services and pump and hands them to the contract modules"

/-- Every check of the linked test, in the order they run, over the job
services `main` starts: its check set (`Editor.CheckGroup`), the lanes'
checks in a plain group, then `VersionControl/Git.lean`'s, of the wiring
set, the contract over git among them as one check. -/
def VersionControlTest.Linked.checks :
    List (Editor.CheckGroup Editor.Job.Services VersionControlTest.Check) :=
  [.plain fun _ => VersionControlTest.Linked.inLanesChecks,
    .wired "VersionControlTest.Linked.VersionControl.Git"
      wiringSet.VersionControlTest.Linked.VersionControl.Git fun jobs =>
      VersionControlTest.Linked.versionControlChecks jobs ++
        VersionControlTest.Linked.versionControlContractChecks jobs]

/-- Runs the checks `mode` selects from the check set
(`Editor.CheckGroup.select`) over the real services, started here, and says
which failed, or how many passed, with the contract's properties and lanes; then a line for each
module of the wiring set the run ran (`Editor.CheckGroup.ranLines`). -/
private def VersionControlTest.Linked.runSelected (mode : Editor.CheckGroup.Mode) : IO UInt32 := do
  let services ← Editor.Test.Linked.Services.start
  let jobs := services.jobs
  let checks := Editor.CheckGroup.select mode VersionControlTest.Linked.checks jobs
  let failed ← VersionControlTest.failures checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println
        s!"version-control linked test: {checks.length} {mode.what} passed, the contract's {Editor.VersionControlContract.properties.length} properties in {VersionControlTest.Linked.versionControlLanes} lanes"
  for line in
    Editor.CheckGroup.ranLines "version-control"
      (Editor.CheckGroup.wiring VersionControlTest.Linked.checks) jobs do
    IO.println line
  (← IO.getStdout).flush
  Editor.Test.Linked.shutdown
  IO.Process.exit (if failed.isEmpty then 0 else 1)

/-- Says the command lines it takes, and exits 2. -/
private def VersionControlTest.Linked.usage : IO UInt32 := do
  IO.eprintln
      "usage: VersionControlTest-Linked <sysroot> <core olean dir> [--wiring], or VersionControlTest-Linked wiring-modules"
  return 2

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["wiring-modules"] =>
    for module in Editor.CheckGroup.modules VersionControlTest.Linked.checks do
      IO.println module
    return 0
  | _ :: _ :: rest =>
    match Editor.CheckGroup.Mode.ofArguments? rest with
    | some mode =>
      VersionControlTest.Linked.runSelected mode
    | none =>
      VersionControlTest.Linked.usage
  | _ =>
    VersionControlTest.Linked.usage
