import Editor.SyntaxTree.DeliveryContract
import Editor.SyntaxTree.Fake
import ModelTest.Check

/-!
# Model tests: `Editor/SyntaxTree/Fake.lean`

What the fake of the syntax service's deliveries (`FakeSyntaxService`)
promises of itself beyond the delivery contract
(`ModelTest.syntaxDeliveryChecks`): `syntaxFakeChecks`. A snapshot the
model does not know is learnt through `learn`, once; a highlight and an
injection of an attached text each make its delivery pending; and a detach
drops a pending delivery, so the fake is quiescent with no step. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The text `learnCheck`'s fake learns. -/
def learntSnapshot : SnapshotId :=
  ⟨5⟩

/-- A fake with an empty model whose `learn` answers `SyntaxDeliveryContract.first`
for `learntSnapshot` alone, and counts its calls in `asked`. -/
def learningFake (asked : IO.Ref (Array SnapshotId)) : BaseIO FakeSyntaxService :=
  FakeSyntaxService.new (learn := fun snapshot => do
    asked.modify (·.push snapshot)
    return if snapshot == learntSnapshot then some SyntaxDeliveryContract.first else none)

/-- The captures of the whole of `snapshot`, holding `contents`, through
`fake`. -/
def fakeCaptures (fake : FakeSyntaxService) (snapshot : SnapshotId) (compiled : QueryId)
    (contents : String) : IO (Except SyntaxTreeError (Array SyntaxTree.Capture)) :=
  (SyntaxTree.captures snapshot compiled 0 contents.utf8ByteSize).runWith fake.handle

/-- An attached text of `fake`, its delivery stepped, and the query
compiled. -/
def settledAttach (fake : FakeSyntaxService) (snapshot : SnapshotId) : IO QueryId := do
  let .ok () ←
    (SyntaxTree.attach snapshot "json").runWith
        fake.handle | throw <| IO.userError "the attach was refused"
  fake.settleAll
  let .ok compiled ←
    (SyntaxTree.compile "json" SyntaxDeliveryContract.query).runWith
        fake.handle | throw <| IO.userError "the query was refused"
  return compiled

/-- The fake asks `learn` for a snapshot its model does not know the first
time a request names it, and the answer is the text the questions are
answered over; a snapshot it knows is not asked again, and one `learn` does
not know is refused as the model refuses it. -/
def learnCheck : Check :=
  { name :=
      "the fake syntax service learns a snapshot it does not know through `learn` the first time a request names it, answers over the learnt text, asks no more once it knows it, and refuses one `learn` does not know as no such snapshot"
    run := do
      let asked ← IO.mkRef #[]
      let fake ← learningFake asked
      let compiled ← settledAttach fake learntSnapshot
      let answer ← fakeCaptures fake learntSnapshot compiled SyntaxDeliveryContract.first
      let unknown ← (SyntaxTree.attach ⟨6⟩ "json").runWith fake.handle
      let calls ← asked.get
      let refused :=
        match unknown with
        | .error .noSuchSnapshot => true
        | _ => false
      unless
        SyntaxDeliveryContract.same answer
            (SyntaxDeliveryContract.modelAnswer SyntaxDeliveryContract.first) &&
          calls == #[learntSnapshot, ⟨6⟩] &&
          refused do
        throw <|
            IO.userError
              s!"answered {SyntaxDeliveryContract.shown answer}, learn asked for {repr calls}, the unknown attach refused {refused}"
      return true }

/-- A highlight and an injection of an attached text each make its delivery
pending, and each step of it posts once. -/
def highlightInjectCheck : Check :=
  { name :=
      "the fake syntax service makes an attached text's delivery pending on a highlight and on an injection, and each is posted once by its step"
    run := do
      let asked ← IO.mkRef #[]
      let fake ← learningFake asked
      let compiled ← settledAttach fake learntSnapshot
      let postsBefore ← fake.posts
      let .ok () ←
        (SyntaxTree.highlight learntSnapshot compiled #[none]).runWith fake.handle | return false
      let highlighted := !(← fake.quiescent)
      fake.settleAll
      let afterHighlight ← fake.posts
      let .ok () ← (SyntaxTree.inject learntSnapshot compiled).runWith fake.handle | return false
      let injected := !(← fake.quiescent)
      fake.settleAll
      let afterInject ← fake.posts
      unless
        highlighted && injected && afterHighlight == postsBefore + 1 &&
          afterInject == postsBefore + 2 &&
          (← fake.quiescent) do
        throw <|
            IO.userError
              s!"pending after the highlight {highlighted}, after the injection {injected}; posts {postsBefore}, then {afterHighlight}, then {afterInject}"
      return true }

/-- A detach of a text whose delivery is pending drops it: the fake is
quiescent with no step, and posts nothing. -/
def detachDropsCheck : Check :=
  { name :=
      "the fake syntax service drops a pending delivery when its text is detached: quiescent with no step, and nothing posted"
    run := do
      let asked ← IO.mkRef #[]
      let fake ← learningFake asked
      let .ok () ← (SyntaxTree.attach learntSnapshot "json").runWith fake.handle | return false
      let pending := !(← fake.quiescent)
      let .ok () ← (SyntaxTree.detach learntSnapshot).runWith fake.handle | return false
      let dropped ← fake.quiescent
      let stepped ← fake.step
      unless pending && dropped && !stepped && (← fake.posts) == 0 do
        throw <|
            IO.userError
              s!"pending after the attach {pending}, quiescent after the detach {dropped}, a step delivered {stepped}"
      return true }

/-- The checks of the syntax service fake's own promises. -/
def syntaxFakeChecks : List Check :=
  [learnCheck, highlightInjectCheck, detachDropsCheck]

end ModelTest
