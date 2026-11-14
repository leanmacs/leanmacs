import Editor.Ffi
import Editor.Job.Runner
import Editor.Watch

/-!
# The watch port's real binding

The watch port (`Editor/Watch.lean`) answered by the Rust library and the
job port's clock (`Watch.real`):

- `interrupted` is the library's interrupt flag (`Ffi.interruptRaised`),
  which the library raises as the interrupt key arrives on the editor
  queue;
- `lower` tells the library that one interrupt key was taken off the queue
  (`Ffi.interruptLower`);
- `now` reads the clock the runner's waits are made of (`Job.Timers.now`):
  the library's timer service in the executable, and a fake clock in a
  test, so that one clock moves the jobs and the loop's measure of a
  command.

This module adds no decision: each request is one call. It imports
`Editor.Ffi`, so only an executable linked with the library imports it.

`contract-test` holds it to the watch port's contract
(`Editor/Watch/Contract.lean`), the list `model-test` holds the model to,
and `ContractTest.watchChecks` pins what only it shows.
-/

namespace Editor

/-- The watch port answered by the library's interrupt flag, and by the
clock of `timers`. -/
def Watch.real (timers : Job.Timers) : WatchHandler
  | .interrupted => Ffi.interruptRaised
  | .lower => Ffi.interruptLower
  | .now => timers.now

end Editor
