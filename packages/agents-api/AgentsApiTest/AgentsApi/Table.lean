import AgentsApi.Table
import AgentsApiTest.Check

/-!
# Model tests: `AgentsApi/Table.lean`

`tableChecks`: the reducer's attention and activity over a table of events
(AC1 of acp-agents phase 7), an agent idle in the conversation with work
in flight among them; the list's order; the minted id; the display name;
a record kept across a restart; and the table's tree, read back through
the store's codec and refused when it is not one. The test driver's root,
`AgentsApiTest/Model.lean`, runs them.
-/

namespace AgentsApiTest

open AgentsApi

/-- Record 1: `claude-code` in `/work/example`, as a session starts. -/
def r0 : AgentRecord :=
  { id := 1, agent := "claude-code", location := .local "/work/example" }

/-- `call-bash-1`, running the tests, with `status`. -/
def bash (status : String) : ToolCall :=
  { id := "call-bash-1", title := "Run the tests", kind := "execute", status }

/-- The work item of `call-bash-1`. -/
def bashItem : WorkItem :=
  WorkItem.of (bash "in_progress")

/-- `record` after each of `changes`, in order. -/
def after (record : AgentRecord) (changes : List Change) : AgentRecord :=
  changes.foldl AgentRecord.apply record

/-- Prompted, and its turn 1 begun. -/
def rowC : List Change :=
  [.prompted, .sent (some 1)]

/-- `rowC`, then a permission request parked as ticket 1. -/
def rowD : List Change :=
  rowC ++ [.event (.permission 1 (some 1) (bash "pending") #[])]

/-- `rowC`, then `call-bash-1` in progress. -/
def rowG : List Change :=
  rowC ++ [.event (.toolCall (bash "in_progress"))]

/-- `rowG`, then its turn's end. -/
def rowH : List Change :=
  rowG ++ [.event (.turnEnded 1 "end_turn")]

/-- `rowH`, then a visit: idle in the conversation with work in flight. -/
def rowI : List Change :=
  rowH ++ [.seen]

/-- One row of AC1's table: its name, the record it reaches, and the
attention and activity it must have. -/
structure Row where
  /-- The row's letter and what it is. -/
  name : String
  /-- The record its events reach. -/
  record : AgentRecord
  /-- Its attention. -/
  attention : Attention
  /-- Its activity. -/
  activity : Activity
  /-- What else must hold of it. -/
  holds : AgentRecord → Bool := fun _ => true

/-- AC1's table of events, each row from `r0`. -/
def rows : List Row :=
  [{ name := "a: no events", record := r0, attention := .idle, activity := .items #[] },
    { name := "b: prompted", record := after r0 [.prompted], attention := .working
      activity := .items #[] },
    { name := "c: prompted, sent 1", record := after r0 rowC, attention := .working
      activity := .items #[] },
    { name := "d: c, permission 1", record := after r0 rowD, attention := .waiting
      activity := .items #[] },
    { name := "e: d, answered 1", record := after r0 (rowD ++ [.answered 1])
      attention := .working, activity := .items #[] },
    { name := "f: d, withdrawn 1", record := after r0 (rowD ++ [.event (.withdrawn 1)])
      attention := .working, activity := .items #[] },
    { name := "g: c, a tool call in progress", record := after r0 rowG, attention := .working
      activity := .items #[bashItem] },
    { name := "h: g, its turn's end", record := after r0 rowH, attention := .finished
      activity := .items #[bashItem] },
    { name := "i: h, seen: idle in the conversation with work in flight"
      record := after r0 rowI, attention := .idle, activity := .items #[bashItem] },
    { name := "j: i, the tool call completed"
      record := after r0 (rowI ++ [.event (.toolCall (bash "completed"))]), attention := .idle
      activity := .items #[] },
    { name := "k: the turn's end before the prompt's reply"
      record := after r0 [.prompted, .event (.turnEnded 1 "end_turn"), .sent (some 1)]
      attention := .finished, activity := .items #[] },
    { name := "l: g, stalled at its generation", record := after r0 (rowG ++ [.stalled 1])
      attention := .working, activity := .unknown },
    { name := "m: g, a stale stall", record := after r0 (rowG ++ [.stalled 0])
      attention := .working, activity := .items #[bashItem] },
    { name := "n: i, stalled while idle", record := after r0 (rowI ++ [.stalled 2])
      attention := .idle, activity := .items #[bashItem] },
    { name := "o: l, then a chunk",
      record := after r0 (rowG ++ [.stalled 1, .event (.chunk (some "msg-1") "More.")])
      attention := .working, activity := .items #[bashItem] },
    { name := "p: d, stalled at its generation while waiting"
      record := after r0 (rowD ++ [.stalled 1]), attention := .waiting, activity := .items #[] },
    { name := "q: a resumed session's replayed history adds no work"
      record :=
        after r0
          [.resumed "sess-0001", .event (.toolCall (bash "in_progress")),
            .event (.userChunk (some "msg-u1") "Read notes.txt."), .event (.title "Example title")]
      attention := .idle, activity := .items #[]
      holds := fun record =>
        record.name == "Example title" && record.sessionId == some "sess-0001" &&
          record.replaying },
    { name := "r: g, the session ended", record := after r0 (rowG ++ [.event (.ended (.exited 0))])
      attention := .finished, activity := .items #[]
      holds := (·.ended == some "the agent exited 0") },
    { name := "s: g, stopped", record := after r0 (rowG ++ [.stopped "session stopped"])
      attention := .idle, activity := .items #[]
      holds := (·.ended == some "session stopped") },
    { name := "t: a title of two lines", record := after r0 [.event (.title "Line one\nLine two")]
      attention := .idle, activity := .items #[], holds := (·.name == "Line one") },
    { name := "u: d across a restart", record := (after r0 rowD).afterRestart
      attention := .finished, activity := .items #[]
      holds := (·.ended == some "the editor restarted") },
    { name := "v: i across a restart", record := (after r0 rowI).afterRestart, attention := .idle
      activity := .items #[] }]

/-- Two records of the table, `claude-code` 1 and 2. -/
def twoRecords : Array AgentRecord :=
  #[r0, { r0 with id := 2 }]

/-- The checks of `AgentsApi/Table.lean`. -/
def tableChecks : List Check :=
  [{  name :=
        "AC1: the reducer's attention and activity on a table of events, an agent idle in the conversation with work in flight among them"
      run := do
        let wrong :=
          rows.filter fun row =>
            row.record.attention != row.attention || row.record.activity != row.activity ||
              !row.holds row.record
        saw wrong.isEmpty
            s!"{wrong.map fun row => s!"{row.name}: {repr row.record.attention}, {repr row.record.activity}, {repr row.record}"}" },
    { name :=
        "AC1 w: an event for agent 2 changes agent 2's record alone, and one for an unknown id none"
      run := do
        let changed := Table.apply twoRecords { agent := 2, change := .prompted }
        let unknown := Table.apply twoRecords { agent := 3, change := .prompted }
        saw
            (changed[0]? == some r0 && (changed[1]?.map (·.attention)) == some .working &&
              unknown == twoRecords)
            s!"{repr changed}" },
    { name :=
        "the list's order is by attention, waiting, finished and unread, working and idle, then by id"
      run := do
        let records :=
          #[{ r0 with id := 5 }, after { r0 with id := 4 } rowG, after { r0 with id := 3 } rowH,
            after { r0 with id := 2 } rowD, { r0 with id := 1 }, after { r0 with id := 6 } rowD]
        let ids := (Table.ordered records).map (·.id)
        saw (ids == #[2, 6, 3, 4, 1, 5]) s!"{ids}" },
    { name :=
        "an id is minted one past the largest held, and the first is 1; a record added again replaces its own"
      run := do
        let added := Table.add twoRecords { r0 with title := some "Again" }
        saw
            (Table.mint #[] == 1 && Table.mint #[3, 1, 7] == 8 && added.size == 2 &&
              (added[0]?.bind (·.title)) == some "Again" &&
              (Table.add twoRecords { r0 with id := 9 }).size == 3)
            s!"{Table.mint #[3, 1, 7]}" },
    { name :=
        "the display name is the title's first line, trimmed and cut at sixty characters, or the agent and the id"
      run := do
        let long := String.ofList (List.replicate 70 'x')
        let names :=
          [r0.name, { r0 with title := some "  Tidy  \nmore" }.name,
            { r0 with title := some long }.name, { r0 with title := some " \nmore" }.name]
        saw
            (names ==
              ["claude-code 1", "Tidy", String.ofList (List.replicate 60 'x'), "claude-code 1"])
            s!"{names}" },
    { name :=
        "across a restart a record keeps its identity, workspace and title, loses what died with its process, is unread when it was cut off, and keeps an ending it had"
      run := do
        let working := (after r0 (rowG ++ [.event (.title "Example title")])).afterRestart
        let ended := (after r0 (rowG ++ [.event (.ended (.exited 0)), .seen])).afterRestart
        saw
            (working.id == 1 && working.location == r0.location &&
              working.title == some "Example title" &&
              working.unread &&
              working.work.isEmpty &&
              working.turn.isNone &&
              !working.awaiting &&
              working.heard == 0 &&
              working.ended == some "the editor restarted" &&
              ended.ended == some "the agent exited 0" &&
              !ended.unread)
            s!"{repr working}; {repr ended}" },
    { name :=
        "a resume forgets the ending and the unread mark, and a stop after it keeps its own reason"
      run := do
        let resuming := after r0.afterRestart [.resuming]
        let refused := after resuming [.stopped "the session did not resume: refused: gone"]
        saw
            (resuming.ended.isNone && resuming.attention == .idle &&
              refused.ended == some "the session did not resume: refused: gone")
            s!"{repr refused}" },
    { name :=
        "the table's tree is read back through the store's codec as it was written, its keep applying the restart, and a tree that is no table is refused"
      run := do
        let full : AgentRecord :=
          { after r0
              (rowD ++
                [.event (.toolCall (bash "in_progress")),
                  .event (.title "T")]) with
            sessionId := some "sess-0001",
            stalled := true, replaying := true
            ended := some "x", location := .reachable "ssh" "example" "/work/example" }
        let records := #[full, r0]
        let codec := Table.store.codec Table.keep
        let tree := Table.store.encode records
        let kept := codec.keep tree
        saw
            (Table.store.decode tree == some records &&
              kept.bind Table.store.decode == some (records.map AgentRecord.afterRestart) &&
              (Table.store.decode (.list [.record [("id", .str "1")]])).isNone &&
              (Table.store.decode (.str "agents")).isNone &&
              (codec.keep (.nat 1)).isNone)
            s!"{repr (Table.store.decode tree)}" }]

end AgentsApiTest
