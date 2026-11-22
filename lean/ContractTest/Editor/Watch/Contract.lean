import Editor.Event
import Editor.Event.Queue
import Editor.Ffi.Events
import Editor.Ffi.Interrupt
import Editor.Job.Runner
import Editor.Program
import Editor.Watch
import Editor.Watch.Contract
import Editor.Watch.Real

/-!
# Contract tests: `Editor/Watch/Contract.lean`

The tests of `Editor/Watch/Contract.lean`: `watchFailures`, the watch port's
contract against the real binding. The root module `ContractTest` runs them; its
module doc says what each shows.
-/

namespace ContractTest

open Editor

/-- Runs a property of the watch port's contract against the real binding
over `timers`. The library is told the interrupt key, and the property's
interrupt keys arrive through the library's window input, as a window's
would, before `holds` runs. Afterwards the events are taken off the editor
queue, the flag is lowered for whatever `holds` left up, and the library is
left with no interrupt key, so the next property starts with the flag down
and the queue empty. `false` when a key could not be posted. -/
def runOnWatch (timers : Job.Timers) (property : WatchContract.Property) : IO Bool := do
  unless ← Event.setInterruptKey (some Watch.interruptKey) do
    return false
  try
    let mut posted := 0
    for _ in [0:property.arrived] do
      if ← Event.post (.key Watch.interruptKey true "") then
        posted := posted + 1
    let held ← Program.runM (port := watchPort) (Watch.real timers) property.holds
    for _ in [0:posted] do
      discard <| Ffi.takeQueued .editor
      Ffi.interruptLower
    return held && posted == property.arrived && !(← Ffi.interruptRaised)
  finally
    discard <| Event.setInterruptKey none

/-- The names of the watch port's contract properties that do not hold of
the real binding over `timers`. -/
def watchFailures (timers : Job.Timers) : IO (List String) := do
  let failed ← WatchContract.failures (runOnWatch timers) WatchContract.properties
  return failed.map (s!"the real watch binding: {·}")

end ContractTest
