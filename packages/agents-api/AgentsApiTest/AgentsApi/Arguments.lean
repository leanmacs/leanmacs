import AgentsApi.Arguments
import AgentsApiTest.Check
import AgentsApiTest.Contract

/-!
# Model tests: `AgentsApi/Arguments.lean`

`argumentsChecks`: every event, a batch of a thousand, and an opened
session with and without a mode, read back as they were written; and
truncated lists, a list with more after it, and lists of an unknown kind
read as none. The test driver's root, `AgentsApiTest/Model.lean`, runs
them.
-/

namespace AgentsApiTest

open AgentsApi

/-- A tool call with every field set: two locations, one with a line, and a
text and two diffs, one of a new file. -/
def fullCall : ToolCall :=
  { Contract.call with
    status := "completed", locations := #[("/work/example/notes.txt", some 2), ("/work/b", none)]
    content :=
      #[.text "Edited.", .diff "/work/example/notes.txt" (some "alpha\nbeta\n") "alpha\ngamma\n",
        .diff "/work/example/new.txt" none "fresh\n"] }

/-- One event of every kind, and of each optional field both ways. -/
def everyEvent : Array Event :=
  #[.chunk (some "msg-1") "Done.", .chunk none "", .toolCall Contract.call, .toolCall fullCall,
    .permission 1 (some 1) fullCall Contract.options, .permission 2 none Contract.second #[],
    .withdrawn 2, .usage 1200 200000 (some ("0.01", "USD")), .usage 0 0 none,
    .title "Example title", .mode "mode-ask", .turnEnded 1 "end_turn", .ended (.exited 0),
    .ended (.exited (-1)), .ended (.signalled 9), .ended .lineTooLong, .ended (.failed "gone"),
    .ended (.protocolError "bad")]

/-- The checks of `AgentsApi/Arguments.lean`. -/
def argumentsChecks : List Check :=
  [{  name :=
        "every event, of every kind and each optional field both ways, is read back as it was written"
      run := do
        let back := everyEvent.map fun event => Event.ofArguments? event.toArguments
        saw (back == everyEvent.map some) s!"{repr back}" },
    { name := "a batch of a thousand events, and an empty one, is read back as it was written"
      run := do
        let batch : Batch :=
          { events := (Array.range 1000).map fun index => .chunk (some "msg-1") s!"x{index}" }
        let back := Batch.ofArguments? batch.toArguments
        let empty := Batch.ofArguments? ({ events := #[] } : Batch).toArguments
        saw (back == some batch && empty == some { events := #[] })
            s!"{(back.map (·.events.size))}, {repr empty}" },
    { name :=
        "an opened session, with a mode and modes and with neither, is read back as it was written"
      run := do
        let opened : Opened :=
          { session := 1, sessionId := Contract.sessionId, mode := some "mode-auto"
            modes :=
              Contract.modes.push
                { id := "mode-plan", name := "Plan", description := some "Plans." } }
        let bare : Opened := { session := 2, sessionId := "sess-0002" }
        saw
            (Opened.ofArguments? opened.toArguments == some opened &&
              Opened.ofArguments? bare.toArguments == some bare)
            s!"{repr (Opened.ofArguments? opened.toArguments)}" },
    { name :=
        "a truncated list, a list with more after it, and a list of an unknown kind are read as none"
      run := do
        let event : Event := .permission 1 (some 1) fullCall Contract.options
        let written := event.toArguments
        let batch : Batch := { events := everyEvent }
        let truncated :=
          (List.range written.length).all fun count =>
            (Event.ofArguments? (written.take count)).isNone
        let extra := (Event.ofArguments? (written ++ [.nat 1])).isNone
        let unknown := (Event.ofArguments? [.str "shout", .str "hi"]).isNone
        let short := (Batch.ofArguments? batch.toArguments.dropLast).isNone
        let counted :=
          (Batch.ofArguments? (.nat (everyEvent.size + 1) :: batch.toArguments.drop 1)).isNone
        let opened := (Opened.ofArguments? [.nat 1]).isNone
        saw (truncated && extra && unknown && short && counted && opened)
            s!"truncated {truncated}, extra {extra}, unknown {unknown}, short {short}, counted {counted}, opened {opened}" }]

end AgentsApiTest
