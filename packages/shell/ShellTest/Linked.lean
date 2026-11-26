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

Its checks run on the linked test kit's rig over fakes
(`Editor.Test.Linked.ProjectRig.stepped`), with the command loop over the
real text binding: the shell's jobs run to their end on the check's thread,
each child answered by the rig's process fake. The test module mirrors the
module it tests; its list was the contract test's
(`ContractTest.shellChecks`) while the shell was modules of the core:

- `shellChecks` (`ShellTest/Linked/Shell.lean`): `shell-command` and
  `shell-filter` run by name as a host runs them, each job spawned on the
  runner over the rig's fakes and its command delivered once the job has
  ended: a child that replies `hello` leaves `hello` in the echo area, and
  a sort filter over `b`, `c`, `a` is fed those lines and leaves `a`, `b`,
  `c`. The real process service's end-to-end check is the compile
  package's (`CompileTest.criterion11RealProcessCheck`).
-/

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | [_, _] =>
    let checks := ShellTest.Linked.shellChecks
    let failed ← ShellTest.failures checks
    for name in failed do
      IO.eprintln s!"FAILED: {name}"
    if failed.isEmpty then
      IO.println s!"shell linked test: {checks.length} checks passed"
    (← IO.getStdout).flush
    Editor.Test.Linked.shutdown
    IO.Process.exit (if failed.isEmpty then 0 else 1)
  -- No module of the wiring set: it lists none, so `tools/package-set.sh
  -- --wiring run`, the stress loop's `linked-wiring`, skips it.
  | ["wiring-modules"] =>
    return 0
  | _ =>
    IO.eprintln
        "usage: ShellTest-Linked <sysroot> <core olean dir>, or ShellTest-Linked wiring-modules"
    return 2
