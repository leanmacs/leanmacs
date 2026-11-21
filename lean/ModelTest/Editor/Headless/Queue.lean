import Editor.Headless.Queue
import Editor.Headless.Queue.Contract
import ModelTest.Check

/-!
# Model tests: `Editor/Headless/Queue.lean`

The tests of the editor queue port's in-memory queue: `queueContractChecks`,
the port's contract (`Editor/Headless/Queue/Contract.lean`) run against
`Queue.Memory`, taken back with `take?`, and `queueMemoryChecks`, what only
the memory queue has: its next-push task (`arrived`) and its close. The
root module `ModelTest` runs them.
-/

namespace ModelTest

open Editor
open Editor.Headless

/-- A rig over a memory queue of its own. -/
def queueMemoryRig : BaseIO QueueContract.QueueRig := do
  let memory ← Queue.Memory.new (α := Posted)
  return {
      name := "the in-memory queue"
      queue := memory.queue id
      source := 7
      take := do
        let some posted ← memory.take? | throw (IO.userError "the queue is empty")
        return posted
      left := memory.size }

/-- The editor queue port's contract on the in-memory queue. -/
def queueContractChecks : List Check :=
  [{  name := "the contract of the editor queue port holds of the in-memory queue"
      run := do
        let failed ← QueueContract.failures (← queueMemoryRig)
        unless failed.isEmpty do
          throw <| IO.userError s!"{failed}"
        return true }]

/-- What only the in-memory queue has: its next-push task and its close. -/
def queueMemoryChecks : List Check :=
  [{  name :=
        "the next-push task ends at the next push and not before, and a push made before it was asked leaves it open with the item queued"
      run := do
        let memory ← Queue.Memory.new (α := Nat)
        discard <| memory.push 1
        let arrived ← memory.arrived
        let early ← IO.hasFinished arrived
        let queued ← memory.size
        discard <| memory.push 2
        let late ← IO.hasFinished arrived
        return !early && queued == 1 && late },
    { name :=
        "a push after the close is refused, the waiter is woken, and what was queued is still taken"
      run := do
        let memory ← Queue.Memory.new (α := Nat)
        let before ← memory.push 1
        let arrived ← memory.arrived
        memory.close
        let woken ← IO.hasFinished arrived
        let after ← memory.push 2
        let first ← memory.take?
        let second ← memory.take?
        let closedArrived ← IO.hasFinished (← memory.arrived)
        return before && woken && !after && first == some 1 && second == none && closedArrived },
    { name := "the memory queue's port posts each post as its item, and says a stepper takes them"
      run := do
        let memory ← Queue.Memory.new (α := UInt64)
        let port := memory.queue (·.code)
        let took ← port.post { source := 3, code := 9 }
        return took && (← memory.take?) == some 9 && port.pulledBy == .stepper }]

end ModelTest
