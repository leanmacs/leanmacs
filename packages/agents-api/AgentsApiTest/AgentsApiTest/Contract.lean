import AgentsApiTest.Check
import AgentsApiTest.Contract
import AgentsApiTest.Fake

/-!
# Model tests: `AgentsApiTest/Contract.lean`

`contractFailures`: the contract of the service `agents` run against the
fake, which must hold every property; and `contractBiteChecks`: three
flawed fakes, each of which the contract must refuse on the property it
breaks, so a contract that stopped asking for a rule fails here. The test
driver's root, `AgentsApiTest/Model.lean`, runs them. The same contract runs
on `acp`'s crate in `acp`'s linked test.
-/

namespace AgentsApiTest

open AgentsApi

/-- hang guard: the fake finishes each wait at once, on the thread that makes
it, so only a property that waits for something never made reaches it, and
then fails as a hang. -/
def fakePatience : Editor.HangGuard :=
  .on "a completion the fake finishes at once" 1000

/-- A rig over a fresh fake breaking `flaws`, and a table of its own. -/
def fakeRig (flaws : Fake.Flaws := .none) (name : String := "the fake") : IO Contract.Rig := do
  let fake ← Fake.new (flaws := flaws)
  let completions ← Editor.Job.Completions.new
  return {
      name, service := fake.service completions, completions, patience := fakePatience
      opened := pure 0
      release := fun _ => pure () }

/-- The names of the contract's properties that do not hold of the fake, a
fresh one for each property. -/
def contractFailures : IO (List String) :=
  Contract.properties.filterMapM fun property => do
    let rig ← fakeRig
    try
      return if ← property.holds rig then none else some s!"the fake: {property.name}"
    catch error =>
      return some s!"the fake: {property.name} ({error})"

/-- Whether the property at `index` fails on a fake breaking `flaws`. -/
def bites (flaws : Fake.Flaws) (index : Nat) : IO Bool := do
  let some property := Contract.properties[index]? | return false
  let rig ← fakeRig flaws "a flawed fake"
  try
    return !(← property.holds rig)
  catch _ =>
    return true

/-- The checks that the contract bites. -/
def contractBiteChecks : List Check :=
  [{  name :=
        "the contract refuses a fake whose cancel leaves the turn's permission request parked, on the cancel's property"
      run := do
        saw (← bites { keepsAfterCancel := true } 2) "it held" },
    { name :=
        "the contract refuses a fake that takes a second answer to a ticket, on the answers' property"
      run := do
        saw (← bites { takesSecondAnswer := true } 3) "it held" },
    { name :=
        "the contract refuses a fake that completes a withdrawn next, on the withdrawn next's property"
      run := do
        saw (← bites { completesWithdrawn := true } 4) "it held" }]

end AgentsApiTest
