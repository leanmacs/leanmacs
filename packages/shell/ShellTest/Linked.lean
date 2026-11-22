import Editor.Test.Linked.Services
import ShellTest.Check
import ShellTest.Linked.Shell

/-!
# The linked test of the package `shell`

The package-set step `run` (`tools/package-set.sh`, in `mise run ffi-test`)
builds this root's executable with the Rust library linked, and runs it in
the package's directory with the Lean toolchain's directory and the core's
`.olean` directory, which it does not need. It prints `shell linked test: N
checks passed`, and exits 0 when all hold, 1 after naming on stderr the ones
that do not, and 2 for a command line that is not the two directories. The
exit is explicit, after the library's services are shut down and its queues
quit: a task may still be blocked in the library.

Its checks run over the library's real process service
(`Editor.Test.Linked.Services`), on the linked test kit's rig, with the
command loop over the real text binding and the editor's working directory
the fixture's, `tests/shell` under the package's directory. The test module
mirrors the module it tests; its list was the contract test's
(`ContractTest.shellChecks`) while the shell was modules of the core:

- `shellChecks` (`ShellTest/Linked/Shell.lean`): `shell-command` and
  `shell-filter` run by name as a host runs them, each job spawned on the
  runner over the library's services and its command delivered once the
  job has ended: the fixture `hello` leaves `hello` in the echo area, a sort
  filter over `b`, `c`, `a` leaves `a`, `b`, `c`, and every child is
  reaped.
-/

/-- The fixtures' directory of the shell's checks, under the package's
directory, which the linked test runs in. -/
def shellFixtures : System.FilePath :=
  "tests" / "shell"

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | [_, _] =>
    let fixtures ← IO.FS.realPath shellFixtures
    let running ← Editor.Test.Linked.Services.start
    let checks := ShellTest.Linked.shellChecks running.jobs fixtures
    let failed ← ShellTest.failures checks
    for name in failed do
      IO.eprintln s!"FAILED: {name}"
    if failed.isEmpty then
      IO.println s!"shell linked test: {checks.length} checks passed"
    (← IO.getStdout).flush
    Editor.Test.Linked.shutdown
    IO.Process.exit (if failed.isEmpty then 0 else 1)
  | _ =>
    IO.eprintln "usage: ShellTest-Linked <sysroot> <core olean dir>"
    return 2
