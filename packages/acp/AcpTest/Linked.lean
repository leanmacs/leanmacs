import Acp.Packages
import AcpTest.Check
import AcpTest.Linked.Acp.Real.Contract
import AcpTest.Linked.Acp.Real.Session
import AgentsApiTest.Contract
import Editor.Headless
import Editor.RealHost
import Editor.Test.Linked.Services

/-!
# The linked test of the package `acp`

The root of an executable linked as the editor is linked (the core's
`editorLinked` facet, `lake build +AcpTest.Linked:editorLinked`), with the
core's glue, the package's glue and the Rust archive generated from the
package's own workspace, which holds the package's crate. The gate builds
it in `mise run lean` and runs it in `mise run ffi-test`
(`tools/package-set.sh`), in the package's directory, with the toolchain's
directory and the core's `.olean` directory as its arguments, which it
does not need: it runs no host and no config.

It starts the linked test kit's services and pump, and runs:

- `agents-api`'s contract against the crate's binding, each property on a
  scripted agent executable of its own (`AcpTest.Linked.contractChecks`,
  `AcpTest/Linked/Acp/Real/Contract.lean`);
- AC4, the crate on a real child through the process service, reached by
  running jobs through `agents-api`'s wrappers alone, given the package
  services the program's edge builds from acp's packages
  (`Editor.Headless.packageServices Acp.packages`, named here as only this
  root may import the headless host; `AcpTest.Linked.sessionChecks`,
  `AcpTest/Linked/Acp/Real/Session.lean`);

and says so. Its checks are a check set (`AcpTest.Linked.checks`,
`Editor.CheckGroup`, `docs/dev-practices/real-thread-checks.md`, "How the
set runs"): two groups, of its two modules of the wiring set, which the
build's `linter.wiringSet` holds true and complete. With `--wiring` after
the two directories it runs those groups alone, the stress loop's
`linked-wiring` suite (`tools/package-set.sh run --wiring`), and
`wiring-modules` prints their modules, one a line, building nothing.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.AcpTest.Linked : Editor.WiringSet :=
  .edge "its main starts the library's services and pump and hands them to the acp crate's checks"

/-- Every check of the linked test: its check set, the contract's one check
in the group of `AcpTest/Linked/Acp/Real/Contract.lean`, and AC4 in the
group of `AcpTest/Linked/Acp/Real/Session.lean`, over the package services
the edge builds from acp's packages. -/
def AcpTest.Linked.checks : List (Editor.CheckGroup Editor.Test.Linked.Services AcpTest.Check) :=
  [.wired "AcpTest.Linked.Acp.Real.Contract" wiringSet.AcpTest.Linked.Acp.Real.Contract
      fun services => AcpTest.Linked.contractChecks services,
    .wired "AcpTest.Linked.Acp.Real.Session" wiringSet.AcpTest.Linked.Acp.Real.Session
      fun services =>
      AcpTest.Linked.sessionChecks services (Editor.Headless.packageServices Acp.packages)]

/-- Runs the checks `mode` selects from the check set
(`Editor.CheckGroup.select`) with the services and pump, started here, and
says which failed, or that they held, and that the pump ended once the
queues were quit. The exit is explicit, after the queues are quit, as the
core's linked tests' is: a task may still be blocked in the library. -/
private def AcpTest.Linked.runSelected (mode : Editor.CheckGroup.Mode) : IO UInt32 := do
  let services ← Editor.Test.Linked.Services.start
  let failed ← AcpTest.failures (Editor.CheckGroup.select mode AcpTest.Linked.checks services)
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println
        s!"acp linked test: agents-api's {AgentsApiTest.Contract.properties.length} properties and AC4 hold on the acp crate over scripted agents, each request completed through the completion queue"
  (← IO.getStdout).flush
  let stopped ← services.stop
  unless stopped do
    IO.eprintln "FAILED: the completion pump did not end once the queues were quit"
  IO.Process.exit (if failed.isEmpty && stopped then 0 else 1)

/-- Says the command lines it takes, and exits 2. -/
private def AcpTest.Linked.usage : IO UInt32 := do
  IO.eprintln
      "usage: AcpTest-Linked <sysroot> <core olean dir> [--wiring], or AcpTest-Linked wiring-modules"
  return 2

/-- Runs the checks, all or with `--wiring` the wiring set's alone, and
exits 0 when all hold, 1 when one does not; `wiring-modules` prints the
wiring set's modules; and 2 for a command line it does not take. -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["wiring-modules"] =>
    for module in Editor.CheckGroup.modules AcpTest.Linked.checks do
      IO.println module
    return 0
  | _ :: _ :: rest =>
    match Editor.CheckGroup.Mode.ofArguments? rest with
    | some mode =>
      AcpTest.Linked.runSelected mode
    | none =>
      AcpTest.Linked.usage
  | _ =>
    AcpTest.Linked.usage
