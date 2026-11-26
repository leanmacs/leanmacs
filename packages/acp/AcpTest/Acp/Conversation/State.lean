import Acp.ClaudeCode
import Acp.Conversation.State
import AcpTest.Check
import AgentsApiTest.Fake

/-!
# Model tests: `Acp/Conversation/State.lean`

`stateChecks`: a conversation after each kind of event, and after the
client's own steps; and its tree, read back as it was written. The test
driver's root, `AcpTest/Model.lean`, runs them.
-/

namespace AcpTest

open AgentsApi
open AgentsApiTest
open Acp.Conversation (Item)

/-- A conversation in `/work/example`, as `agent-start` makes one. -/
def example1 : Acp.Conversation :=
  { number := 1, agent := Acp.defaultAgent, location := .local "/work/example", buffer := some 3 }

/-- The events of `Fake.conversation`'s prompt, in order, with its turn. -/
def conversationEvents : Array Event :=
  #[.mode "mode-ask", .chunk (some "msg-1") "Do", .chunk (some "msg-1") "ne.",
    .toolCall Fake.editPending, .toolCall Fake.editCompleted,
    .usage 1200 200000 (some ("0.01", "USD")), .title "Example title", .turnEnded 1 "end_turn"]

/-- The checks of `Acp/Conversation/State.lean`. -/
def stateChecks : List Check :=
  [{  name :=
        "a turn's events give one message of its chunks joined, one tool call replaced whole by its completed post, the usage, title and mode, and the turn's end, which clears the turn in flight"
      run := do
        let conversation :=
          ((example1.prompted "Read notes.txt.").sent 1).applyBatch { events := conversationEvents }
        saw
            (conversation.items ==
                #[.prompt "Read notes.txt." (some 1), .message (some "msg-1") "Done.",
                  .toolCall Fake.editCompleted, .turnEnded 1 "end_turn"] &&
              conversation.mode == some "mode-ask" &&
              conversation.title == some "Example title" &&
              conversation.usage ==
                some { used := 1200, size := 200000, cost := some ("0.01", "USD") } &&
              conversation.turn.isNone &&
              !conversation.awaiting)
            s!"{repr conversation}" },
    { name :=
        "a turn's end that comes before the prompt's reply leaves no turn in flight, and a chunk of another id or of none starts a message of its own"
      run := do
        let early := ((example1.prompted "p").apply (.turnEnded 1 "end_turn")).sent 1
        let messages :=
          (example1.applyBatch
              {
                events :=
                  #[.chunk (some "a") "1", .chunk none "2", .chunk none "3", .chunk (some "b") "4",
                    .chunk (some "a") "5"] }).items
        saw
            (early.turn.isNone && !early.busy &&
              messages == #[.message (some "a") "15", .message none "23", .message (some "b") "4"])
            s!"early {repr early.turn}, messages {repr messages}" },
    { name :=
        "a permission request is pending until withdrawn or answered, both final: a withdrawal of an answered ticket and a turn's end change nothing, and pending is empty"
      run := do
        let asked :=
          (example1.prompted "p").sent 1 |>.applyBatch
            {
              events :=
                #[.permission 1 (some 1) Contract.call Contract.options,
                  .permission 2 (some 1) Contract.second Contract.options] }
        let pendingFirst := asked.pending
        let settled :=
          (asked.answered 1 Contract.allow).applyBatch
            { events := #[.withdrawn 2, .withdrawn 1, .turnEnded 1 "cancelled"] }
        let states :=
          settled.items.filterMap fun item =>
            match item with
            | .permission ticket _ _ _ state => some (ticket, state)
            | _ => none
        saw
            (pendingFirst == #[1, 2] && settled.pending.isEmpty &&
              states == #[(1, .answered Contract.allow), (2, .withdrawn)] &&
              settled.turn.isNone)
            s!"pending first {pendingFirst}, states {repr states}" },
    { name :=
        "the session's open gives its number, id, mode and modes; its end is kept and clears the turn; a tool call's fold toggles"
      run := do
        let opened :=
          example1.opened
            { session := 4, sessionId := Contract.sessionId, mode := some "mode-auto"
              modes := Contract.modes }
        let ended := ({ opened with turn := some 1 }).apply (.ended (.exited 0))
        let toggled := opened.toggled "call-edit-1"
        saw
            (opened.session == some 4 && opened.sessionId == some Contract.sessionId &&
              opened.mode == some "mode-auto" &&
              opened.modes == Contract.modes &&
              ended.ended == some "the agent exited 0" &&
              ended.turn.isNone &&
              toggled.unfolded == #["call-edit-1"] &&
              (toggled.toggled "call-edit-1").unfolded.isEmpty)
            s!"{repr ended.ended}" },
    { name :=
        "a conversation holding every kind of item is read back from its tree as it was written"
      run := do
        let full : Acp.Conversation :=
          { example1 with
            session := some 1, sessionId := some Contract.sessionId, mode := some "mode-ask"
            modes := Contract.modes, title := some "Example title"
            usage := some { used := 1200, size := 200000, cost := some ("0.01", "USD") }
            items :=
              #[.prompt "Read notes.txt." (some 1), .prompt "again" none,
                .message (some "msg-1") "Done.", .message none "", .toolCall Fake.editCompleted,
                .permission 1 (some 1) Contract.call Contract.options .pending,
                .permission 2 none Contract.second #[] .withdrawn,
                .permission 3 (some 1) Contract.call Contract.options (.answered "allow"),
                .turnEnded 1 "end_turn", .note "session stopped"]
            unfolded := #["call-edit-1"], turn := some 2, awaiting := true
            ended := some "stopped" }
        let bare : Acp.Conversation := { number := 2, agent := "other", location := .local "/" }
        saw
            (Acp.Conversation.decode full.encode == some full &&
              Acp.Conversation.decode bare.encode == some bare)
            s!"{repr (Acp.Conversation.decode full.encode)}" }]

end AcpTest
