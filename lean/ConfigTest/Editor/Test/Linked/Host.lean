import ConfigTest.Check
import Editor.Headless
import Editor.Job.Real
import Editor.SyntaxTree.DeliveryContract
import Editor.SyntaxTree.Fake
import Editor.Test.Linked.Host

/-!
# Config tests: `Editor/Test/Linked/Host.lean`

The tests of the stage makers a host check gets its fakes from that no
other check reaches: `stageMakerChecks`. A stage's fake syntax service
(`Stage.fakeSyntaxService`) on a stepped host: it is the host's syntax
handler, it learns a text from the stage's published table, and each step
posts a `parsed` event to the stage's memory queue that the host's loop
takes. The root module `ConfigTest` runs them; its module doc says what
they show.
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- The last snapshot the stage's published table holds, with its text,
among the first `count` ids; `none` if it holds none of them. -/
def lastPublished (published : SnapshotReader) (count : Nat := 64) :
    IO (Option (SnapshotId × String)) := do
  let mut last := none
  for index in [0:count] do
    let id : SnapshotId := ⟨index⟩
    if let some text← Job.realSnapshots published id then
      last := some (id, text)
  return last

/-- The text `stageMakerChecks` types into the scratch buffer: a json list
of two numbers, which the query captures. -/
def typedJson : String :=
  "[1, 2]"

/-- The scene counts the host said, oldest first: each `published <n>` line
of the stage's output. -/
def publishedCounts {β σ : Type} (stage : Stage β σ) : IO (Array Nat) := do
  return (← stage.output.get).filterMap fun line =>
      match line.splitOn "published " with
      | ["", rest] => rest.toNat?
      | _ => none

/-- The checks of the stage makers no other check reaches. -/
def stageMakerChecks (context : Context) : List Check :=
  [{  name :=
        "a stage's fake syntax service is the host's syntax handler: it learns the text the host published of what was typed, from the stage's table, refuses its captures as not parsed until the check steps it, and its step posts one `parsed` event to the stage's memory queue, which the stepped host's loop takes and answers with one scene"
      run := do
        let stage ←
          Stage.new context context.elaborator (memorySource [])
              {
                commands :=
                  #[{ name := "type-json"
                      action :=
                        .call fun call => do
                          discard <| call.target.window.id.insertAtSelections typedJson }] }
        let (stage, fake) ← stage.fakeSyntaxService
        let thread ← IO.getTID
        onStage stage fun drive stage => do
            drive.send (.run "type-json")
            unless ← drive.settle hangGuard do
              return false
            let some (snapshot, text) ←
              lastPublished
                  stage.collaborators.published.reader | saw false "no snapshot published once the host had run a command"
            let handler ← stage.collaborators.syntaxTree stage.collaborators.published.reader
            let .ok () ←
              (SyntaxTree.attach snapshot "json").runWith
                  handler | saw false s!"the attach of {repr snapshot} was refused"
            let learnt := (← fake.state.get).model.text? snapshot
            let .ok compiled ←
              (SyntaxTree.compile "json" SyntaxDeliveryContract.query).runWith
                  handler | saw false "the query was refused"
            let captures := fun () =>
              (SyntaxTree.captures snapshot compiled 0 text.utf8ByteSize).runWith handler
            let before ← captures ()
            -- The count three times, each request settled before the
            -- next, the step between the second and the third: the step
            -- posts its event to the memory queue before the third request,
            -- so the settle after that request drains both. What the event
            -- published is the second difference less the first, each
            -- holding a request's scene and a settle's.
            drive.send .published
            unless ← drive.settle hangGuard do
              return false
            drive.send .published
            unless ← drive.settle hangGuard do
              return false
            let stepped ← fake.step
            drive.send .published
            unless ← drive.settle hangGuard do
              return false
            let after ← captures ()
            let counts ← publishedCounts stage
            let scenes :=
              match counts.toList.reverse with
              | c :: b :: a :: _ => some ((c : Int) - b - (b - a))
              | _ => none
            let posts ← fake.postThreads
            let requests ← fake.requestThreads
            saw
                (text == typedJson && learnt == some text &&
                  SyntaxDeliveryContract.same before (.error .notParsed) &&
                  stepped &&
                  SyntaxDeliveryContract.same after (SyntaxDeliveryContract.modelAnswer text) &&
                  scenes == some 1 &&
                  posts == #[thread] &&
                  requests.all (· == thread) &&
                  (← fake.quiescent))
                s!"learnt {learnt} of the published {text}; captures before the step {SyntaxDeliveryContract.shown before}, after {SyntaxDeliveryContract.shown after}; stepped {stepped}; scene counts {counts}; posts on {posts}, requests on {requests}, the check's thread {thread}" }]

end ConfigTest
