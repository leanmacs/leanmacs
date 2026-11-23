import Editor.SyntaxTree.DeliveryContract
import Editor.SyntaxTree.Fake
import ModelTest.Check

/-!
# Model tests: `Editor/SyntaxTree/DeliveryContract.lean`

The contract of the syntax service's deliveries run over the fake
(`FakeSyntaxService`): `syntaxDeliveryChecks`, one check per property, each
on a fake of its own whose texts the rig makes in its model, an edit a new
snapshot of the same text (`SyntaxTreeModel.documents`), and whose `settle`
steps the fake until the text has nothing pending. Beside them, what only
the fake shows: before a step the undelivered revision's captures are
refused as not parsed, each step posts exactly once on the stepping thread,
every request is recorded on the check's thread, and the fake is quiescent
once stepped to its end. The root module `ModelTest` runs them.
-/

namespace ModelTest

open Editor

/-- A rig over a fake of its own, and the fake. -/
def deliveryFakeRig : BaseIO (SyntaxDeliveryContract.DeliveryRig × FakeSyntaxService) := do
  let fake ← FakeSyntaxService.new
  let make (document : Option Nat) (contents : String) : IO SnapshotId :=
    fake.state.modifyGet fun state =>
      let id : SnapshotId := ⟨state.model.texts.size⟩
      let number := document.getD state.model.texts.size
      (id,
        { state with
          model :=
            { state.model with
              texts := state.model.texts.push (id, contents)
              documents := state.model.documents.push (id, number) } })
  let rig : SyntaxDeliveryContract.DeliveryRig :=
    { name := "the fake syntax service", handler := fake.handle, make := make none
      edit := fun snapshot contents => do
        let state ← fake.state.get
        let document := (state.model.documents.find? (·.1 == snapshot)).map (·.2)
        make document contents
      settle := fun snapshot => fake.settle snapshot }
  return (rig, fake)

/-- The contract of the deliveries on the fake, and the fake's own
promises. -/
def syntaxDeliveryChecks : List Check :=
  (SyntaxDeliveryContract.properties.map fun property =>
      { name := s!"the fake syntax service keeps the delivery contract: {property.name}"
        run := do
          let (rig, fake) ← deliveryFakeRig
          return (← property.holds rig) && (← fake.quiescent) }) ++
    [{  name :=
          "the fake syntax service refuses the captures of an attached text as not parsed until its delivery is stepped, and each step posts exactly once, on the stepping thread: here the check's own, as every request is"
        run := do
          let (rig, fake) ← deliveryFakeRig
          let thread ← IO.getTID
          let snapshot ← rig.make SyntaxDeliveryContract.first
          discard <| (SyntaxTree.attach snapshot "json").runWith rig.handler
          let .ok compiled ←
            (SyntaxTree.compile "json" SyntaxDeliveryContract.query).runWith rig.handler |
            return false
          let before ←
            SyntaxDeliveryContract.capturesOf rig snapshot compiled SyntaxDeliveryContract.first
          let postsBefore ← fake.posts
          let stepped ← fake.step
          let after ←
            SyntaxDeliveryContract.capturesOf rig snapshot compiled SyntaxDeliveryContract.first
          let again ← fake.step
          let posts ← fake.postThreads
          let requests ← fake.requestThreads
          unless SyntaxDeliveryContract.same before (.error .notParsed) && postsBefore == 0 &&
                stepped && SyntaxDeliveryContract.same after
                  (SyntaxDeliveryContract.modelAnswer SyntaxDeliveryContract.first) && !again &&
                posts == #[thread] && requests.all (· == thread) && (← fake.quiescent) do
            throw <|
                IO.userError
                  s!"before the step {SyntaxDeliveryContract.shown before}, after it {SyntaxDeliveryContract.shown after}; posts on {posts}, requests on {requests}, the check's thread {thread}"
          return true },
      { name :=
          "the fake syntax service makes a new snapshot of an attached text pending, and is quiescent once stepped to its end"
        run := do
          let (rig, fake) ← deliveryFakeRig
          let snapshot ← rig.make SyntaxDeliveryContract.first
          discard <| (SyntaxTree.attach snapshot "json").runWith rig.handler
          fake.settleAll
          let next ← rig.edit snapshot SyntaxDeliveryContract.edited
          discard <| (SyntaxTree.captures next ⟨0⟩ 0 0).runWith rig.handler
          let pending := !(← fake.quiescent)
          fake.settleAll
          return pending && (← fake.quiescent) && (← fake.posts) == 2 }]

end ModelTest
