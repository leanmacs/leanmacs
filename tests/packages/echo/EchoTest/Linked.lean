import Echo.Contract
import Echo.Packages
import EchoTest.Check
import EchoTest.Linked.Echo.Packages
import EchoTest.Linked.Echo.Real
import EchoTest.Linked.Echo.Real.Attach
import EchoTest.Linked.Echo.Real.Job
import Editor
import Editor.RealHost
import Editor.Test.Linked.Host
import Editor.Test.Linked.Services

/-!
# The linked test of the package `echo`

The root of an executable linked as the editor is linked (the core's
`editorLinked` facet, `lake build +EchoTest.Linked:editorLinked`), with the
core's glue, the package's glue and the Rust archive generated from the
package's own workspace, which holds the package's crate. The gate builds
it in `mise run lean` and runs it in `mise run ffi-test`
(`tools/package-set.sh`), in the package's directory, with the toolchain's
directory and the core's `.olean` directory as its arguments.

It makes the context of a harness of hosts over the real elaborator
(`Editor.Test.Linked.HostContext.run`, on the config base `Editor`, which
it imports for the link alone, with the package `echo`), starts the linked
test kit's services and pump, and runs:

- the package through the headless host stepped on the check's thread,
  its service the fake over echo's model (`EchoTest.Linked.echoPackageChecks`,
  `EchoTest/Linked/Echo/Packages.lean`): a running job's `say`, and the
  two forced orders of a cancel of a job that handed its child over;
- the contract of the echo port against the Rust-backed binding over the
  real services (`EchoTest.Linked.echoRealChecks`, one check over one
  subject);
- the checks of a child the core's process service opened and the
  package's crate took over (`EchoTest.Linked.attachChecks`);
- the crate's service reached by running jobs through the runner's package
  port (`EchoTest.Linked.echoJobChecks`, `EchoTest/Linked/Echo/Real/Job.lean`);

and says so, counting the contract's properties.

Its checks are a check set (`EchoTest.Linked.checks`, `Editor.CheckGroup`,
`docs/dev-practices/real-thread-checks.md`, "How the set runs"):
the lists of its modules of the wiring set in groups of their module, which
the build's `linter.wiringSet` holds true and complete. With `--wiring`
after the two directories it
runs those groups alone, the stress loop's `linked-wiring` suite
(`tools/package-set.sh run --wiring`), and `wiring-modules` prints their
modules, one a line, building nothing.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.EchoTest.Linked : Editor.WiringSet :=
  .edge "its main starts the library's services and pump and hands them to the echo contract"

/-- What every check is handed: the harness's context, and the services
`main` starts. -/
abbrev EchoTest.Linked.Context :=
  Editor.Test.Linked.HostContext × Editor.Test.Linked.Services

/-- Every check of the linked test: its check set (`Editor.CheckGroup`), the
package's checks through the stepped host in a plain group, the contract's
one check in the group of `EchoTest/Linked/Echo/Real.lean`, the take-over's
checks in the group of `EchoTest/Linked/Echo/Real/Attach.lean`, and the
running jobs' checks in the group of `EchoTest/Linked/Echo/Real/Job.lean`,
the last three of the wiring set. -/
def EchoTest.Linked.checks : List (Editor.CheckGroup EchoTest.Linked.Context EchoTest.Check) :=
  [.plain fun (context, _) => EchoTest.Linked.echoPackageChecks context,
    .wired "EchoTest.Linked.Echo.Real" wiringSet.EchoTest.Linked.Echo.Real fun (_, services) =>
      EchoTest.Linked.echoRealChecks services.completions,
    .wired "EchoTest.Linked.Echo.Real.Attach" wiringSet.EchoTest.Linked.Echo.Real.Attach
      fun (_, services) => EchoTest.Linked.attachChecks services,
    .wired "EchoTest.Linked.Echo.Real.Job" wiringSet.EchoTest.Linked.Echo.Real.Job
      fun (_, services) => EchoTest.Linked.echoJobChecks services]

/-- Runs the checks `mode` selects from the check set
(`Editor.CheckGroup.select`) with the hosts' context, made with
`HostContext.run` over `sysroot` and `oleans`, and the services and pump,
started here, and says which failed, or that the contract's properties
held, and that the pump ended once the queues were quit. The exit is
explicit, after the queues are quit, as the core's linked tests' is: a task
may still be blocked in the library. -/
private def EchoTest.Linked.runSelected (sysroot oleans : String) (mode : Editor.CheckGroup.Mode) :
    IO UInt32 := do
  let services ← Editor.Test.Linked.Services.start
  let failed ←
    Editor.Test.Linked.HostContext.run sysroot oleans Echo.packages fun context =>
        EchoTest.failures (Editor.CheckGroup.select mode EchoTest.Linked.checks (context, services))
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println
        s!"echo linked test: the contract's {Echo.Contract.properties.length} properties hold on the Rust-backed binding, each request completed through the completion queue"
  (← IO.getStdout).flush
  let stopped ← services.stop
  unless stopped do
    IO.eprintln "FAILED: the completion pump did not end once the queues were quit"
  IO.Process.exit (if failed.isEmpty && stopped then 0 else 1)

/-- Says the command lines it takes, and exits 2. -/
private def EchoTest.Linked.usage : IO UInt32 := do
  IO.eprintln
      "usage: EchoTest-Linked <sysroot> <core olean dir> [--wiring], or EchoTest-Linked wiring-modules"
  return 2

/-- Runs the checks, all or with `--wiring` the wiring set's alone, and
exits 0 when all hold, 1 when one does not; `wiring-modules` prints the
wiring set's modules; and 2 for a command line it does not take. -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["wiring-modules"] =>
    for module in Editor.CheckGroup.modules EchoTest.Linked.checks do
      IO.println module
    return 0
  | sysroot :: oleans :: rest =>
    match Editor.CheckGroup.Mode.ofArguments? rest with
    | some mode =>
      EchoTest.Linked.runSelected sysroot oleans mode
    | none =>
      EchoTest.Linked.usage
  | _ =>
    EchoTest.Linked.usage
