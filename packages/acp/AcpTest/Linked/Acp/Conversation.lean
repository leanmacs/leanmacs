import Acp.ClaudeCode
import Acp.Conversation
import AcpTest.Check
import AgentsApiTest.Fake
import BuffersApiTest.Fake
import Editor.Api
import Editor.File.Model
import Editor.InputScheme.Test
import Editor.Jumps
import Editor.Process.Model
import Editor.Test.Ex
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Test.Minibuffer
import Editor.Test.Workspace
import FilesApiTest.Fake

/-!
# Linked tests: `Acp/Conversation.lean`

A session and its conversation buffer through the headless host stepped on
the check's thread (`Editor.Test.Linked.Stage.stepped`), its service
`agents-api`'s fake (`AgentsApiTest.Fake`, handed the stage as a package's
own fake) and the agent's child the stage's process fake, paused for ever:
so every job's code, every request and every completion runs on a step of
the check's, and the clock moves only when the check advances it.

The stage's host is handed the core's test kit's ex line, minibuffer and
attach stand-in (a buffer that takes in a file gets the workspace at
`/work/example`), `files-api`'s fake, `buffers-api`'s fake (whose
`close-buffer` runs the hook `BuffersApi.Closing`), then the packages the
root hands in, `acp`'s, with its crate's service dropped (a stepped
stage's package services are its fakes), then the check's own package
(`probePackage`). It imports no implementation package: the keys a check
presses are read from the test scheme's role table, never named. Each AC
check opens `/work/example/lakefile.lean`, starts a session with
`agent-start`, and types `agent-prompt Read notes.txt.` on the kit's ex
line.

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

/-- The workspace's root. -/
def root : String :=
  "/work/example"

/-- The file each check opens: a marker of the workspace. -/
def opened : String :=
  "/work/example/lakefile.lean"

/-- The prompt each check types. -/
def promptText : String :=
  "Read notes.txt."

/-- The agent's child, as the stage's process fake runs it: exactly the
command the session job starts, paused for ever, as an agent lives until it
is ended. -/
def agentChild : Process.StreamScript :=
  { command := Acp.claudeCode.command root, steps := #[.pause 1000000000] }

/-- The name of the check's command that puts the focused view's cursor on
the first row of the tool call `call-edit-1`. -/
def cursorToCall : String :=
  "test-cursor-to-call"

/-- The name of the check's command that says, in the echo area, what the
focused buffer's conversation holds. -/
def probeName : String :=
  "test-probe"

/-- The name of the check's command that says, in the echo area, the
number of every conversation in acp's store. -/
def storeName : String :=
  "test-store"

/-- The name of the check's command that gives the focused buffer a
workspace on another machine, where commands cannot run. -/
def toReachable : String :=
  "test-to-reachable"

/-- The workspace `test-to-reachable` gives: a pod's `/app`, which a command
would reach through `kube`. -/
def reachable : Location :=
  .reachable "kube" "pod" "/app"

/-- The check's own package: `test-cursor-to-call`, which reads the
conversation from acp's store and the call's row from its render
(`Acp.Conversation.rowOf`), and places the cursor there as compile places
its followers; `test-probe`, which says the pending tickets, the turn
in flight and whether the buffer is read-only; `test-store`, which says the
number of every conversation in the store; and `test-to-reachable`, which
gives the focused buffer a workspace where commands cannot run. -/
def probePackage : Package :=
  { name := "acp-test"
    setup := do
      commandWith cursorToCall fun call => do
          let some conversation ← Acp.Conversation.ofBuffer? call.target.window.buffer | return
          let view ← Acp.Conversation.chosenView
          let some row := Acp.Conversation.rowOf view conversation "call-edit-1" | return
          let offset ← call.target.buffer.text.offsetOf ⟨row, 0⟩
          Jumps.placeCursor call.target.window.id offset
      commandWith probeName fun call => do
          let some conversation ←
            Acp.Conversation.ofBuffer? call.target.window.buffer | message "probe: none"
          let readOnly := ((← editorState).buffer? call.target.window.buffer).any (·.readOnly)
          message
              s!"probe: pending {conversation.pending.toList}, turn {conversation.turn}, read-only {readOnly}"
      commandWith storeName fun _ => do
          message s!"store: {((← Acp.Conversation.conversations).map (·.number)).toList}"
      commandWith toReachable fun call => do
          discard <| Workspace.register reachable "git@example.invalid:o/r.git"
          Workspace.setBufferWorkspace call.target.window.buffer reachable }

/-- The packages a stage's host is handed (the module docs). -/
def stagePackages (packages : Array Package) : Array Package :=
  #[exLinePackage, Minibuffer.package, FilesApiTest.fake, BuffersApiTest.fake,
      attachPackage (Workspace.Found.ofMarker root)] ++
    packages.map (fun package => { package with services := #[] }) ++
    #[probePackage]

/-- The file fake's model: `/work/example` holding an empty
`lakefile.lean`. -/
def files : FileModel :=
  ((({} : FileModel).withDirectory "/").withDirectory "/work").withDirectory root |>.withFile opened
    .empty

/-- Runs `check` against a host stepped on the check's thread over a stepped
stage of `context`'s elaborator with no config, handed `stagePackages
packages`, whose service `agents` is a fake over `script` and whose agent's
child is `agentChild`. `check` is handed the session, the fake and the
stage's fakes. -/
def withConversation (context : HostContext) (packages : Array Package) (script : Fake.Script)
    (check : Session → Fake → Stage.Fakes → IO Bool) : IO Bool := do
  let fake ← Fake.new script
  let stage ←
    Stage.new context context.elaborator (memorySource []) { packages := stagePackages packages }
  let stage ← stage.stepped files { streams := #[agentChild] } (packageFakes := #[fake.packageFake])
  let some fakes := stage.fakes | return false
  onStage stage fun drive stage => check (Session.ofStage drive "/" stage) fake fakes

/-- Types `line` on the kit's ex line: the command `ex` asks, `line` is
committed into the minibuffer and the accept key pressed. Sends the
requests and waits for nothing. -/
def sendEx (session : Session) (line : String) : IO Unit := do
  session.send (.run ExLine.name)
  session.commit line
  for key in acceptKeys do
    session.press key

/-- Types `line` on the kit's ex line, drains the host's queue, and steps
the session to rest. -/
def exStepped (session : Session) (line : String) : IO Bool := do
  sendEx session line
  unless ← session.handled do
    return false
  session.step
  return true

/-- The text a quoted string of a scene line holds, from the quote at its
start to the one that ends it, and what follows; none when it is no quoted
string. -/
partial def unquote? (chars : List Char) (done : String := "") : Option (String × List Char) :=
  match chars with
  | '"' :: rest => some (done, rest)
  | '\\' :: 'n' :: rest => unquote? rest (done.push '\n')
  | '\\' :: 't' :: rest => unquote? rest (done.push '\t')
  | '\\' :: 'r' :: rest => unquote? rest (done.push '\r')
  | '\\' :: c :: rest => unquote? rest (done.push c)
  | c :: rest => unquote? rest (done.push c)
  | [] => none

/-- The text the scene shows in a view of the conversation buffer, a line a
row: the first view whose text starts as a conversation's header does. -/
def conversationLines (session : Session) : IO (Array String) := do
  for line in ← session.sceneLines do
    if line.startsWith "view " then
      match (line.splitOn ": \"").drop 1 with
      | [] =>
        pure ()
      | parts =>
        if let some (text, _) := unquote? (": \"".intercalate parts).toList then
          if text.startsWith s!"{Acp.defaultAgent} in " then
            return ((text.splitOn "\n").toArray.popWhile (·.isEmpty))
  return #[]

/-- Opens the marker file, starts a session and steps to rest: the session
open and its job parked on `next`. -/
def started (session : Session) : IO Bool := do
  session.ask [.reload]
  session.ask [.open opened]
  session.step
  exStepped session Acp.Conversation.startName

/-- The check's thread's requests, as the fake logged them. -/
def onThread (fake : Fake) : IO Bool := do
  let thread ← IO.getTID
  return (← fake.log).all (·.2.2 == thread)

/-- Whether the trace of the fake's session replays on the protocol's model
with no violation. -/
def replays (fake : Fake) : IO Bool := do
  return (Protocol.replay (← fake.trace)).toOption.isSome

/-- Stops the session (`agent-stop`) and steps to rest, so the check leaves
no job running. -/
def stopped (session : Session) : IO Bool :=
  exStepped session Acp.Conversation.stopName

/-- The echo area's text after `test-probe`. -/
def probe (session : Session) : IO String := do
  session.ask [.run probeName]
  session.echo

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

/-- Every piece of the stage's fakes' work that can run, run, and no host
queue drained: whether any ran. -/
def stepFakes (fakes : Stage.Fakes) : IO Bool := do
  let mut ran := false
  while ← fakes.stepWork do
    ran := true
  return ran

/-- The order the session's requests carried, as a check reads the fake's
log. -/
def ordersOf (fake : Fake) : IO (Array Order) := do
  return (← fake.log).filterMap fun (request, _, _) =>
      match request with
      | .send _ order => some order
      | _ => none

/-- Whether the echo area's text `echo` says `text`. -/
def says (echo text : String) : Bool :=
  (echo.splitOn text).length > 1

/-- Types `line` on the kit's ex line, steps the session to rest, and returns
what the echo area then says. -/
def echoAfter (session : Session) (line : String) : IO String := do
  unless ← exStepped session line do
    return "the ex line was not handled"
  session.echo

/-- The echo area's text after `test-store`. -/
def storeProbe (session : Session) : IO String := do
  session.ask [.run storeName]
  session.echo

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
