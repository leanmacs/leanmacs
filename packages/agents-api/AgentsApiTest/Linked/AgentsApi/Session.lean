import AgentsApiTest.Check
import AgentsApiTest.Fake
import Editor.Api
import Editor.Job.Fake
import Editor.Process.Model
import Editor.Setup
import Editor.Test.Linked.Host

/-!
# Linked tests: a session on the stepped host, over the fake

A session as a consumer runs it, through the headless host stepped on the
check's thread (`Editor.Test.Linked.Stage.stepped`), its service the fake
of `agents-api` (`AgentsApiTest.Fake`) handed the stage as a package's own
fake (`Fake.packageFake`), the agent's child the stage's process fake, so
every job's code, request and completion runs on a step of the check's.

A package of the check's own (`sessionPackage`) registers the long-lived job
`agents-test-session`, which opens a session with `AgentsApi.Job.open`,
prompts it, and loops on `next`, posting each event to the command
`agents-test-record`, which says it in the echo area; the command
`agents-test-answer`, which starts a job that answers ticket 1 `allow`; and
the command `agents-test-cancel`, which cancels the session's job by its
key.

- **AC3, stepped**: a permission request is answered while the prompt is
  still pending. At rest the fake holds the parked ticket and turn 1 is
  outstanding; the answer's job runs; the fake's log shows the answer
  arriving in a state whose turn 1 is outstanding, then the script's
  remaining events and the turn's end; the session job's last post is the
  turn's end; the fake's trace replays on the protocol's model; and every
  request came on the check's thread. Cancelling the session job then
  withdraws its `next`, leaves the fake quiescent, and the process fake
  kills its child.

The ordering properties underneath are proved on the protocol's model
(`AgentsApiTest/Protocol/Theorems.lean`); the same exchange over the real
crate and a real child is `acp`'s wiring check.
-/

namespace AgentsApiTest.Linked

open Editor
open Editor.Test.Linked
open AgentsApi

/-- The name of the session's job, of the command that starts it, and of the
key it runs under. -/
def sessionName : String :=
  "agents-test-session"

/-- The name of the command that answers ticket 1, and of its job. -/
def answerName : String :=
  "agents-test-answer"

/-- The name of the command that records an event in the echo area. -/
def recordName : String :=
  "agents-test-record"

/-- The name of the command that cancels the session's job. -/
def cancelName : String :=
  "agents-test-cancel"

/-- The agent the session opens: a child the stage's process fake runs. -/
def agent : Agent :=
  { name := "test-agent", program := "/bin/sh", arguments := #["-c", "exec sleep 600"] }

/-- The session's working directory. -/
def directory : String :=
  "/"

/-- The agent's child, as the stage's process fake runs it: a pause no step
ends, as an agent's child lives until it is ended. -/
def pausingAgent : Process.StreamScript :=
  { command := agent.command directory, steps := #[.pause 1000000000] }

/-- An event in a word or three, as the record command says it. -/
def said : AgentsApi.Event → String
  | .chunk _ _ => "chunk"
  | .toolCall call => s!"toolCall {call.id} {call.status}"
  | .permission ticket _ _ _ => s!"permission {ticket}"
  | .withdrawn ticket => s!"withdrawn {ticket}"
  | .usage .. => "usage"
  | .title _ => "title"
  | .mode id => s!"mode {id}"
  | .turnEnded turn stopReason => s!"turnEnded {turn} {stopReason}"
  | .ended _ => "ended"

/-- The session's job: opens the session, prompts it `ask`, and loops on
`next`, posting each event to the record command, until a refusal or the
session's end. -/
def sessionWork : JobM Bool := do
  match ← AgentsApi.Job.open agent directory with
  | .error _ =>
    return false
  | .ok opened =>
    discard <| AgentsApi.Job.send opened.session (.prompt Contract.promptText)
    for _ in [0:64] do
      match ← AgentsApi.Job.next opened.session with
      | .error _ =>
        return false
      | .ok batch =>
        for event in batch.events do
          post { command := recordName, arguments := [.str (said event)] }
        if batch.events.any (· matches .ended _) then
          return true
    return false

/-- The package of the check: the session's job and the commands that start
it, answer ticket 1, record an event and cancel the session. -/
def sessionPackage : Package :=
  { name := "agents-test"
    setup := do
      job sessionName (fun _ => sessionWork) fun _ => pure ()
      command sessionName (discard <| startJob sessionName [] (some sessionName))
      job answerName (fun _ => AgentsApi.Job.send 1 (.answer 1 Contract.allow)) fun _ => pure ()
      command answerName (discard <| startJob answerName)
      commandWith recordName fun call =>
          match call.arguments with
          | [.str word] => message s!"{recordName}: {word}"
          | _ => pure ()
      command cancelName (cancelJob sessionName) }

/-- Runs `check` against a host stepped on the check's thread over a stepped
stage of `context`'s elaborator with no config, handed `sessionPackage`,
whose service `agents` is `fake` and whose children are the process fake
running `pausingAgent`. `check` is handed the session and the process
fake. -/
def withSessionHost (context : HostContext) (fake : Fake)
    (check : Session → Job.FakeProcesses → IO Bool) : IO Bool := do
  let stage ←
    Stage.new context context.elaborator (memorySource []) { packages := #[sessionPackage] }
  let stage ←
    stage.stepped (processes := { streams := #[pausingAgent] }) (packageFakes :=
        #[fake.packageFake])
  let some fakes := stage.fakes | return false
  onStage stage fun drive stage =>
      check (Session.ofStage drive directory stage) fakes.services.processes

/-- Whether `text` holds `part`. -/
def holds (text part : String) : Bool :=
  (text.splitOn part).length > 1

/-- An order of the process fake's log, as a check compares it. -/
def processOrder : Job.FakeProcesses.Order → String
  | .start _ request =>
    match request with
    | .start .. => "start child"
    | _ => "start"
  | .flush _ => "flush"
  | .withdraw _ => "withdraw"
  | .kill _ => "kill"
  | .handOff _ => "handOff"

/-- The checks of a session on the stepped host. -/
def sessionChecks (context : HostContext) : List Check :=
  [{  name :=
        "AC3, stepped: a permission request is answered while the prompt is still pending, over agents-api's fake"
      run := do
        let fake ← Fake.new Fake.answerEnds
        withSessionHost context fake fun session processes => do
            let thread ← IO.getTID
            session.ask [.reload]
            session.ask [.run sessionName]
            session.step
            -- At rest: the prompt's turn is outstanding and its permission
            -- request parked, which the session job has posted last.
            let atRest ← fake.session?
            let parked := atRest.map (·.protocol.parked)
            let outstanding := atRest.map (·.protocol.outstanding)
            let echoAtRest ← session.echo
            session.ask [.run answerName]
            session.step
            let log ← fake.log
            let answeredIn :=
              log.find? fun (request, _, _) => request == .send 1 (.answer 1 Contract.allow)
            let trace ← fake.trace
            let echoAfter ← session.echo
            let replays := (Protocol.replay trace).toOption.isSome
            session.ask [.run cancelName]
            session.step
            let children := (← processes.log).map (processOrder ·.1)
            saw
                (parked == some [(1, some 1)] && outstanding == some [1] &&
                  holds echoAtRest s!"{recordName}: permission 1" &&
                  answeredIn.any (fun (_, state, _) => state.outstanding == [1]) &&
                  trace == [.send 1 (some 1), .ask 1, .answer 1, .respond 1] &&
                  holds echoAfter s!"{recordName}: turnEnded 1 end_turn" &&
                  replays &&
                  log.all (·.2.2 == thread) &&
                  children.contains "kill" &&
                  (← fake.quiescent))
                s!"parked {repr parked}, outstanding {outstanding}, echo at rest {echoAtRest}, answered in {repr (answeredIn.map (·.2.1))}, trace {repr trace}, echo after {echoAfter}, threads {log.map (·.2.2)} on {thread}, children {children}" }]

end AgentsApiTest.Linked
