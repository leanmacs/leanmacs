import AgentsApiTest.Check
import AgentsApiTest.Linked.AgentsApi.Session
import Editor
import Editor.Test.Linked.Host
import Editor.Test.Linked.Services

/-!
# The linked test of the package `agents-api`

The root of an executable linked as the editor is linked (the core's
`editorLinked` facet, `lake build +AgentsApiTest.Linked:editorLinked`). The
gate builds it in `mise run lean` and runs it in `mise run ffi-test`
(`tools/package-set.sh`), in the package's directory, with the toolchain's
directory and the core's `.olean` directory as its arguments.

It makes the context of a harness of hosts over the real elaborator
(`Editor.Test.Linked.HostContext.run`, on the config base `Editor`, which it
imports for the link alone), and runs a session through the headless host
stepped on the check's thread, over the fake of the service `agents`
(`AgentsApiTest.Linked.sessionChecks`,
`AgentsApiTest/Linked/AgentsApi/Session.lean`): AC3. It starts no real
service and no real child.

Its checks are a check set (`AgentsApiTest.Linked.checks`, `Editor.CheckGroup`,
`docs/dev-practices/real-thread-checks.md`, "How the set runs") of one plain
group: it holds no module of the wiring set, so `wiring-modules` prints
nothing and `--wiring` selects no check and exits 0, building no host
(`Editor.CheckGroup.running`).
-/

/-- Every check of the linked test: its check set, the session's checks
through the stepped host in a plain group. -/
def AgentsApiTest.Linked.checks :
    List (Editor.CheckGroup Editor.Test.Linked.HostContext AgentsApiTest.Check) :=
  [.plain fun context => AgentsApiTest.Linked.sessionChecks context]

/-- Runs the checks `mode` selects from the check set
(`Editor.CheckGroup.select`) with the hosts' context, made with
`HostContext.run` over `sysroot` and `oleans`, and says which failed. The
exit is explicit, once the library's services are shut down and its queues
quit, as a host's is. -/
private def AgentsApiTest.Linked.runSelected (sysroot oleans : String)
    (mode : Editor.CheckGroup.Mode) : IO UInt32 := do
  let failed ←
    Editor.Test.Linked.HostContext.run sysroot oleans #[] fun context =>
        AgentsApiTest.failures (Editor.CheckGroup.select mode AgentsApiTest.Linked.checks context)
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println
        "agents-api linked test: a session's permission request is answered while its prompt is pending, on the stepped host over the fake"
  (← IO.getStdout).flush
  Editor.Test.Linked.shutdown
  IO.Process.exit (if failed.isEmpty then 0 else 1)

/-- Says the command lines it takes, and exits 2. -/
private def AgentsApiTest.Linked.usage : IO UInt32 := do
  IO.eprintln
      "usage: AgentsApiTest-Linked <sysroot> <core olean dir> <test grammars dir> [--wiring], or AgentsApiTest-Linked wiring-modules"
  return 2

/-- Runs the checks, all or with `--wiring` the wiring set's alone, and
exits 0 when all hold, 1 when one does not; with `--wiring` it selects no
check and exits 0 (`Editor.CheckGroup.running`); `wiring-modules` prints
the wiring set's modules, none; and 2 for a command line it does not
take. -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["wiring-modules"] =>
    for module in Editor.CheckGroup.modules AgentsApiTest.Linked.checks do
      IO.println module
    return 0
  | sysroot :: oleans :: _ :: rest =>
    match Editor.CheckGroup.Mode.ofArguments? rest with
    | some mode =>
      Editor.CheckGroup.running mode AgentsApiTest.Linked.checks
          (AgentsApiTest.Linked.runSelected sysroot oleans mode)
    | none =>
      AgentsApiTest.Linked.usage
  | _ =>
    AgentsApiTest.Linked.usage
