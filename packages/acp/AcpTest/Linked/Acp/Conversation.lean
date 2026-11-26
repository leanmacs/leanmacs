import Acp.ClaudeCode
import Acp.Conversation
import AcpTest.Check
import AcpTest.Linked.Support.Stage
import AgentsApiTest.Fake
import Editor.InputScheme.Test
import Editor.Process.Model
import Editor.Test.Linked.Host

/-!
# Linked tests: `Acp/Conversation.lean`

A session and its conversation buffer through the headless host stepped on
the check's thread (`Editor.Test.Linked.Stage.stepped`), its service
`agents-api`'s fake (`AgentsApiTest.Fake`, handed the stage as a package's
own fake) and the agent's child the stage's process fake, paused for ever:
so every job's code, every request and every completion runs on a step of
the check's, and the clock moves only when the check advances it. The
stage, its packages and the helpers the checks type and read with are
`AcpTest/Linked/Support/Stage.lean`'s. Each AC check opens
`/work/example/lakefile.lean`, starts a session with `agent-start`, and
types `agent-prompt Read notes.txt.` on the kit's ex line.

- **AC1**: the reply, the tool call and its final diff are shown.
- **AC2**: the default registration sends no `setMode`, starts its child
  with no environment of the editor's, and the buffer shows the mode the
  session reports.
- **AC3**: a thousand events the agent sends between two turns, into a
  parked `next` and across a pause, are one batch, one post, one turn and
  one published scene.
- **AC4**: an answer and a cancel, forced in both orders, end the turn
  `cancelled` with no permission request pending.
- **The commands' refusals** (`refusalChecks`): `agent-start` on a buffer
  with no workspace, at a root no workspace of the project is at, in a
  workspace where commands cannot run, and with no `claude-code`
  registered; `agent-prompt` before the session is open, while a prompt is
  on its way and while a turn is in flight; `agent-answer` with malformed
  words, a ticket not pending, an option the request did not offer, and a
  ticket answered already. Each is said in the echo area, and the fake is
  handed no open, prompt or answer for it.
- **Closing the buffer** (`closingCheck`): `buffers-api`'s fake's close
  cancels the session's job, which kills the agent's child and leaves the
  fake holding no request, and drops the conversation from the store.

None is of the wiring set: the root runs them in a plain group.
-/

namespace AcpTest.Linked

open Editor
open Editor.Test
open Editor.Test.Linked
open AgentsApi
open AgentsApiTest

/-- How many scenes the host has published, as `published` prints it. -/
def publishedCount (session : Session) : IO Nat := do
  let before := (← session.output.get).size
  session.send .published
  discard <| session.handled
  let printed := (← session.output.get).extract before
  return ((printed.findSome? fun line => (line.dropPrefix? "published ").map (·.toString)).bind
          String.toNat?).getD
      0

/-- `count` chunks of the message `msg-1`, each `x`, as the agent's own
moves. -/
def chunks (count : Nat) : List Fake.Move :=
  (List.range count).map fun _ => .event (.chunk (some "msg-1") "x")

/-- The commands the stage's process fake was asked to start. -/
def startedCommands (fakes : Stage.Fakes) : IO (Array Process.Command) := do
  return (← fakes.services.processes.started).filterMap fun (_, request) =>
      match request with
      | .start command _ => some command
      | _ => none

/-- A package named as acp's that registers `agent-start` alone, and so no
agent at `AgentsApi.Agent`: the stage of a set where nobody registered
`claude-code`. -/
def startOnly : Package :=
  { name := "acp", setup := commandWith Acp.Conversation.startName Acp.Conversation.startCommand }

/-- The checks of the commands' refusals (the module docs of
`Acp/Conversation.lean`): each refusal is said in the echo area, and
nothing is sent. -/
def refusalChecks (context : HostContext) (packages : Array Package) : List Check :=
  [{  name :=
        "agent-start refuses a buffer with no workspace, a root no workspace of the project is at, and a workspace where commands cannot run, and opens no session"
      run :=
        withConversation context packages Fake.conversation fun session fake fakes => do
          session.ask [.reload]
          let bare ← echoAfter session Acp.Conversation.startName
          session.ask [.open opened]
          session.step
          let nowhere ← echoAfter session s!"{Acp.Conversation.startName} /work/nowhere"
          session.ask [.run toReachable]
          let remote ← echoAfter session Acp.Conversation.startName
          let requests := (← fake.log).map (·.1)
          let commands ← startedCommands fakes
          let store ← storeProbe session
          saw
              (says bare "agent-start: " && says bare " has no workspace" &&
                says nowhere "agent-start: no workspace of " &&
                says nowhere " is at /work/nowhere" &&
                says remote "agent-start: " &&
                says remote " where commands cannot run" &&
                requests.isEmpty &&
                commands.isEmpty &&
                says store "store: []")
              s!"bare {bare}; nowhere {nowhere}; remote {remote}; requests {repr requests}; commands {repr commands}; store {store}" },
    { name :=
        "agent-start refuses when no agent named claude-code is registered, and opens no session"
      run :=
        withConversation context #[startOnly] Fake.conversation fun session fake fakes => do
          session.ask [.reload]
          session.ask [.open opened]
          session.step
          session.ask [.run Acp.Conversation.startName]
          session.step
          let said ← session.echo
          let requests := (← fake.log).map (·.1)
          let commands ← startedCommands fakes
          saw
              (says said s!"agent-start: no agent named {Acp.defaultAgent}" && requests.isEmpty &&
                commands.isEmpty)
              s!"said {said}; requests {repr requests}; commands {repr commands}" },
    { name := "agent-prompt refuses before the session is open, and sends nothing"
      run :=
        withConversation context packages Fake.conversation fun session fake _ => do
          session.ask [.reload]
          session.ask [.open opened]
          session.step
          -- agent-start's command runs, but no fake steps: its session job
          -- waits in the fake scheduler, so the session is not open.
          sendEx session Acp.Conversation.startName
          unless ← session.handled do
            return false
          sendEx session s!"{Acp.Conversation.promptName} {promptText}"
          unless ← session.handled do
            return false
          let early ← session.echo
          session.step
          let orders ← ordersOf fake
          let lines ← conversationLines session
          unless ← stopped session do
            return false
          saw
              (says early "agent-prompt: the session is not open yet" && orders.isEmpty &&
                !lines.contains s!"> {promptText}")
              s!"early {early}; orders {repr orders}; lines {lines}" },
    { name :=
        "agent-prompt refuses while a prompt is on its way and while a turn is in flight, and sends one prompt"
      run :=
        withConversation context packages Fake.cancellable fun session fake _ => do
          unless ← started session do
            return false
          -- Both lines run before any fake steps: the first prompt's
          -- send waits in the fake scheduler, so its reply has not come.
          sendEx session s!"{Acp.Conversation.promptName} {promptText}"
          sendEx session s!"{Acp.Conversation.promptName} again"
          unless ← session.handled do
            return false
          let onItsWay ← session.echo
          session.step
          let inFlight ← echoAfter session s!"{Acp.Conversation.promptName} third"
          let probed ← probe session
          let orders ← ordersOf fake
          unless ← stopped session do
            return false
          saw
              (says onItsWay "agent-prompt: a turn is in flight" &&
                says inFlight "agent-prompt: a turn is in flight" &&
                says probed "turn (some 1)" &&
                orders == #[.prompt promptText])
              s!"on its way {onItsWay}; in flight {inFlight}; probe {probed}; orders {repr orders}" },
    { name :=
        "agent-answer refuses malformed words, a ticket that is not pending and an option the request did not offer, and answers a ticket once"
      run :=
        withConversation context packages Fake.cancellable fun session fake _ => do
          unless ← started session do
            return false
          unless ← exStepped session s!"{Acp.Conversation.promptName} {promptText}" do
            return false
          let answer := Acp.Conversation.answerName
          let noOption ← echoAfter session s!"{answer} 1 nope"
          let notPending ← echoAfter session s!"{answer} 9 {Contract.allow}"
          let alone ← echoAfter session s!"{answer} 1"
          let noTicket ← echoAfter session s!"{answer} one {Contract.allow}"
          let before ← ordersOf fake
          let first ← echoAfter session s!"{answer} 1 {Contract.allow}"
          let twice ← echoAfter session s!"{answer} 1 {Contract.allow}"
          let orders ← ordersOf fake
          unless ← stopped session do
            return false
          saw
              (says noOption "agent-answer: the request 1 offers no option nope" &&
                says notPending "agent-answer: no permission request 9 is pending" &&
                says alone "agent-answer: give a ticket and an option's id" &&
                says noTicket "agent-answer: one is no ticket" &&
                !before.any (· matches .answer ..) &&
                !says first "agent-answer: " &&
                says twice "agent-answer: no permission request 1 is pending" &&
                (orders.filter (· matches .answer ..)) == #[.answer 1 Contract.allow])
              s!"no option {noOption}; not pending {notPending}; alone {alone}; no ticket {noTicket}; first {first}; twice {twice}; orders {repr orders}" }]

/-- The check of closing a conversation buffer (the module docs of
`Acp/Conversation.lean`): through `buffers-api`'s fake's close, which runs
the hook `BuffersApi.Closing`, the session's job is cancelled, the agent's
child killed, the fake left holding no request, and the conversation
dropped from the store. -/
def closingCheck (context : HostContext) (packages : Array Package) : Check :=
  { name :=
      "closing a conversation buffer cancels its session's job, kills its child and drops the conversation"
    run :=
      withConversation context packages Fake.conversation fun session fake fakes => do
        unless ← started session do
          return false
        let openBefore ← storeProbe session
        let waitingBefore := !(← fake.quiescent)
        let killedBefore := (← fakes.services.processes.model).killed
        session.ask [.run BuffersApi.closeName]
        session.step
        let quiescent ← fake.quiescent
        let killed := (← fakes.services.processes.model).killed
        let store ← storeProbe session
        saw
            (says openBefore "store: [1]" && waitingBefore && killedBefore.isEmpty && quiescent &&
              killed == #[agentChild.command] &&
              says store "store: []")
            s!"store before {openBefore}; waiting before {waitingBefore}; killed before {repr killedBefore}; quiescent {quiescent}; killed {repr killed}; store {store}" }

/-- The checks of a conversation through the stepped host, over `packages`,
the packages the root hands in (`Acp.packages`). -/
def conversationChecks (context : HostContext) (packages : Array Package) : List Check :=
  [{    name :=
          "AC1: a scripted session's prompt shows its reply, its tool calls and their final diffs in the conversation buffer, over agents-api's fake"
        run :=
          withConversation context packages Fake.conversation fun session fake _ => do
            unless ← started session do
              return false
            unless ← exStepped session s!"{Acp.Conversation.promptName} {promptText}" do
              return false
            session.clock.advance Acp.Conversation.batchPause
            session.step
            let folded ← conversationLines session
            session.ask [.run cursorToCall]
            for key in (TestScheme.scheme.roleKey Role.toggle).getD [] do
              session.press key
            discard <| session.handled
            let unfolded ← conversationLines session
            let readOnly ← probe session
            let thread ← onThread fake
            let replayed ← replays fake
            unless ← stopped session do
              return false
            saw
                (folded ==
                    #["claude-code in /work/example", "title: Example title",
                      "mode: Ask (mode-ask)", "usage: 1200 of 200000, 0.01 USD", "",
                      "-- starting claude-code in /work/example", "> Read notes.txt.", "Done.",
                      "[+] edit: Edit notes.txt (completed) /work/example/notes.txt",
                      "-- turn 1: end_turn"] &&
                  unfolded.extract 8 13 ==
                    #["[-] edit: Edit notes.txt (completed) /work/example/notes.txt",
                      "  /work/example/notes.txt", "      alpha", "    - beta", "    + gamma"] &&
                  (unfolded.filter (· == "    - beta")).size == 1 &&
                  unfolded[13]? == some "-- turn 1: end_turn" &&
                  (readOnly.splitOn "read-only true").length > 1 &&
                  thread &&
                  replayed)
                s!"folded {folded}; unfolded {unfolded}; probe {readOnly}; thread {thread}; replayed {replayed}" },
      { name :=
          "AC2: a session started with the default registration sends no setMode, its child gets no CLAUDE_CONFIG_DIR, and the buffer shows the reported mode"
        run :=
          withConversation context packages Fake.conversation fun session fake fakes => do
            unless ← started session do
              return false
            let before ← conversationLines session
            unless ← exStepped session s!"{Acp.Conversation.promptName} {promptText}" do
              return false
            session.clock.advance Acp.Conversation.batchPause
            session.step
            let after ← conversationLines session
            let requests := (← fake.log).map (·.1)
            let allowed :=
              requests.all fun request =>
                match request with
                | .open .. => true
                | .next _ => true
                | .send _ (.prompt _) => true
                | _ => false
            let commands :=
              (← fakes.services.processes.started).filterMap fun (_, request) =>
                match request with
                | .start command _ => some command
                | _ => none
            unless ← stopped session do
              return false
            let command := commands[0]?
            saw
                (allowed && requests.any (· matches .send _ (.prompt _)) && commands.size == 1 &&
                  command == some (Acp.claudeCode.command root) &&
                  (command.map (·.program)) == some "claude-agent-acp" &&
                  (command.map (·.arguments.isEmpty)) == some true &&
                  (command.map (·.environment)) ==
                    some { clear := false, set := #[], unset := #[] } &&
                  before[2]? == some "mode: Auto (mode-auto)" &&
                  after[2]? == some "mode: Ask (mode-ask)")
                s!"requests {repr requests}; commands {repr commands}; before {before}; after {after}" },
      { name :=
          "AC3: a thousand events queued between two turns are handled in one turn and publish one scene, into a parked next and across the pause"
        run :=
          withConversation context packages (Fake.burst 0) fun session fake fakes => do
            unless ← started session do
              return false
            unless ← exStepped session s!"{Acp.Conversation.promptName} {promptText}" do
              return false
            -- The baseline: what two reads of the count cost by themselves.
            let first ← publishedCount session
            let second ← publishedCount session
            let cost := second - first
            -- The burst, in ten pieces, into the session job's parked next.
            for _ in [0:10] do
              fake.agentSends 1 (chunks 100)
            discard <| stepFakes fakes
            let queuedOne ← fakes.memory.size
            let drained := ((← fake.session?).map (·.queue.isEmpty)) == some true
            discard <| session.handled
            let afterOne ← publishedCount session
            let oneRow :=
              (← conversationLines session).contains (String.ofList (List.replicate 1000 'x'))
            -- A second burst while the job sleeps its pause: nothing reaches the
            -- editor before the clock moves. The scene read above cost scenes
            -- of its own, so the count is read again first.
            let baseTwo ← publishedCount session
            for _ in [0:10] do
              fake.agentSends 1 (chunks 100)
            let movedAsleep ← stepFakes fakes
            let queuedAsleep ← fakes.memory.size
            session.clock.advance Acp.Conversation.batchPause
            discard <| stepFakes fakes
            let queuedTwo ← fakes.memory.size
            discard <| session.handled
            let afterTwo ← publishedCount session
            let twoRow :=
              (← conversationLines session).contains (String.ofList (List.replicate 2000 'x'))
            unless ← stopped session do
              return false
            saw
                (queuedOne == 1 && drained && afterOne - second == cost + 1 && oneRow &&
                  !movedAsleep &&
                  queuedAsleep == 0 &&
                  queuedTwo == 1 &&
                  afterTwo - baseTwo == cost + 1 &&
                  twoRow)
                s!"cost {cost}; queued {queuedOne}, drained {drained}, after one {afterOne} from {second}, one row {oneRow}; asleep moved {movedAsleep} queued {queuedAsleep}; queued two {queuedTwo}, after two {afterTwo} from {baseTwo}; two row {twoRow}" }] ++
    ([true, false].map fun answerFirst =>
      { name :=
          s!"AC4: a cancel ends the turn cancelled with no permission request pending: {if answerFirst then "answer then cancel" else "cancel then answer"}"
        run :=
          withConversation context packages Fake.cancellable fun session fake _ => do
            unless ← started session do
              return false
            unless ← exStepped session s!"{Acp.Conversation.promptName} {promptText}" do
              return false
            let parkedFirst := ((← fake.session?).map (·.protocol.parked)) == some [(1, some 1)]
            -- The forced interleaving: both lines are typed and their
            -- commands run before any fake steps, so both jobs wait in the
            -- fake scheduler in the order chosen, and the scheduler runs
            -- the older first.
            let answer := s!"{Acp.Conversation.answerName} 1 {Contract.allow}"
            let cancel := Acp.Conversation.cancelName
            for line in if answerFirst then [answer, cancel] else [cancel, answer] do
              sendEx session line
            unless ← session.handled do
              return false
            session.step
            session.clock.advance Acp.Conversation.batchPause
            session.step
            let orders ← ordersOf fake
            let sentOrder :=
              orders.filter fun order => order matches .answer .. || order matches .cancel
            let model ← fake.session?
            let trace ← fake.trace
            let replayed ← replays fake
            let lines ← conversationLines session
            let probed ← probe session
            unless ← exStepped session s!"{Acp.Conversation.promptName} again" do
              return false
            let later := (← ordersOf fake).contains (.prompt "again")
            let laterLines ← conversationLines session
            unless ← stopped session do
              return false
            let expectedOrder : Array Order :=
              if answerFirst then #[.answer 1 Contract.allow, .cancel]
              else #[.cancel, .answer 1 Contract.allow]
            let rows :=
              if answerFirst then
                lines.contains "? permission 1: Edit notes.txt [Allow, Reject] (answered Allow)" &&
                  lines.contains
                    "? permission 2: Edit notes.txt again [Allow, Reject] (withdrawn)" &&
                  trace.contains (.answer 1)
              else
                lines.contains "? permission 1: Edit notes.txt [Allow, Reject] (withdrawn)" &&
                  lines.contains "-- agent-answer: refused: the ticket 1 is not parked" &&
                  !trace.contains (.answer 1)
            saw
                (parkedFirst && sentOrder == expectedOrder &&
                  (model.map (·.protocol.parked)) == some [] &&
                  (model.map (·.protocol.outstanding)) == some [] &&
                  replayed &&
                  (probed.splitOn "pending [], turn none").length > 1 &&
                  lines.contains "-- turn 1: cancelled" &&
                  rows &&
                  later &&
                  laterLines.contains "> again")
                s!"parked first {parkedFirst}; orders {repr sentOrder}; model {repr (model.map (·.protocol))}; probe {probed}; lines {lines}; later {later}" }) ++
    refusalChecks context packages ++ [closingCheck context packages]

end AcpTest.Linked
