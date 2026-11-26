import Acp.Conversation.View
import Acp.Permissions.Queue
import AcpTest.Acp.Permissions.Policy

/-!
# Model tests: `Acp/Permissions/Queue.lean`

`queueChecks`: the queue of a project's pending permission requests,
derived from its conversations. Entries are every pending request of every
conversation of the project that has not ended, by conversation and then by
the request's place; answered, withdrawn and ended ones and another
project's are left out; the text is a header and each entry's lines as the
default view lists it; the map of rows names the request on each of its
rows (`rowOf` finds its first), and a view's line feed is split into rows.
The test driver's root, `AcpTest/Model.lean`, runs them.
-/

namespace AcpTest

open AgentsApi
open AgentsApiTest
open Acp.Permissions

/-- Whether a location is in the project of `/work/example`. -/
def inExample (location : Editor.Location) : Bool :=
  location == .local "/work/example"

/-- `openedExample` as the conversation `number`, after `batch`. -/
def numbered (number : Nat) (batch : Batch := askedBatch) : Acp.Conversation :=
  { openedExample with number }.applyBatch batch

/-- The lines of the default view's entry for ticket `ticket` of the
conversation `number`. -/
def entryLines (number ticket : Nat) : Array String :=
  Acp.Conversation.defaultView.queued number
    { agent := Acp.defaultAgent, root := "/work/example", sessionId := Contract.sessionId, ticket
      turn := some 1, call := Fake.editAsked, options := Fake.adapterOptions }

/-- The checks of `Acp/Permissions/Queue.lean`. -/
def queueChecks : List Check :=
  [{  name :=
        "the queue's entries are every pending request of the project's conversations, by conversation and then by place, the same ticket of two sessions kept apart"
      run := do
        let second :=
          { askedBatch with
            events :=
              askedBatch.events.push (.permission 2 (some 1) Fake.editAsked Fake.adapterOptions) }
        let found := entries #[numbered 2, numbered 1 second] inExample
        saw
            ((found.map fun entry => (entry.conversation, entry.request.ticket)) ==
              #[(1, 1), (1, 2), (2, 1)])
            s!"{repr (found.map fun entry => (entry.conversation, entry.request.ticket))}" },
    { name :=
        "an answered, a withdrawn and an ended conversation's request are left out, as is another project's"
      run := do
        let answered := (numbered 1).answered 1 "allow-once"
        let withdrawn := numbered 2 { events := askedBatch.events.push (.withdrawn 1) }
        let ended := { numbered 3 with ended := some "stopped" }
        let elsewhere := { numbered 4 with location := .local "/work/other" }
        let kept := numbered 5
        let found := entries #[answered, withdrawn, ended, elsewhere, kept] inExample
        saw ((found.map (·.conversation)) == #[5]) s!"{repr (found.map (·.conversation))}" },
    { name :=
        "the queue's text is its project, the count pending and each entry as the default view lists it: title, input, diff and options"
      run := do
        let found := entries #[numbered 1, numbered 2] inExample
        let (lines, _) := render Acp.Conversation.defaultView "example" found
        saw
            (lines ==
                #["permissions of example", "2 pending", ""] ++ entryLines 1 1 ++ entryLines 2 1 &&
              (entryLines 1 1).contains "    - beta" &&
              (entryLines 1 1).contains "    + gamma")
            s!"{lines}" },
    { name := "a queue with nothing pending says so"
      run := do
        let (lines, map) := render Acp.Conversation.defaultView "example" #[]
        saw
            (lines == #["permissions of example", "nothing pending", ""] &&
              map == #[none, none, none])
            s!"{lines}" },
    { name :=
        "the map of rows names the conversation and ticket on every row of an entry, and rowOf finds its first row"
      run := do
        let found := entries #[numbered 1, numbered 2] inExample
        let view := Acp.Conversation.defaultView
        let (lines, map) := render view "example" found
        let size := (entryLines 1 1).size
        let first := rowOf view "example" found 2 1
        saw
            (map.size == lines.size &&
              map.extract 3 (3 + size) == Array.replicate size (some (1, 1)) &&
              map.extract (3 + size) (3 + 2 * size) == Array.replicate size (some (2, 1)) &&
              first == some (3 + size) &&
              rowOf view "example" found 2 9 == none)
            s!"{map}, first {first}" },
    { name := "a line feed in a queued line is split into rows, and the map keeps its size"
      run := do
        let view :=
          { Acp.Conversation.defaultView with queued := fun number _ => #[s!"one\n{number}"] }
        let (lines, map) := render view "example" (entries #[numbered 1] inExample)
        saw
            (lines.extract 3 5 == #["one", "1"] && map.size == lines.size &&
              map[4]? == some (some (1, 1)))
            s!"{lines}" }]

end AcpTest
