import Echo.Contract
import Echo.Model

/-!
# Model tests: `Echo/Model.lean`

The contract of the echo port (`Echo.Contract`) against its pure model, and
what holds of the model alone. The test driver's root, `EchoTest/Model.lean`,
runs them.
-/

namespace EchoTest

/-- The model as the contract's subject: ids from a counter, and a request
completed when its reply is held. -/
def modelSubject : IO Echo.Contract.Subject := do
  let model ← Echo.Model.new
  let next ← IO.mkRef (1 : UInt64)
  return {
      echo := model.echo
      fresh := next.modifyGet fun id => (id, id + 1)
      completed := model.completed
      endedNow := model.completed }

/-- The checks of the model, each with what must hold as a sentence: every
property of the contract, then the model's own. -/
def echoModelChecks : IO (List (String × Bool)) := do
  let failing ← Echo.Contract.failing (← modelSubject)
  let contract :=
    Echo.Contract.properties.map fun property =>
      (s!"the model: {property.name}", !failing.contains property.name)
  let model ← Echo.Model.new
  let started ← model.echo.start 1 "now"
  let completed ← model.completed 1
  return contract ++ [("the model completes a request the moment it starts", started && completed)]

end EchoTest
