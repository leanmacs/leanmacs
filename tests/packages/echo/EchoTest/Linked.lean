import Echo.Contract
import EchoTest.Check
import EchoTest.Linked.Echo.Real
import Editor.RealHost
import Editor.Test.Linked.Services

/-!
# The linked test of the package `echo`

The root of an executable linked as the editor is linked (the core's
`editorLinked` facet, `lake build +EchoTest.Linked:editorLinked`), with the
core's glue, the package's glue and the Rust archive generated from the
package's own workspace, which holds the package's crate. The gate builds
it in `mise run lean` and runs it in `mise run ffi-test`
(`tools/package-set.sh`), in the package's directory, with the toolchain's
directory and the core's `.olean` directory as its arguments, which it does
not need.

It starts the linked test kit's services and pump, runs the contract of the
echo port against the Rust-backed binding over them
(`EchoTest.Linked.echoRealChecks`, one check over one subject), and says
so, counting the contract's properties.

Its checks are a check set (`EchoTest.Linked.checks`, `Editor.CheckGroup`,
`docs/dev-practices/real-thread-checks.md`, "How stress runs the set"):
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

/-- Every check of the linked test, over the completions of the services
`main` starts: its check set (`Editor.CheckGroup`), the contract's one
check in the group of `EchoTest/Linked/Echo/Real.lean`, of the wiring set. -/
def EchoTest.Linked.checks : List (Editor.CheckGroup Editor.Job.Completions EchoTest.Check) :=
  [.wired "EchoTest.Linked.Echo.Real" wiringSet.EchoTest.Linked.Echo.Real fun completions =>
      EchoTest.Linked.echoRealChecks completions]

/-- Runs the checks `mode` selects from the check set
(`Editor.CheckGroup.select`) over the services and
pump, started here, and says which failed, or that the contract's
properties held, and that the pump ended once the queues were quit. The exit is explicit, after the queues are quit, as the core's
linked tests' is: a task may still be blocked in the library. -/
private def EchoTest.Linked.runSelected (mode : Editor.CheckGroup.Mode) : IO UInt32 := do
  let services ← Editor.Test.Linked.Services.start
  let failed ←
    EchoTest.failures (Editor.CheckGroup.select mode EchoTest.Linked.checks services.completions)
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
  | _ :: _ :: rest =>
    match Editor.CheckGroup.Mode.ofArguments? rest with
    | some mode =>
      EchoTest.Linked.runSelected mode
    | none =>
      EchoTest.Linked.usage
  | _ =>
    EchoTest.Linked.usage
