import Acp.Packages
import AcpTest.Check
import AcpTest.Linked.Acp.Conversation
import AcpTest.Linked.Acp.Permissions
import AcpTest.Linked.Acp.Real.Contract
import AcpTest.Linked.Acp.Real.InstalledSet
import AcpTest.Linked.Acp.Real.Load
import AcpTest.Linked.Acp.Real.Session
import AcpTest.Linked.Acp.Table
import AgentsApiTest.Contract
import Editor
import Editor.Headless
import Editor.RealHost
import Editor.Test.Linked.Host
import Editor.Test.Linked.Services

/-!
# The linked test of the package `acp`

The root of an executable linked as the editor is linked (the core's
`editorLinked` facet, `lake build +AcpTest.Linked:editorLinked`), with the
core's glue, the package's glue and the core's Rust archive; the package's
crate is a library of its own, staged under the package's
`.lake/build/libraries/acp/`, which `Acp.Real`'s initialiser loads before
`main`. The gate builds
it in `mise run lean` and runs it in `mise run ffi-test`
(`tools/package-set.sh`), in the package's directory, with the toolchain's
directory and the core's `.olean` directory as its arguments.

It makes the context of a harness of hosts over the real elaborator
(`Editor.Test.Linked.HostContext.run`, on the config base `Editor`, which it
imports for the link alone), starts the linked test kit's services and
pump, one pump a process, which only the wired groups use, and runs:

- the conversation through a host stepped on the check's thread over
  `agents-api`'s fake (`AcpTest.Linked.conversationChecks`,
  `AcpTest/Linked/Acp/Conversation.lean`): AC1 to AC4 of the
  sessions-and-conversation phase, the commands' refusals and the close of
  a conversation buffer, handed `Acp.packages`, which only this root may
  import since they bring the library's binding;
- the queue of a project's permission requests, the policy and the audit
  log through the same stepped host (`AcpTest.Linked.permissionChecks`,
  `AcpTest/Linked/Acp/Permissions.lean`): AC2 to AC4 of the permissions
  phase, silence, the queue's refusals and prompt, and the close of a
  queue buffer, likewise handed `Acp.packages`;
- the agent table, the stall watchdog, the agents list and resume through
  the same stepped host, two of them in turn across a restart over the
  journal's recording fake (`AcpTest.Linked.tableChecks`,
  `AcpTest/Linked/Acp/Table.lean`): AC2 to AC5 of the agent-table phase,
  likewise handed `Acp.packages`;

- the load of acp's library through its glue and the core's loader
  (`AcpTest.Linked.acpLoadChecks`, `AcpTest/Linked/Acp/Real/Load.lean`, a
  plain group);
- `agents-api`'s contract against the library's binding, each property on a
  scripted agent executable of its own (`AcpTest.Linked.contractChecks`,
  `AcpTest/Linked/Acp/Real/Contract.lean`);
- AC4, the library on a real child through the process service, reached by
  running jobs through `agents-api`'s wrappers alone, given the package
  services the program's edge builds from acp's packages
  (`Editor.Headless.packageServices Acp.packages`, named here as only this
  root may import the headless host; `AcpTest.Linked.sessionChecks`,
  `AcpTest/Linked/Acp/Real/Session.lean`);
- a config laid out as `install --agents` leaves it, with acp's library
  already built in its `lib/`, built with the toolchain's `lake` under the
  sysroot it is handed, through the real process port, with no `cargo` on
  the child's `PATH`, and its editor's probe, which passes only once acp's
  library loaded from the config's build
  (`AcpTest.Linked.acpInstalledSetChecks`,
  `AcpTest/Linked/Acp/Real/InstalledSet.lean`);

and says so. Its checks are a check set (`AcpTest.Linked.checks`,
`Editor.CheckGroup`, `docs/dev-practices/real-thread-checks.md`, "How the
set runs"): the conversation's, the permissions', the table's and the
load's checks in a plain group each, then three groups,
of its three modules of the wiring set, which the build's `linter.wiringSet`
holds true and complete. With `--wiring` after
the three arguments it runs those groups alone, the stress loop's
`linked-wiring` suite (`tools/package-set.sh run --wiring`), and
`wiring-modules` prints their modules, one a line, building nothing.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.AcpTest.Linked : Editor.WiringSet :=
  .edge
    "its main starts the library's services and pump and hands them to the checks of acp's library"

/-- What every check is handed: the harness's context and the services
started for the run (`Services.start`). -/
abbrev AcpTest.Linked.Context :=
  Editor.Test.Linked.HostContext × Editor.Test.Linked.Services

/-- Every check of the linked test: its check set, the conversation's, the
permissions' and the table's checks over `Acp.packages` and the load's checks in a plain
group each, the contract's one check in the group
of `AcpTest/Linked/Acp/Real/Contract.lean`, and AC4 in the group of
`AcpTest/Linked/Acp/Real/Session.lean`, over the package services the edge
builds from acp's packages, and the installed config's build in the group
of `AcpTest/Linked/Acp/Real/InstalledSet.lean`, over the sysroot the
context was made with. -/
def AcpTest.Linked.checks : List (Editor.CheckGroup AcpTest.Linked.Context AcpTest.Check) :=
  [.plain fun (context, _) => AcpTest.Linked.conversationChecks context Acp.packages,
    .plain fun (context, _) => AcpTest.Linked.permissionChecks context Acp.packages,
    .plain fun (context, _) => AcpTest.Linked.tableChecks context Acp.packages,
    .plain fun _ => AcpTest.Linked.acpLoadChecks,
    .wired "AcpTest.Linked.Acp.Real.Contract" wiringSet.AcpTest.Linked.Acp.Real.Contract
      fun (_, services) => AcpTest.Linked.contractChecks services,
    .wired "AcpTest.Linked.Acp.Real.Session" wiringSet.AcpTest.Linked.Acp.Real.Session
      fun (_, services) =>
      AcpTest.Linked.sessionChecks services (Editor.Headless.packageServices Acp.packages),
    .wired "AcpTest.Linked.Acp.Real.InstalledSet" wiringSet.AcpTest.Linked.Acp.Real.InstalledSet
      fun (context, services) => AcpTest.Linked.acpInstalledSetChecks context.sysroot services]

/-- Runs the checks `mode` selects from the check set
(`Editor.CheckGroup.select`) with the hosts' context, made with
`HostContext.run` over `sysroot` and `oleans`, and the services and pump,
started here, and says which failed, or that they held, and that the pump
ended once the queues were quit. The exit is explicit, after the queues are
quit, as the core's linked tests' is: a task may still be blocked in the
library. -/
private def AcpTest.Linked.runSelected (sysroot oleans : String) (mode : Editor.CheckGroup.Mode) :
    IO UInt32 := do
  let (failed, services) ←
    Editor.Test.Linked.HostContext.run sysroot oleans #[] fun context => do
        let services ← Editor.Test.Linked.Services.start
        let failed ←
          AcpTest.failures (Editor.CheckGroup.select mode AcpTest.Linked.checks (context, services))
        return (failed, services)
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println
        s!"acp linked test: the conversation and the permissions hold on the stepped host over agents-api's fake, and agents-api's {AgentsApiTest.Contract.properties.length} properties and AC4 hold on acp's library over scripted agents, each request completed through the completion queue"
  (← IO.getStdout).flush
  let stopped ← services.stop
  unless stopped do
    IO.eprintln "FAILED: the completion pump did not end once the queues were quit"
  IO.Process.exit (if failed.isEmpty && stopped then 0 else 1)

/-- Says the command lines it takes, and exits 2. -/
private def AcpTest.Linked.usage : IO UInt32 := do
  IO.eprintln
      "usage: AcpTest-Linked <sysroot> <core olean dir> <test grammars dir> [--wiring], or AcpTest-Linked wiring-modules"
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
  | sysroot :: oleans :: _ :: rest =>
    match Editor.CheckGroup.Mode.ofArguments? rest with
    | some mode =>
      AcpTest.Linked.runSelected sysroot oleans mode
    | none =>
      AcpTest.Linked.usage
  | _ =>
    AcpTest.Linked.usage
