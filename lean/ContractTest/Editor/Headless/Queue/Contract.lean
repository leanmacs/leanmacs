import ContractTest.Check
import Editor.Ffi.Events
import Editor.Headless.Queue
import Editor.Headless.Queue.Contract
import Editor.Headless.Queue.Real

/-!
# Contract tests: `Editor/Headless/Queue/Contract.lean`

The editor queue port's contract run against its real binding, the
library's editor queue (`Queue.library`, `Editor/Headless/Queue/Real.lean`):
`queueContractChecks`. The rig posts under a Lean source id no other check
of this run posts under (`queueSource`), and takes a post back with a pull
of the editor queue, passing over any event of another source: a take is
made only after a post, so a pull never parks. What is left of the rig's
posts is counted by posting a marker under the same source, which the queue
hands back after everything posted before it, and pulling up to it. The
root module `ContractTest` runs them.
-/

namespace ContractTest

open Editor
open Editor.Headless

/-- The Lean source id the queue checks post under: no other check of this
run posts under it. -/
def queueSource : UInt64 :=
  0x5157

/-- The code of the marker `queueLibraryRig` counts what is left with: no
property posts it. -/
def queueMarker : UInt64 :=
  0xFFFF

/-- The next event of the editor queue posted under `queueSource`, passing
over any of another source. Called only once one has been posted; it never
parks (`takeQueued`), so one that is not there throws, a failure, not a
wait for good. -/
partial def pullQueued : IO Ffi.Event := do
  let some event ←
    Ffi.takeQueued
        .editor | throw (IO.userError "the editor queue holds no event posted under the queue checks' source")
  if event.source.kind == .lean && event.source.id == queueSource then
    return event
  pullQueued

/-- The rig of the library's editor queue. -/
def queueLibraryRig : QueueContract.QueueRig where
  name := "the library's editor queue"
  queue := Queue.library
  source := queueSource
  take := do
    let event ← pullQueued
    return { source := event.source.id, code := event.code, text := event.text }
  left := do
    unless ← Queue.library.post { source := queueSource, code := queueMarker } do
      throw (IO.userError "the editor queue refused the marker")
    let mut left := 0
    repeat
      let event ← pullQueued
      if event.code == queueMarker then
        break
      left := left + 1
    return left

/-- The editor queue port's contract on the library's editor queue. -/
def queueContractChecks : List Check :=
  [{  name := "the contract of the editor queue port holds of the library's editor queue"
      run := do
        let failed ← QueueContract.failures queueLibraryRig
        unless failed.isEmpty do
          throw <| IO.userError s!"{failed}"
        return true }]

end ContractTest
