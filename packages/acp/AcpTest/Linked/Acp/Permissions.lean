import Acp.Permissions
import AcpTest.Acp.Permissions.Audit
import AcpTest.Linked.Support.Stage

/-!
# Linked tests: `Acp/Permissions.lean`

The queue of a project's permission requests, the policy and the audit
log, through the headless host stepped on the check's thread over
`agents-api`'s fake (`AcpTest/Linked/Support/Stage.lean`), the agent the
fake's `permissionRequest` script: a prompt parks ticket 1 for an edit of
`notes.txt`, offering the adapter's three options, and its answer ends the
turn. A conversation that no view shows is read from acp's store through
the check's `test-probe-conversation`, so two conversations of one header
are told apart.

- **AC2**: two sessions of one project each park ticket 1; both are in one
  queue, and answering one from the queue answers that session's request
  alone.
- **AC3**: a request pending across a config reload is still in the queue
  after it, and answering it from the queue answers the session, whose job
  lived through the reload.
- **AC4**: every request and its answer are appended to the audit log
  under the host's state directory, by the orders the file fake was handed,
  for an answer from the queue, a policy's answer, a withdrawal and a
  close; and nothing but appends, after the directory's make, names it.
- **Silence**: a session that never asks leaves the queue empty, sends no
  answer, writes no record and waits on nothing but its session's `next`.
- **The queue's refusals**, **an answer asked for** by the queue's prompt,
  and **closing the queue buffer**.

None is of the wiring set: the root runs them in a plain group.
-/

namespace AcpTest.Linked

open Editor
open Editor.Test
open Editor.Test.Linked
open AgentsApi
open AgentsApiTest

/-- The state directory of the stages that keep an audit log. -/
def stateDirectory : System.FilePath :=
  "/state"

/-- The audit log of `stateDirectory`. -/
def auditLog : System.FilePath :=
  Acp.Permissions.logPath stateDirectory

/-- The queue's text the scene shows: the first view whose text starts as
a queue's does. -/
def queueLines (session : Session) : IO (Array String) :=
  bufferLines session "permissions of "

/-- The text of the conversation `number`, as acp's store holds it: the
echo of `test-probe-conversation`, a line a row. -/
def conversationText (session : Session) (number : Nat) : IO (Array String) := do
  let echo ← echoAfter session s!"{conversationProbe} {number}"
  let unquoted :=
    match echo.toList with
    | '"' :: rest => ((unquote? rest).map Prod.fst).getD echo
    | _ => echo
  match unquoted.dropPrefix? "conversation: " with
  | some text =>
    return (text.toString.splitOn " | ").toArray
  | none =>
    return #[]

/-- Prompts the focused conversation and steps until its first batch is
handled and the session job parked again on `next`. -/
def prompted (session : Session) : IO Bool := do
  unless ← exStepped session s!"{Acp.Conversation.promptName} {promptText}" do
    return false
  session.clock.advance Acp.Conversation.batchPause
  session.step
  return true

/-- Steps the session to rest, moves the clock a pause, and steps again. -/
def settledAfter (session : Session) : IO Unit := do
  session.step
  session.clock.advance Acp.Conversation.batchPause
  session.step

/-- The queue's row of a pending request of the conversation `number`,
ticket 1, as the default view lists it. -/
def requestRow (number : Nat) : String :=
  s!"? claude-code in /work/example, conversation {number}, ticket 1: Edit notes.txt"

/-- The rows the default view lists below a request's first. -/
def requestBody : Array String :=
  #["  input: {\"file_path\":\"/work/example/notes.txt\",\"old_string\":\"beta\",\"new_string\":\"gamma\"}",
    "  /work/example/notes.txt", "    - beta", s!"    {Acp.Conversation.noLineFeed}", "    + gamma",
    s!"    {Acp.Conversation.noLineFeed}",
    "  options: allow-once (Yes), allow-session (Yes, for this session), reject (No)"]

/-- The conversation's row of its permission request, pending. -/
def pendingRow : String :=
  "? permission 1: Edit notes.txt [Yes, Yes, for this session, No]"

/-- The answers the fake was handed, each with its session. -/
def answersOf (fake : Fake) : IO (Array (Nat × Order)) := do
  return (← fake.log).filterMap fun (request, _, _) =>
      match request with
      | .send session (.answer ticket optionId) => some (session, .answer ticket optionId)
      | _ => none

/-- The orders the file fake was handed that name the audit log or its
directory, oldest first. -/
def logOrders (fakes : Stage.Fakes) : IO (Array FileRequest) := do
  let directory := (auditLog.parent).getD stateDirectory
  return (← fakes.services.files.started).filterMap fun (_, request) =>
      match request with
      | .load path _ | .save _ path _ | .stamp path | .list path | .makeDirectory path |
        .append path _ | .remove path =>
        if path == auditLog || path == directory then some request else none

/-- Whether `orders` keep the log append-only: each append of the log comes
after a make of its directory, and nothing but an append, or that make,
names it. -/
def appendOnly (orders : Array FileRequest) : Bool :=
  let directory := (auditLog.parent).getD stateDirectory
  (List.range orders.size).all fun index =>
    match orders[index]? with
    | some (.append path _) =>
      path == auditLog && (orders.extract 0 index).any (· == .makeDirectory directory)
    | some (.makeDirectory path) => path == directory
    | _ => false

/-- The bytes `orders` append to the log, in order, as text. -/
def appended (orders : Array FileRequest) : String :=
  String.fromUTF8! <|
    orders.foldl (init := ByteArray.empty) fun bytes order =>
      match order with
      | .append _ more => bytes ++ more
      | _ => bytes

/-- The log as the file fake's model holds it, as text. -/
def logHeld (fakes : Stage.Fakes) : IO String := do
  return (((← fakes.services.files.model).file? auditLog).map fun file =>
          String.fromUTF8! file.bytes).getD
      ""

/-- The records' lines, each ended by a line feed. -/
def logText (lines : List String) : String :=
  String.join (lines.map (· ++ "\n"))

/-- The line of a decision of the default policy, `decision` its word. -/
def decidedLine (decision : String) : String :=
  s!"decided\tconversation=1\tticket=1\tpolicy=default\tdecision={decision}"

/-- A package after acp's that registers, under the default name, a policy
that answers `allow_once`: so it is the latest `default`. -/
def allowOncePolicy : Package :=
  { name := "acp-test-policy"
    setup :=
      Extension.add
        ({  name := PermissionPolicy.defaultName
            decide := fun request => .ofKind request "allow_once" } : PermissionPolicy) }

/-- One case of AC4: how the request is answered, and the log it leaves. -/
structure AuditCase where
  /-- What the case is. -/
  name : String
  /-- The packages after acp's. -/
  extra : Array Package := #[]
  /-- What the check does once the request is parked, from the conversation
  buffer: whether it was handled. -/
  answer : Session → IO Bool
  /-- The log's lines after it. -/
  expected : List String

/-- The cases of AC4. -/
def auditCases : List AuditCase :=
  [{  name := "asked and answered by the user from the queue"
      answer := fun session => do
        unless ← exStepped session Acp.Conversation.queueName do
          return false
        unless ← exStepped session s!"{cursorToRequest} 1 1" do
          return false
        exStepped session s!"{Acp.Conversation.queueAnswerName} allow-once"
      expected :=
        [askedLine, decidedLine "ask",
          "answered\tconversation=1\tticket=1\toption=allow-once\tby=user"] },
    { name := "decided by a policy"
      extra := #[allowOncePolicy]
      answer := fun _ => return true
      expected :=
        [askedLine, decidedLine "allow-once",
          "answered\tconversation=1\tticket=1\toption=allow-once\tby=policy"] },
    { name := "withdrawn by a cancel"
      answer := fun session => exStepped session Acp.Conversation.cancelName
      expected := [askedLine, decidedLine "ask", "withdrawn\tconversation=1\tticket=1"] },
    { name := "closed by agent-stop"
      answer := fun session => exStepped session Acp.Conversation.stopName
      expected :=
        [askedLine, decidedLine "ask",
          "closed\tconversation=1\tticket=1\treason=session stopped"] }]

/-- The checks of AC4, one a case, each on a fresh stage. -/
def auditChecks (context : HostContext) (packages : Array Package) : List Check :=
  auditCases.map fun case =>
    { name :=
        s!"AC4: every request and its answer are appended to the audit log, by the orders the file port's fake was handed: {case.name}"
      run :=
        withConversation context packages Fake.permissionRequest (state := some stateDirectory)
          (extra := case.extra) fun session fake fakes => do
          unless ← started session do
            return false
          unless ← prompted session do
            return false
          unless ← case.answer session do
            return false
          settledAfter session
          let orders ← logOrders fakes
          let text := appended orders
          let held ← logHeld fakes
          let answers ← answersOf fake
          let queue ←
            if case.extra.isEmpty then
              pure #[]
            else
              do
                unless ← exStepped session Acp.Conversation.queueName do
                  return false
                queueLines session
          let expected := logText case.expected
          let policyHeld :=
            case.extra.isEmpty ||
              answers == #[(1, .answer 1 "allow-once")] && queue[1]? == some "nothing pending"
          saw
              (appendOnly orders && orders.any (· matches .append ..) && text == expected &&
                held == expected &&
                policyHeld)
              s!"orders {repr orders}; text {repr text}; held {repr held}; answers {repr answers}; queue {queue}" }

/-- The checks of the supporting behaviour: silence, the queue's refusals and
closing the queue buffer. -/
def supportingChecks (context : HostContext) (packages : Array Package) : List Check :=
  [{  name :=
        "a session that never asks leaves the queue empty, sends no answer, writes no record and waits on nothing but its session's next"
      run :=
        withConversation context packages Fake.conversation (state := some stateDirectory)
          fun session fake fakes => do
          unless ← started session do
            return false
          unless ← prompted session do
            return false
          let orders ← ordersOf fake
          let pending := (← fake.state.get).pending.map (·.2.1)
          unless ← exStepped session Acp.Conversation.queueName do
            return false
          let queue ← queueLines session
          let logged ← logOrders fakes
          unless ← exStepped session s!"{showConversation} 1" do
            return false
          unless ← stopped session do
            return false
          let quiescent ← fake.quiescent
          saw
              (orders == #[.prompt promptText] && pending == #[.next 1] &&
                queue == #["permissions of example", "nothing pending"] &&
                logged.isEmpty &&
                quiescent)
              s!"orders {repr orders}; pending {repr pending}; queue {queue}; logged {repr logged}; quiescent {quiescent}" },
    { name :=
        "agent-queue refuses a buffer with no workspace, and agent-queue-answer a row with no request and an option the request did not offer, and none is sent"
      run :=
        withConversation context packages Fake.permissionRequest fun session fake _ => do
          session.ask [.reload]
          let bare ← echoAfter session Acp.Conversation.queueName
          session.ask [.open opened]
          session.step
          unless ← exStepped session Acp.Conversation.startName do
            return false
          unless ← prompted session do
            return false
          unless ← exStepped session Acp.Conversation.queueName do
            return false
          let header ← echoAfter session s!"{Acp.Conversation.queueAnswerName} allow-once"
          unless ← exStepped session s!"{cursorToRequest} 1 1" do
            return false
          let nope ← echoAfter session s!"{Acp.Conversation.queueAnswerName} nope"
          let answers ← answersOf fake
          saw
              (says bare "agent-queue: " && says bare " has no workspace" &&
                says header "agent-queue-answer: no request on this line" &&
                says nope "agent-queue-answer: the request 1 offers no option nope" &&
                answers.isEmpty)
              s!"bare {bare}; header {header}; nope {nope}; answers {repr answers}" },
    { name :=
        "agent-queue-answer with no option asks for one, naming the ticket and the offered ids, and the answer goes to the request it asked about"
      run :=
        withConversation context packages Fake.permissionRequest fun session fake _ => do
          unless ← started session do
            return false
          unless ← prompted session do
            return false
          unless ← exStepped session Acp.Conversation.queueName do
            return false
          unless ← exStepped session s!"{cursorToRequest} 1 1" do
            return false
          unless ← exStepped session Acp.Conversation.queueAnswerName do
            return false
          let asked := " | ".intercalate (← session.sceneLines).toList
          session.commit "allow-once"
          for key in acceptKeys do
            session.press key
          unless ← session.handled do
            return false
          settledAfter session
          let answers ← answersOf fake
          let after ← queueLines session
          saw
              (says asked "Answer 1 (allow-once, allow-session, reject): " &&
                answers == #[(1, .answer 1 "allow-once")] &&
                after == #["permissions of example", "nothing pending"])
              s!"asked {asked}; answers {repr answers}; after {after}" },
    { name :=
        "closing the queue buffer drops it from acp's queue store, and a later change writes into no closed buffer"
      run :=
        withConversation context packages Fake.permissionRequest fun session _ _ => do
          unless ← started session do
            return false
          unless ← exStepped session Acp.Conversation.queueName do
            return false
          let before ← queueLines session
          session.ask [.run BuffersApi.closeName]
          session.step
          let closed ← queueLines session
          unless ← exStepped session s!"{showConversation} 1" do
            return false
          unless ← prompted session do
            return false
          let after ← queueLines session
          let text ← conversationText session 1
          saw
              (before[1]? == some "nothing pending" && closed.isEmpty && after.isEmpty &&
                text.contains pendingRow)
              s!"before {before}; closed {closed}; after {after}; text {text}" }]

/-- The checks of the queue, the policy and the audit log through the
stepped host, over `packages`, the packages the root hands in
(`Acp.packages`). -/
def permissionChecks (context : HostContext) (packages : Array Package) : List Check :=
  [{    name :=
          "AC2: permission requests from two sessions of one project appear in one queue, and answering one from the queue answers that session's request, over agents-api's fake"
        run :=
          withConversation context packages Fake.permissionRequest fun session fake _ => do
            unless ← started session do
              return false
            unless ← exStepped session s!"{Acp.Conversation.promptName} {promptText}" do
              return false
            session.ask [.open opened]
            session.step
            unless ← exStepped session Acp.Conversation.startName do
              return false
            unless ← prompted session do
              return false
            let parked (number : Nat) : IO Bool := do
              return ((← fake.session? number).map (·.protocol.parked)) == some [(1, some 1)]
            let parkedBoth := (← parked 1) && (← parked 2)
            unless ← exStepped session Acp.Conversation.queueName do
              return false
            let queue ← queueLines session
            session.ask [.run readOnlyProbe]
            let readOnly ← session.echo
            unless ← exStepped session s!"{cursorToRequest} 2 1" do
              return false
            unless ← exStepped session s!"{Acp.Conversation.queueAnswerName} allow-once" do
              return false
            settledAfter session
            let answers ← answersOf fake
            let traceOne ← fake.trace 1
            let traceTwo ← fake.trace 2
            let stillOne ← parked 1
            let parkedTwo := (← fake.session? 2).map (·.protocol.parked)
            let after ← queueLines session
            let one ← conversationText session 1
            let two ← conversationText session 2
            let thread ← onThread fake
            let replayed :=
              (Protocol.replay traceOne).toOption.isSome &&
                (Protocol.replay traceTwo).toOption.isSome
            saw
                (parkedBoth &&
                  queue ==
                    #["permissions of example", "2 pending", "", requestRow 1] ++ requestBody ++
                      #[requestRow 2] ++
                      requestBody &&
                  says readOnly "read-only true" &&
                  answers == #[(2, .answer 1 "allow-once")] &&
                  traceTwo.contains (.answer 1) &&
                  !traceOne.contains (.answer 1) &&
                  stillOne &&
                  parkedTwo == some [] &&
                  after ==
                    #["permissions of example", "1 pending", "", requestRow 1] ++ requestBody &&
                  two.contains s!"{pendingRow} (answered Yes)" &&
                  two.contains "-- turn 1: end_turn" &&
                  one.contains pendingRow &&
                  !one.contains "-- turn 1: end_turn" &&
                  thread &&
                  replayed)
                s!"parked {parkedBoth}; queue {queue}; read-only {readOnly}; answers {repr answers}; traces {repr traceOne} {repr traceTwo}; after {after}; one {one}; two {two}; thread {thread}; replayed {replayed}" },
      { name :=
          "AC3: a request pending across a config reload is still in the queue after it, and answering it from the queue answers the session"
        run :=
          withConversation context packages Fake.permissionRequest fun session fake _ => do
            unless ← started session do
              return false
            unless ← prompted session do
              return false
            unless ← exStepped session Acp.Conversation.queueName do
              return false
            let before ← queueLines session
            let reloads := (← session.output.get).size
            session.ask [.reload]
            session.step
            let installed :=
              ((← session.output.get).extract reloads).any (·.startsWith "reload 2: installed")
            let waiting := ((← fake.session? 1).bind (·.waiting)).isSome && !(← fake.quiescent)
            let shown ← queueLines session
            unless ← exStepped session Acp.Conversation.queueName do
              return false
            let again ← queueLines session
            unless ← exStepped session s!"{cursorToRequest} 1 1" do
              return false
            unless ← exStepped session s!"{Acp.Conversation.queueAnswerName} allow-once" do
              return false
            settledAfter session
            let answers ← answersOf fake
            let trace ← fake.trace 1
            let text ← conversationText session 1
            let after ← queueLines session
            let pendingQueue :=
              #["permissions of example", "1 pending", "", requestRow 1] ++ requestBody
            saw
                (before == pendingQueue && installed && waiting && shown == pendingQueue &&
                  again == pendingQueue &&
                  answers == #[(1, .answer 1 "allow-once")] &&
                  trace.contains (.answer 1) &&
                  text.contains s!"{pendingRow} (answered Yes)" &&
                  text.contains "-- turn 1: end_turn" &&
                  after == #["permissions of example", "nothing pending"])
                s!"before {before}; installed {installed}; waiting {waiting}; shown {shown}; again {again}; answers {repr answers}; text {text}; after {after}" }] ++
    auditChecks context packages ++ supportingChecks context packages

end AcpTest.Linked
