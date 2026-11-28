import Editor.RealHost
import Editor.Test.Linked.Services
import MiseTest.Check
import MiseTest.Linked.Mise.Contract

/-!
# The linked test of the package `mise`

The package-set step `run` (`tools/package-set.sh`, in `mise run ffi-test`)
builds this root's executable with the Rust library linked, and runs it in
the package's directory with the Lean toolchain's directory and the core's
`.olean` directory, which it does not need. It prints `mise linked test: N
checks passed`, and exits 0 when all hold, 1 after naming on stderr the ones
that do not, and 2 for a command line it does not take. The exit is
explicit, after the library's services are shut down and its queues quit:
a task may still be blocked in the library.

Its checks run over the library's real process service
(`Editor.Test.Linked.Services`), each in a temporary directory of its own,
with the fixtures under the package's `tests/process-environment` standing
in for mise. The test module mirrors the module it tests:

- `miseChecks` (`MiseTest/Linked/Mise/Contract.lean`): `environment-api`'s
  directory-source contract (`EnvironmentApiTest.directoryContract`)
  against the package, a check for each sentence (D1 to D4: registered; a
  child prepared with the directory's `PATH`; kept until mise's first
  config file changes; a failing lookup leaves the child unchanged and is
  said once); a child started in each of two directories, by its path and
  by a bare name, gets that directory's fixture `PATH`; a mise that sleeps
  past a limit of 1 s is killed at the limit and not before, and reported
  once; and the test process's environment is the same after a lookup as
  before. They were the core's contract test's while mise was the core's.

Its checks are a check set (`MiseTest.Linked.checks`, `Editor.CheckGroup`,
`docs/dev-practices/real-thread-checks.md`, "How the set runs"): the list
of its module of the wiring set in a group of its module, which the build's
`linter.wiringSet` holds true and complete. With `--wiring` after the two
directories it runs that group alone, the stress loop's `linked-wiring`
suite (`tools/package-set.sh run --wiring`), and `wiring-modules` prints its
module, building nothing.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.MiseTest.Linked : Editor.WiringSet :=
  .edge "its main starts the library's services and hands them to the contract module"

/-- The fixtures' directory of the checks, under the package's directory,
which the linked test runs in. -/
def miseFixtures : System.FilePath :=
  "tests" / "process-environment"

/-- What every check is handed: the job services `main` starts, and the
fixtures' directory. -/
abbrev MiseTest.Linked.Context :=
  Editor.Job.Services × System.FilePath

/-- Every check of the linked test, in the order they run: its check set
(`Editor.CheckGroup`), the contract module's list in a group of its module
of the wiring set. -/
def MiseTest.Linked.checks : List (Editor.CheckGroup MiseTest.Linked.Context MiseTest.Check) :=
  [.wired "MiseTest.Linked.Mise.Contract" wiringSet.MiseTest.Linked.Mise.Contract
      fun (services, fixtures) => MiseTest.Linked.miseChecks services fixtures]

/-- Runs the checks `mode` selects from the check set
(`Editor.CheckGroup.select`) over the real services, started here, and says
which failed, or how many passed. -/
private def MiseTest.Linked.runSelected (mode : Editor.CheckGroup.Mode) : IO UInt32 := do
  let fixtures ← IO.FS.realPath miseFixtures
  let running ← Editor.Test.Linked.Services.start
  let checks := Editor.CheckGroup.select mode MiseTest.Linked.checks (running.jobs, fixtures)
  let failed ← MiseTest.failures checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"mise linked test: {checks.length} {mode.what} passed"
  (← IO.getStdout).flush
  Editor.Test.Linked.shutdown
  IO.Process.exit (if failed.isEmpty then 0 else 1)

/-- Says the command lines it takes, and exits 2. -/
private def MiseTest.Linked.usage : IO UInt32 := do
  IO.eprintln
      "usage: MiseTest-Linked <sysroot> <core olean dir> <test grammars dir> [--wiring], or MiseTest-Linked wiring-modules"
  return 2

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["wiring-modules"] =>
    for module in Editor.CheckGroup.modules MiseTest.Linked.checks do
      IO.println module
    return 0
  | _ :: _ :: _ :: rest =>
    match Editor.CheckGroup.Mode.ofArguments? rest with
    | some mode =>
      MiseTest.Linked.runSelected mode
    | none =>
      MiseTest.Linked.usage
  | _ =>
    MiseTest.Linked.usage
