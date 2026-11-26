import Acp.Conversation.View
import Acp.Table.List
import AcpTest.Check

/-!
# Model tests: `Acp/Table/List.lean` and the default view's `listed`

`listChecks`: a project's agents list as the default view shows it: its
rows ordered by attention, then id; each row's words for every attention
and activity; `not running` and `ended:`; the header for no, one and two
sessions; the map of rows and `rowOf`; and a view whose `listed` gives a
line feed split into rows. The test driver's root, `AcpTest/Model.lean`,
runs them.
-/

namespace AcpTest

open AgentsApi
open Acp.Conversation (defaultView)

/-- Agent `id` of `claude-code` in `/work/example`. -/
def agentRecord (id : Nat) : AgentRecord :=
  { id, agent := "claude-code", location := .local "/work/example" }

/-- `call-bash-1` in flight. -/
def bashWork : WorkItem :=
  { id := "call-bash-1", title := "Run the tests", kind := "execute" }

/-- Four agents, one of each attention: 1 working with a call in flight, 2
waiting, 3 finished with a call in flight, and 4 idle. -/
def fourAgents : Array AgentRecord :=
  #[{ agentRecord 1 with
      awaiting := true, work := #[bashWork], sessionId := some "sess-0001" },
    { agentRecord 2 with
      pending := #[1], sessionId := some "sess-0002" },
    { agentRecord 3 with
      unread := true, work := #[bashWork], sessionId := some "sess-0003" },
    { agentRecord 4 with sessionId := some "sess-0004" }]

/-- The checks of the agents list. -/
def listChecks : List Check :=
  [{  name :=
        "the agents list orders its sessions by attention, waiting, finished and unread, working and idle, each row saying its attention, its activity, its agent and root and its session"
      run := do
        let (lines, _) := Acp.Table.render defaultView "example" fourAgents fun _ => true
        saw
            (lines ==
              #["agents of example", "4 sessions", "",
                "2 claude-code 2: waiting, nothing in flight — claude-code in /work/example, session sess-0002",
                "3 claude-code 3: finished, unread, 1 in flight (Run the tests) — claude-code in /work/example, session sess-0003",
                "1 claude-code 1: working, 1 in flight (Run the tests) — claude-code in /work/example, session sess-0001",
                "4 claude-code 4: idle, nothing in flight — claude-code in /work/example, session sess-0004"])
            s!"{lines}" },
    { name :=
        "a row says activity unknown once stalled, two calls in flight by their titles, the title as the name, and not running with the ending when no session of its id runs"
      run := do
        let stalled :=
          { agentRecord 1 with
            awaiting := true, stalled := true }
        let two :=
          { agentRecord
              2 with
            work :=
              #[bashWork,
                { bashWork with
                  id := "call-bash-2", title := "Lint" }]
            title := some "Tidy the notes" }
        let ended := { agentRecord 3 with ended := some "the editor restarted" }
        let rows :=
          [(stalled, true), (two, false), (ended, false)].map fun (record, running) =>
            defaultView.listed record running
        saw
            (rows ==
              [#["1 claude-code 1: working, activity unknown — claude-code in /work/example"],
                #["2 Tidy the notes: idle, 2 in flight (Run the tests, Lint) — claude-code in /work/example, not running"],
                #["3 claude-code 3: idle, nothing in flight — claude-code in /work/example, not running; ended: the editor restarted"]])
            s!"{rows}" },
    { name := "the header says no sessions, one session or the count"
      run := do
        let heads :=
          [#[], #[agentRecord 1], #[agentRecord 1, agentRecord 2]].map
            fun (records : Array AgentRecord) =>
            (Acp.Table.render defaultView "example" records fun _ => true).1[1]?
        saw (heads == [some "no sessions", some "1 session", some "2 sessions"]) s!"{heads}" },
    { name :=
        "the map of rows names each row's agent, rowOf finds an agent's first row, and a view whose listed gives a line feed is split into rows"
      run := do
        let view := { defaultView with listed := fun record _ => #[s!"one\n{record.id}"] }
        let (lines, map) := Acp.Table.render view "example" fourAgents fun _ => true
        let row3 := Acp.Table.rowOf view "example" fourAgents (fun _ => true) 3
        saw
            (lines.size == 11 && map.size == 11 && map[3]? == some (some 2) &&
              map[4]? == some (some 2) &&
              map[5]? == some (some 3) &&
              map[0]? == some none &&
              row3 == some 5 &&
              (Acp.Table.rowOf view "example" fourAgents (fun _ => true) 9).isNone)
            s!"{lines}, {map}, {row3}" }]

end AcpTest
