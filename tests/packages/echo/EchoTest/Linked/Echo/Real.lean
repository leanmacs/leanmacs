import Echo.Contract
import Echo.Real
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Services

/-!
# Linked tests: `Echo/Real.lean`

The contract of the echo port (`Echo.Contract`) against the Rust-backed
binding, over the linked test kit's table of waits and its completion pump
(`Editor.Test.Linked.Services.start`), the same queue and pump the editor
runs. Each id a property uses is a wait registered in that table, and a
request has completed when its wait has ended: the pump ends it only for a
completion on the completion queue whose code is the id, which only the
crate's service posts for it.
-/

namespace EchoTest.Linked

open Editor

/-- The binding as the contract's subject, over the table of waits
`completions`, whose pump is running: each fresh id is a wait registered
there, and a request has completed when the pump ended its wait as
completed, waited for on the wait itself, the kit's patience a hang guard. -/
def realSubject (completions : Job.Completions) : IO Echo.Contract.Subject := do
  let waits ← IO.mkRef (∅ : Std.HashMap UInt64 (IO.Promise Job.Completion))
  return {
      echo := Echo.Real.real
      fresh := do
        let (id, wait) ← completions.register
        waits.modify (·.insert id wait)
        return id
      completed := fun id => do
        let some wait := (← waits.get)[id]? | return false
        -- Waited for on the wait itself; the kit's patience is a hang guard.
        let ended ← Job.awaitWithin Test.Linked.patience wait.result?
        return ended == some (some .completed) }

/-- The checks of the binding, each with what must hold as a sentence: every
property of the contract, over `completions`. -/
def echoRealChecks (completions : Job.Completions) : IO (List (String × Bool)) := do
  let failing ← Echo.Contract.failing (← realSubject completions)
  return Echo.Contract.properties.map fun property =>
      (s!"the Rust-backed binding: {property.name}", !failing.contains property.name)

end EchoTest.Linked
