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
(`EchoTest.Linked.echoRealChecks`), and says so.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.EchoTest.Linked : Editor.WiringSet :=
  .edge "its main starts the library's services and pump and hands them to the echo contract"

/-- Runs the checks and exits 0 when all hold, 1 when one does not, and 2
for a command line that is not the two directories. The exit is explicit,
after the queues are quit, as the core's linked tests' is: a task may still
be blocked in the library. -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | [_, _] =>
    let services ← Editor.Test.Linked.Services.start
    let checks ← EchoTest.Linked.echoRealChecks services.completions
    let failed := checks.filter fun check => !check.2
    for check in failed do
      IO.eprintln s!"FAILED: {check.1}"
    if failed.isEmpty then
      IO.println
          s!"echo linked test: the contract's {checks.length} properties hold on the Rust-backed binding, each request completed through the completion queue"
    (← IO.getStdout).flush
    let stopped ← services.stop
    unless stopped do
      IO.eprintln "FAILED: the completion pump did not end once the queues were quit"
    IO.Process.exit (if failed.isEmpty && stopped then 0 else 1)
  | _ =>
    IO.eprintln "usage: EchoTest-Linked <sysroot> <core olean dir>"
    return 2
