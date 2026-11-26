import AcpTest.Linked.Acp.Conversation
import AcpTest.Linked.Acp.Permissions
import AcpTest.Linked.Support.Restart

/-!
# Linked tests: `Acp/Table.lean`, the agents list and resume

The agent table, the stall watchdog, the agents list and resume, through
the headless host stepped on the check's thread over `agents-api`'s fake
(`AcpTest/Linked/Support/Stage.lean`), the agent `Fake.table`, whose
prompts' texts say what they give, or `Fake.resumable`, whose store holds
`sess-0001`'s history. A record is read through the check's `test-table`
(`recordLine`), and the list from the scene. Time moves only by the
check's own advances of the stage's fake clock; every wait is a step to
rest.

- **AC2**: a working agent silent past `Acp.Table.stallTimeout` is of
  unknown activity, and not one millisecond before; a batch makes it known
  again; a batch before the deadline moves it to that batch's timeout; an
  agent not working never stalls.
- **AC3**: a project's agents list orders its sessions by attention, each
  saying what it has in flight, and a visit reorders it.
- **AC4**: after a restart over the journal's recording fake
  (`AcpTest/Linked/Support/Restart.lean`), the table's records are read
  back from the project's store, every session's identity and workspace,
  and nothing is resumed.
- **AC5**: a session from before a restart is resumed by `session/load`
  when it is first visited, with its history shown; a second visit loads
  nothing, and the resumed session is live.
- **Supporting**: a load the agent refuses is recorded and tried again by
  the next visit; closing a list buffer drops it; `agent-list` refuses a
  buffer with no workspace; a stop with a request pending leaves the record
  not waiting.

None is of the wiring set: the root runs them in a plain group.
-/

namespace AcpTest.Linked

open Editor
open Editor.Test
open Editor.Test.Linked
open AgentsApi
open AgentsApiTest

/-- What `test-table` says, without its label and quotes. -/
def tableText (session : Session) : IO String := do
  session.ask [.run tableName]
  let said ← session.echo
  -- The echo area's text comes quoted.
  let label := "\"table: "
  if said.startsWith label && said.endsWith "\"" then
    return String.ofList ((said.toList.drop label.length).dropLast)
  else
    return said

/-- The lines of the agents list the scene shows. -/
def listLines (session : Session) : IO (Array String) :=
  bufferLines session "agents of "

/-- Moves the stage's clock by `ms` and steps the session to rest. -/
def advanced (session : Session) (ms : Nat) : IO Unit := do
  session.clock.advance ms
  session.step

/-- Prompts the focused conversation `text` and steps to rest. -/
def promptedWith (session : Session) (text : String) : IO Bool :=
  exStepped session s!"{Acp.Conversation.promptName} {text}"

/-- The record line of agent 1 working on `call-bash-1`, with the activity
`activity`. -/
def workingLine (activity : String) : String :=
  s!"1|sess-0001|claude-code 1|claude-code|/work/example|working|{activity}|-"

/-- A list's row of an agent of `/work/example`. -/
def listRow (id : Nat) (name state : String) : String :=
  s!"{id} {name}: {state} — claude-code in /work/example, session sess-000{id}"

/-- The requests the fake was handed, but each `next`. -/
def requestsBeyondNext (fake : Fake) : IO (Array Request) := do
  return (← fake.log).filterMap fun (request, _, _) =>
      match request with
      | .next _ => none
      | other => some other

/-- The checks of the stall watchdog (AC2). -/
def stallChecks (context : HostContext) (packages : Array Package) : List Check :=
  [{  name :=
        "AC2: a silent working agent's activity is unknown once the fake clock passes the stall timeout, and not one millisecond before; its attention stays working; a batch makes it known again"
      run :=
        withConversation context packages Fake.table fun session fake _ => do
          unless ← started session do
            return false
          unless ← promptedWith session "work" do
            return false
          let first ← tableText session
          advanced session (Acp.Table.stallTimeout - 1)
          let before ← tableText session
          unless ← exStepped session Acp.Conversation.listName do
            return false
          let beforeRows ← listLines session
          advanced session 1
          let stalled ← tableText session
          let stalledRows ← listLines session
          fake.agentSends 1 [.event (.chunk (some "msg-w") " More.")]
          session.step
          let known ← tableText session
          let knownRows ← listLines session
          saw
              (first == workingLine "Run the tests" && before == first &&
                beforeRows[3]? ==
                  some (listRow 1 "claude-code 1" "working, 1 in flight (Run the tests)") &&
                stalled == workingLine "unknown" &&
                stalledRows[3]? == some (listRow 1 "claude-code 1" "working, activity unknown") &&
                known == first &&
                knownRows[3]? == beforeRows[3]?)
              s!"first {first}; before {before} {beforeRows}; stalled {stalled} {stalledRows}; known {known} {knownRows}" },
    { name :=
        "AC2: a batch heard before the deadline moves the stall to that batch's timeout: not unknown at the first deadline, nor one millisecond before the second, and unknown at it"
      run :=
        withConversation context packages Fake.table fun session fake _ => do
          unless ← started session do
            return false
          unless ← promptedWith session "work" do
            return false
          advanced session (Acp.Table.stallTimeout - 1)
          fake.agentSends 1 [.event (.chunk (some "msg-w") " More.")]
          session.step
          advanced session 1
          let atFirst ← tableText session
          advanced session (Acp.Table.stallTimeout - 2)
          let underSecond ← tableText session
          advanced session 1
          let atSecond ← tableText session
          saw
              (atFirst == workingLine "Run the tests" && underSecond == atFirst &&
                atSecond == workingLine "unknown")
              s!"at first {atFirst}; under second {underSecond}; at second {atSecond}" },
    { name := "AC2: an agent whose turn has ended never stalls, however far the clock moves"
      run :=
        withConversation context packages Fake.table fun session _ _ => do
          unless ← started session do
            return false
          unless ← promptedWith session "done" do
            return false
          advanced session Acp.Conversation.batchPause
          advanced session (10 * Acp.Table.stallTimeout)
          let line ← tableText session
          unless ← exStepped session Acp.Conversation.listName do
            return false
          let rows ← listLines session
          saw
              (line == "1|sess-0001|Example title|claude-code|/work/example|finished|nothing|-" &&
                rows[3]? == some (listRow 1 "Example title" "finished, unread, nothing in flight"))
              s!"{line}; {rows}" }]

/-- Starts a session from the focused buffer and prompts it `text`, unless
`text` is empty: whether both were handled. -/
def startedWith (session : Session) (text : String) : IO Bool := do
  unless ← exStepped session Acp.Conversation.startName do
    return false
  if text.isEmpty then
    return true
  promptedWith session text

/-- The check of the agents list's order (AC3). -/
def orderChecks (context : HostContext) (packages : Array Package) : List Check :=
  [{  name :=
        "AC3: a project's agents list orders its sessions by attention, waiting, finished and unread, working and idle, each saying what it has in flight; a visit marks one seen and reorders it; the list is read-only, and neither it nor the visit sends the agent anything"
      run :=
        withConversation context packages Fake.table fun session fake _ => do
          session.ask [.reload]
          session.ask [.open opened]
          session.step
          for text in ["work", "ask", "bg", ""] do
            unless ← startedWith session text do
              return false
          settledAfter session
          unless ← exStepped session Acp.Conversation.listName do
            return false
          let rows ← listLines session
          session.ask [.run readOnlyProbe]
          let readOnly ← session.echo
          unless ← exStepped session s!"{cursorToAgent} 3" do
            return false
          unless ← exStepped session Acp.Conversation.visitName do
            return false
          unless ← exStepped session Acp.Conversation.listName do
            return false
          let after ← listLines session
          let requests ← requestsBeyondNext fake
          let header := #["agents of example", "4 sessions", ""]
          let b := listRow 2 "claude-code 2" "waiting, 1 in flight (Edit notes.txt)"
          let c := listRow 3 "claude-code 3" "finished, unread, 1 in flight (Run the tests)"
          let a := listRow 1 "claude-code 1" "working, 1 in flight (Run the tests)"
          let d := listRow 4 "claude-code 4" "idle, nothing in flight"
          let seen := listRow 3 "claude-code 3" "idle, 1 in flight (Run the tests)"
          saw
              (rows == header ++ #[b, c, a, d] && after == header ++ #[b, a, seen, d] &&
                says readOnly "read-only true" &&
                requests.size == 7 &&
                (requests.filter (· matches .open ..)).size == 4 &&
                (requests.filter (· matches .send _ (.prompt _))).size == 3)
              s!"rows {rows}; after {after}; read-only {readOnly}; requests {repr requests}" }]

/-- Host 1 of a restart: restores nothing, opens the lakefile, starts a
session and prompts it `done`, which ends its turn with the title
`Example title`, and, with `second`, starts a second session left idle;
then writes the session index. -/
def beforeRestart (context : HostContext) (packages : Array Package) (model : IO.Ref FileModel)
    (second : Bool) : IO Bool :=
  withStateHost context packages Fake.table model fun session _ _ => do
    session.send (.restore none)
    session.step
    session.ask [.reload]
    session.ask [.open opened]
    session.step
    unless ← startedWith session "done" do
      return false
    settledAfter session
    if second then
      unless ← startedWith session "" do
        return false
    stepIndexed session

/-- Host 2 of a restart: restores the index, steps to rest and opens the
lakefile. -/
def restored (session : Session) : IO Unit := do
  session.send (.restore none)
  session.step
  session.ask [.open opened]
  session.step

/-- Agent 1 as kept across the restart. -/
def keptFirst : String :=
  "1|sess-0001|Example title|claude-code|/work/example|finished|nothing|the editor restarted"

/-- The checks of the table across a restart (AC4). -/
def restartChecks (context : HostContext) (packages : Array Package) : List Check :=
  [{  name :=
        "AC4: after a restart over the journal's recording fake, the table's records are read back from the project's store with every session's identity and workspace, listed not running, and nothing is resumed"
      run := do
        let model ← IO.mkRef files
        unless ← beforeRestart context packages model true do
          return false
        withStateHost context packages Fake.table model fun session fake fakes => do
            restored session
            let table ← tableText session
            unless ← exStepped session Acp.Conversation.listName do
              return false
            let rows ← listLines session
            let log ← fake.log
            let started ← startedCommands fakes
            saw
                (table ==
                    " ; ".intercalate
                      [keptFirst,
                        "2|sess-0002|claude-code 2|claude-code|/work/example|idle|nothing|the editor restarted"] &&
                  rows ==
                    #["agents of example", "2 sessions", "",
                      "1 Example title: finished, unread, nothing in flight — claude-code in /work/example, session sess-0001, not running; ended: the editor restarted",
                      "2 claude-code 2: idle, nothing in flight — claude-code in /work/example, session sess-0002, not running; ended: the editor restarted"] &&
                  log.isEmpty &&
                  started.isEmpty)
                s!"table {table}; rows {rows}; log {log.size}; started {started.size}" }]

/-- The conversation's lines of the resumed session: its note and its
replayed history, in order. -/
def resumedLines : Array String :=
  #["-- resuming claude-code session sess-0001 in /work/example", "> Read notes.txt.", "Done.",
    "[+] edit: Edit notes.txt (completed) /work/example/notes.txt"]

/-- The checks of resume (AC5) and its refusal. -/
def resumeChecks (context : HostContext) (packages : Array Package) : List Check :=
  [{  name :=
        "AC5: a session from before a restart is resumed by session/load when it is first visited, with its history shown, over agents-api's fake; a second visit loads nothing, and the resumed session is live"
      run := do
        let model ← IO.mkRef files
        unless ← beforeRestart context packages model false do
          return false
        withStateHost context packages Fake.resumable model fun session fake fakes => do
            restored session
            unless ← exStepped session Acp.Conversation.listName do
              return false
            let before ← listLines session
            let quiet := (← fake.log).isEmpty
            unless ← exStepped session s!"{Acp.Conversation.visitName} 1" do
              return false
            settledAfter session
            let lines ← conversationLines session
            let store ← storeProbe session
            let table ← tableText session
            let requests ← requestsBeyondNext fake
            let started ← startedCommands fakes
            unless ← exStepped session s!"{Acp.Conversation.visitName} 1" do
              return false
            settledAfter session
            let again ← requestsBeyondNext fake
            unless ← promptedWith session "Again." do
              return false
            settledAfter session
            let turned ← conversationLines session
            let orders ← ordersOf fake
            saw
                (before[3]? ==
                    some
                      "1 Example title: finished, unread, nothing in flight — claude-code in /work/example, session sess-0001, not running; ended: the editor restarted" &&
                  quiet &&
                  lines.extract 5 9 == resumedLines &&
                  lines[1]? == some "title: Example title" &&
                  says store "store: [1]" &&
                  table == "1|sess-0001|Example title|claude-code|/work/example|idle|nothing|-" &&
                  (match requests with
                  | #[.load _ "/work/example" #[] "sess-0001"] => true
                  | _ => false) &&
                  started == #[Acp.claudeCode.command "/work/example"] &&
                  again == requests &&
                  orders == #[.prompt "Again."] &&
                  turned.contains "-- turn 1: end_turn" &&
                  (← replays fake) &&
                  (← onThread fake))
                s!"before {before}; lines {lines}; store {store}; table {table}; requests {repr requests}; started {started.size}; again {repr again}; orders {repr orders}; turned {turned}" },
    { name :=
        "a load the agent refuses is noted and recorded as the session's end, and the next visit tries it again in the same buffer"
      run := do
        let model ← IO.mkRef files
        unless ← beforeRestart context packages model false do
          return false
        withStateHost context packages Fake.table model fun session fake _ => do
            restored session
            unless ← exStepped session s!"{Acp.Conversation.visitName} 1" do
              return false
            settledAfter session
            let lines ← conversationLines session
            let table ← tableText session
            unless ← exStepped session s!"{Acp.Conversation.visitName} 1" do
              return false
            settledAfter session
            let store ← storeProbe session
            let loads := (← requestsBeyondNext fake).filter (· matches .load ..)
            let words := "the session did not resume: refused: the agent has no session sess-0001"
            saw
                (lines.contains s!"-- session ended: {words}" &&
                  table ==
                    s!"1|sess-0001|Example title|claude-code|/work/example|idle|nothing|{words}" &&
                  loads.size == 2 &&
                  says store "store: [1]")
                s!"lines {lines}; table {table}; loads {loads.size}; store {store}" }]

/-- The checks of the list buffer's refusal and close, and of a stop's
effect on the record. -/
def listBufferChecks (context : HostContext) (packages : Array Package) : List Check :=
  [{  name :=
        "closing an agents list drops it from acp's list store, and a later change writes into no closed buffer"
      run :=
        withConversation context packages Fake.table fun session _ _ => do
          unless ← started session do
            return false
          unless ← exStepped session Acp.Conversation.listName do
            return false
          let before ← listLines session
          let held ← storeProbe session
          session.ask [.run BuffersApi.closeName]
          session.step
          let dropped ← storeProbe session
          unless ← exStepped session s!"{showConversation} 1" do
            return false
          unless ← promptedWith session "work" do
            return false
          let after ← listLines session
          saw
              (before[1]? == some "1 session" && !says held "lists []" && says dropped "lists []" &&
                after.isEmpty)
              s!"before {before}; held {held}; dropped {dropped}; after {after}" },
    { name := "agent-list in a buffer with no workspace says so and makes no list"
      run :=
        withConversation context packages Fake.table fun session _ _ => do
          session.ask [.reload]
          session.step
          let said ← echoAfter session Acp.Conversation.listName
          let store ← storeProbe session
          saw (says said "agent-list: " && says said " has no workspace" && says store "lists []")
              s!"said {said}; store {store}" },
    { name :=
        "agent-stop with a request pending closes it, so the record has none pending and is not waiting"
      run :=
        withConversation context packages Fake.table fun session _ _ => do
          unless ← started session do
            return false
          unless ← promptedWith session "ask" do
            return false
          settledAfter session
          let asked ← tableText session
          unless ← stopped session do
            return false
          let after ← tableText session
          saw
              (asked ==
                  "1|sess-0001|claude-code 1|claude-code|/work/example|waiting|Edit notes.txt|-" &&
                after ==
                  "1|sess-0001|claude-code 1|claude-code|/work/example|idle|nothing|session stopped")
              s!"asked {asked}; after {after}" }]

/-- Every check of the agent table, list and resume. -/
def tableChecks (context : HostContext) (packages : Array Package) : List Check :=
  stallChecks context packages ++ orderChecks context packages ++ restartChecks context packages ++
    resumeChecks context packages ++
    listBufferChecks context packages

end AcpTest.Linked
