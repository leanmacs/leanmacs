import Acp.Conversation.Render
import Acp.Conversation.View
import AcpTest.Acp.Conversation.State

/-!
# Model tests: `Acp/Conversation/Render.lean` and `Acp/Conversation/View.lean`

`renderChecks`: a conversation's text as the default view shows it, its
header's mode line from the session's open and a mode event, a tool call
folded by default and unfolded through `unfolded`, the map of rows and
`rowOf`, a view whose field gives a line feed split into rows, and a
permission request as the queue lists it (`queued`). The test driver's
root, `AcpTest/Model.lean`, runs them.
-/

namespace AcpTest

open AgentsApi
open AgentsApiTest
open Acp.Conversation

/-- `example1` opened in `mode-auto`, after `Fake.conversation`'s turn. -/
def talked : Acp.Conversation :=
  ((((example1.opened
                { session := 1, sessionId := Contract.sessionId, mode := some "mode-auto"
                  modes := Contract.modes }).prompted
            "Read notes.txt.").sent
        1).applyBatch
    { events := conversationEvents })

/-- The checks of the conversation's text. -/
def renderChecks : List Check :=
  [{  name :=
        "the default view shows the header, the prompt, the reply joined, the tool call folded, and the turn's end"
      run := do
        let (lines, _) := render defaultView talked
        saw
            (lines ==
              #["claude-code in /work/example", "title: Example title", "mode: Ask (mode-ask)",
                "usage: 1200 of 200000, 0.01 USD", "", "> Read notes.txt.", "Done.",
                "[+] edit: Edit notes.txt (completed) /work/example/notes.txt",
                "-- turn 1: end_turn"])
            s!"{lines}" },
    { name :=
        "the header's mode is - before the agent reports one, the mode's name and id from the open, and the id alone when no offered mode names it"
      run := do
        let before := (render defaultView example1).1
        let opened :=
          (render defaultView
              (example1.opened
                { session := 1, sessionId := Contract.sessionId, mode := some "mode-auto"
                  modes := Contract.modes })).1
        let unnamed := (render defaultView (example1.apply (.mode "mode-other"))).1
        saw
            (before[2]? == some "mode: -" && before[1]? == some "title: (untitled)" &&
              before[3]? == some "usage: -" &&
              opened[2]? == some "mode: Auto (mode-auto)" &&
              unnamed[2]? == some "mode: mode-other")
            s!"before {before}, opened {opened}, unnamed {unnamed}" },
    { name :=
        "an unfolded tool call shows its final diff alone, with its context, and the map of rows names the call on each of its rows; rowOf finds its first"
      run := do
        let unfolded := talked.toggled "call-edit-1"
        let (lines, map) := render defaultView unfolded
        let first := rowOf defaultView unfolded "call-edit-1"
        let rows := (List.range map.size).filter fun row => map[row]? == some (some "call-edit-1")
        saw
            (lines.extract 7 12 ==
                #["[-] edit: Edit notes.txt (completed) /work/example/notes.txt",
                  "  /work/example/notes.txt", "      alpha", "    - beta", "    + gamma"] &&
              (lines.filter (· == "    - beta")).size == 1 &&
              first == some 7 &&
              rows == [7, 8, 9, 10, 11] &&
              map.size == lines.size &&
              rowOf defaultView unfolded "nobody" == none)
            s!"{lines}, first {first}, rows {rows}" },
    { name :=
        "a permission request shows its options and where it stands, answered by its option's name, withdrawn or closed"
      run := do
        let asked :=
          example1.applyBatch
            {
              events :=
                #[.permission 1 (some 1) Contract.call Contract.options,
                  .permission 2 (some 1) Contract.second Contract.options,
                  .permission 3 (some 1) Contract.second Contract.options,
                  .permission 4 (some 1) Contract.second Contract.options, .withdrawn 2] }
        let lines := (render defaultView ((asked.answered 1 Contract.allow).settle 4 .closed)).1
        saw
            (lines.extract 5 9 ==
              #["? permission 1: Edit notes.txt [Allow, Reject] (answered Allow)",
                "? permission 2: Edit notes.txt again [Allow, Reject] (withdrawn)",
                "? permission 3: Edit notes.txt again [Allow, Reject]",
                "? permission 4: Edit notes.txt again [Allow, Reject] (closed)"])
            s!"{lines}" },
    { name := "a line feed in a line a view gives is split into rows, and the map keeps its size"
      run := do
        let view := { defaultView with message := fun text => #[s!"one\n{text}"] }
        let (lines, map) := render view talked
        saw (lines.extract 6 8 == #["one", "Done."] && map.size == lines.size) s!"{lines}" },
    { name :=
        "the default view lists a queued request by its agent, root, conversation, ticket and title, then its input, its diff and its options"
      run := do
        let request : PermissionRequest :=
          { agent := "claude-code", root := "/work/example", sessionId := Contract.sessionId
            ticket := 1, turn := some 1, call := Fake.editAsked, options := Fake.adapterOptions }
        let lines := defaultView.queued 2 request
        let bare := defaultView.queued 2 { request with call := { id := "call-2", title := "Run" } }
        saw
            (lines ==
                #["? claude-code in /work/example, conversation 2, ticket 1: Edit notes.txt",
                  "  input: {\"file_path\":\"/work/example/notes.txt\",\"old_string\":\"beta\",\"new_string\":\"gamma\"}",
                  "  /work/example/notes.txt", "    - beta", s!"    {noLineFeed}", "    + gamma",
                  s!"    {noLineFeed}",
                  "  options: allow-once (Yes), allow-session (Yes, for this session), reject (No)"] &&
              bare ==
                #["? claude-code in /work/example, conversation 2, ticket 1: Run",
                  "  input: (none)",
                  "  options: allow-once (Yes), allow-session (Yes, for this session), reject (No)"])
            s!"{lines}; bare {bare}" }]

end AcpTest
