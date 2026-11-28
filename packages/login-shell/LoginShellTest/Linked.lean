import Editor.RealHost
import Editor.Test.Linked.Services
import LoginShellTest.Check
import LoginShellTest.Linked.LoginShell.Contract
import LoginShellTest.Linked.LoginShell.Real

/-!
# The linked test of the package `login-shell`

The package-set step `run` (`tools/package-set.sh`, in `mise run ffi-test`)
builds this root's executable with the Rust library linked, and runs it in
the package's directory with the Lean toolchain's directory and the core's
`.olean` directory, which it does not need. It prints `login-shell linked
test: N checks passed`, and exits 0 when all hold, 1 after naming on stderr
the ones that do not, and 2 for a command line it does not take. The exit
is explicit, after the library's services are shut down and its queues
quit: a task may still be blocked in the library.

Its checks run over the library's real process service
(`Editor.Test.Linked.Services`), each in a temporary directory of its own,
with the fixtures under the package's `tests/login-shell` standing in for a
login shell and for a directory source. No check runs the user's own shell
or reads their profile. The test modules mirror the module they test:

- `loginShellContractChecks` (`LoginShellTest/Linked/LoginShell/Contract.lean`):
  `environment-api`'s base contract (`EnvironmentApiTest.baseContract`)
  against the package's login shell at the fixture shell, a check for each
  sentence (B1 to B4: registered; a child in any directory prepared with
  the `PATH` the fixture profile sets, criterion 3; looked up once per run;
  a failing shell leaves children unchanged and is said once).
- `loginShellWiringChecks` (`LoginShellTest/Linked/LoginShell/Real.lean`),
  criterion 4, the one wiring check: a real child started under the fixture
  shell's base and a fixture directory source standing in for mise gets the
  directory's prepended entry first and the shell's `PATH` after it.

Its checks are a check set (`LoginShellTest.Linked.checks`,
`Editor.CheckGroup`, `docs/dev-practices/real-thread-checks.md`, "How the
set runs"): each module of the wiring set's list in a group of its module,
which the build's `linter.wiringSet` holds true and complete. With
`--wiring` after the three arguments it runs those groups alone, the stress
loop's `linked-wiring` suite (`tools/package-set.sh run --wiring`), and
`wiring-modules` prints its modules, building nothing.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.LoginShellTest.Linked : Editor.WiringSet :=
  .edge "its main starts the library's services and hands them to the contract and wiring modules"

/-- The fixtures' directory of the checks, under the package's directory,
which the linked test runs in. -/
def loginShellFixtures : System.FilePath :=
  "tests" / "login-shell"

/-- What every check is handed: the job services `main` starts, and the
fixtures' directory. -/
abbrev LoginShellTest.Linked.Context :=
  Editor.Job.Services × System.FilePath

/-- Every check of the linked test, in the order they run: its check set
(`Editor.CheckGroup`), each module's list in a group of its module of the
wiring set. -/
def LoginShellTest.Linked.checks :
    List (Editor.CheckGroup LoginShellTest.Linked.Context LoginShellTest.Check) :=
  [.wired "LoginShellTest.Linked.LoginShell.Contract"
      wiringSet.LoginShellTest.Linked.LoginShell.Contract fun (services, fixtures) =>
      LoginShellTest.Linked.loginShellContractChecks services fixtures,
    .wired "LoginShellTest.Linked.LoginShell.Real" wiringSet.LoginShellTest.Linked.LoginShell.Real
      fun (services, fixtures) => LoginShellTest.Linked.loginShellWiringChecks services fixtures]

/-- Runs the checks `mode` selects from the check set
(`Editor.CheckGroup.select`) over the real services, started here, and says
which failed, or how many passed. -/
private def LoginShellTest.Linked.runSelected (mode : Editor.CheckGroup.Mode) : IO UInt32 := do
  let fixtures ← IO.FS.realPath loginShellFixtures
  let running ← Editor.Test.Linked.Services.start
  let checks := Editor.CheckGroup.select mode LoginShellTest.Linked.checks (running.jobs, fixtures)
  let failed ← LoginShellTest.failures checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"login-shell linked test: {checks.length} {mode.what} passed"
  (← IO.getStdout).flush
  Editor.Test.Linked.shutdown
  IO.Process.exit (if failed.isEmpty then 0 else 1)

/-- Says the command lines it takes, and exits 2. -/
private def LoginShellTest.Linked.usage : IO UInt32 := do
  IO.eprintln
      "usage: LoginShellTest-Linked <sysroot> <core olean dir> <test grammars dir> [--wiring], or LoginShellTest-Linked wiring-modules"
  return 2

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["wiring-modules"] =>
    for module in Editor.CheckGroup.modules LoginShellTest.Linked.checks do
      IO.println module
    return 0
  | _ :: _ :: _ :: rest =>
    match Editor.CheckGroup.Mode.ofArguments? rest with
    | some mode =>
      LoginShellTest.Linked.runSelected mode
    | none =>
      LoginShellTest.Linked.usage
  | _ =>
    LoginShellTest.Linked.usage
