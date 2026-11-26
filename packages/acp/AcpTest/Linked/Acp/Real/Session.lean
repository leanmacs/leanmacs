import Acp.Real
import AcpTest.Check
import AcpTest.ScriptedAgent
import AgentsApiTest.Protocol
import Editor.Job.Fake
import Editor.Job.Protocol
import Editor.Job.Runner
import Editor.RealHost
import Editor.Test.Jobs
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Services

/-!
# Linked tests: the acp crate on a real child, through the process service

The crate's service as the job runner's package service, given the
package services the program's edge builds from acp's packages
(`Editor.Headless.packageServices Acp.packages`, which the linked test's
root hands in, as only the root may import the headless host), over the
linked test kit's real services and the completion pump running over their
table. A session runs as a consumer runs it, through `agents-api`'s job
wrappers alone, on the scripted agent executable (`AcpTest.ScriptedAgent`),
a real child of the core's process service that the crate takes over.

- **AC4**: one session job opens the session with `AgentsApi.Job.open`,
  prompts it `ask`, and loops on `next`, posting each event; a second job
  answers ticket 1 `allow` once the session job has posted it, while the
  prompt is pending; a third cancels the turn once ticket 2 is posted. The
  events are, in order, the session opened, a chunk, the tool call, the
  permission request of ticket 1, the call completed, that of ticket 2, its
  withdrawal, the turn's end `cancelled` and, last, `ended exited 0`: the
  scripted agent exits by itself once it has answered the cancelled
  prompt, and exits 0 only if every line it read was the one it expected,
  so that last event is its own verdict that the client sent exactly the
  expected lines in order: an `initialize` offering no `fs` and no
  `terminal`, and no `session/set_mode`. A fourth job's
  answer to ticket 2 after the cancel is refused. The trace of the orders
  and events replays on the protocol's model, and the runner's trace of
  every job here on the job protocol's model, its package waits as service
  waits. Once the session job has
  ended, the runner's flushes of the service `agents` and of the process
  service complete, so the crate and the process service have finished
  what was handed to them.

Each wait is on an event (a job's outcome, a post, a flush's end), the
kit's patience a hang guard. The ordering properties are the protocol
model's theorems (`agents-api`'s `AgentsApiTest/Protocol/Theorems.lean`),
forced on the stepped host over the fake (`agents-api`'s
`AgentsApiTest/Linked/AgentsApi/Session.lean`) and in the crate's own
`LocalPool` tests (`rust/src/session/tests.rs`).
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.AcpTest.Linked.Acp.Real.Session : Editor.WiringSet :=
  .wiring "the acp crate on a real child through the process service"
    "only a real child exercises the take-over, the SDK's threads and the completion queue together"

namespace AcpTest.Linked

open Editor
open Editor.Test

/-- The name of the command the session job posts each event to. -/
def recordName : String :=
  "acp-test-record"

/-- An event in a word or three, as the session job posts it. -/
def said : AgentsApi.Event → String
  | .chunk _ _ => "chunk"
  | .userChunk _ _ => "userChunk"
  | .toolCall call => s!"toolCall {call.id} {call.status}"
  | .permission ticket _ _ _ => s!"permission {ticket}"
  | .withdrawn ticket => s!"withdrawn {ticket}"
  | .usage .. => "usage"
  | .title _ => "title"
  | .mode id => s!"mode {id}"
  | .turnEnded turn stopReason => s!"turnEnded {turn} {stopReason}"
  | .ended (.exited code) => s!"ended exited {code}"
  | .ended how => s!"ended {repr how}"

/-- Posts `word` to the record command. -/
def record (word : String) : JobM Unit :=
  post { command := recordName, arguments := [.str word] }

/-- The session job: opens the session on the scripted agent in
`directory`, posts its number, prompts it `ask`, and loops on `next`,
posting each event, until the session's end: whether it ended with the
agent's exit 0. -/
def sessionWork (directory : String) : JobM Bool := do
  match ← AgentsApi.Job.open ScriptedAgent.agent directory with
  | .error refusal =>
    record s!"refused {repr refusal}"
    return false
  | .ok opened =>
    record s!"opened {opened.session}"
    discard <| AgentsApi.Job.send opened.session (.prompt AgentsApiTest.Contract.promptText)
    for _ in [0:64] do
      match ← AgentsApi.Job.next opened.session with
      | .error refusal =>
        record s!"refused {repr refusal}"
        return false
      | .ok batch =>
        for event in batch.events do
          record (said event)
        if let some (.ended how) := batch.events.back? then
          return how == .exited 0
    return false

/-- What the session job posted, oldest first, and the posts a check
waits for, each resolved once a post holds its word. -/
structure Posts where
  /-- The words posted, oldest first. -/
  words : IO.Ref (Array String)
  /-- Each word a check waits for, and the promise resolved once it is
  posted. -/
  waits : IO.Ref (Array (String × IO.Promise Unit))

/-- No post yet. -/
def Posts.new : IO Posts :=
  return { words := ← IO.mkRef #[], waits := ← IO.mkRef #[] }

/-- Records the invocation `invocation`, the job's post, resolving every
wait for its word. -/
def Posts.posted (posts : Posts) (invocation : Invocation) : BaseIO Unit := do
  let [.str word] := invocation.arguments | return
  posts.words.modify (·.push word)
  for (wanted, promise) in ← posts.waits.get do
    if wanted == word then
      promise.resolve ()

/-- Waits for `word` to be posted, on the post itself, the kit's patience a
hang guard: at once when it was posted already. -/
def Posts.reach (posts : Posts) (word : String) : IO Unit := do
  let promise ← IO.Promise.new
  posts.waits.modify (·.push (word, promise))
  if (← posts.words.get).contains word then
    promise.resolve ()
  discard <| Editor.Test.Linked.hangGuarded s!"the session job's post {word}" promise.result?

/-- The session number the session job posted. -/
def Posts.session (posts : Posts) : IO Nat := do
  for word in ← posts.words.get do
    if let some number := (word.dropPrefix? "opened ").bind (·.toString.toNat?) then
      return number
  throw (IO.userError "the session job posted no session")

/-- The runner over `services`, the linked kit's real services, given the
package services `packages`, the edge's for acp's packages. -/
def runner (services : Editor.Test.Linked.Services) (packages : Job.PackageServices)
    (recorder : Job.FakeRecorder) : Job.Services :=
  { services.jobs with
    packages, recorder := recorder.recorder }

/-- How the job behind `handle` ended, waited for on its outcome, the kit's
patience a hang guard; its value read back. -/
def endedOf (handle : Job.Handle) : IO (Job.Outcome Bool) := do
  discard <| Editor.Test.Linked.hangGuarded "the job's end" handle.finishedRan.result?
  match (← handle.outcome?).map texts with
  | some (.finished values) =>
    return .finished (values == #["true"])
  | some (.failed message) =>
    return .failed message
  | _ =>
    return .cancelled

/-- Whether `reply` is the order `Sent`, for the send jobs. -/
def isSent (reply : Except AgentsApi.Refusal AgentsApi.Sent) : Bool :=
  reply.toOption.isSome

/-- Runs a job of `runner` that sends the session `session` `order`, and
gives whether it was sent. -/
def sent (runner : Job.Services) (session : Nat) (order : AgentsApi.Order) :
    IO (Job.Outcome Bool) := do
  endedOf
      (←
        Job.spawn runner
            (reporting fun _ => do
              return isSent (← AgentsApi.Job.send session order))
            (pure ()))

/-- The protocol model's trace of what the check observed and ordered, from
the session job's posts: the prompt, sent as the session opened; each
permission request asked, ticket 1 answered and the turn cancelled once
ticket 2 was asked, as the check drove them; a withdrawal of a ticket never
asked, asked and answered at once; the turn's end; and the close. -/
def observedTrace (words : Array String) : List AgentsApiTest.Protocol.Action :=
  let step (asked : List Nat) (word : String) : List Nat × List AgentsApiTest.Protocol.Action :=
    match word.splitOn " " with
    | ["opened", _] => (asked, [.send 1 (some 1)])
    | ["permission", ticket] =>
      let ticket := ticket.toNat!
      let ordered : List AgentsApiTest.Protocol.Action :=
        if ticket == 1 then [.answer 1] else if ticket == 2 then [.cancel] else []
      (ticket :: asked, .ask ticket :: ordered)
    | ["withdrawn", ticket] =>
      let ticket := ticket.toNat!
      if asked.contains ticket then (asked, []) else (ticket :: asked, [.ask ticket])
    | ["turnEnded", turn, _] => (asked, [.respond turn.toNat!])
    | "ended" :: _ => (asked, [.close])
    | _ => (asked, [])
  (words.foldl
      (fun (asked, trace) word =>
        let (asked, more) := step asked word
        (asked, trace ++ more))
      ([], [])).2

/-- The events of the canonical scenario, in the session job's words. -/
def canonicalWords (session : Nat) : Array String :=
  #[s!"opened {session}", "chunk", "toolCall call-edit-1 pending", "permission 1",
    "toolCall call-edit-1 completed", "permission 2", "withdrawn 2", "turnEnded 1 cancelled",
    "ended exited 0"]

/-- The checks of the crate on a real child, over `services`, whose pump is
running, and the package services `packages`: the edge's for acp's
packages (`Editor.Headless.packageServices`), which the linked test's root
hands in. -/
def sessionChecks (services : Editor.Test.Linked.Services) (packages : Job.PackageServices) :
    List Check :=
  [{  name :=
        "AC4: the real crate on a scripted agent, through the process service: start, prompt, answer a permission while the prompt is pending, cancel"
      run :=
        Editor.Test.Linked.withFiles services.jobs (targets := [.processes]) fun directory => do
          let recorder ← Job.FakeRecorder.new
          let runner := runner services packages recorder
          let posts ← Posts.new
          let session ←
            Job.spawn runner (reporting fun _ => sessionWork directory.toString) (pure ())
                (posted := posts.posted)
          posts.reach "permission 1"
          let number ← posts.session
          -- The prompt is still pending: its turn has not ended.
          let pending := !(← posts.words.get).any (·.startsWith "turnEnded")
          let answered ← sent runner number (.answer 1 AgentsApiTest.Contract.allow)
          posts.reach "permission 2"
          let cancelSent ← sent runner number .cancel
          let ended ← endedOf session
          let late ← sent runner number (.answer 2 AgentsApiTest.Contract.allow)
          -- Each flush is waited for on its own end, the kit's patience a
          -- hang guard: the crate and the process service have finished
          -- what was handed to them.
          let crate ←
            Job.awaitWithin Editor.Test.Linked.patience
                (← runner.flushed (.package AgentsApi.serviceName))
          let processes ← Job.awaitWithin Editor.Test.Linked.patience (← runner.flushed .processes)
          let words ← posts.words.get
          let replays := (AgentsApiTest.Protocol.replay (observedTrace words)).toOption.isSome
          let jobs ← recorder.trace
          let jobsReplay :=
            match Job.Protocol.replay jobs with
            | .ok state => state.violation?.isNone && jobs.any (· matches .ask _ _ .service)
            | .error _ => false
          saw
              (pending && answered == .finished true && cancelSent == .finished true &&
                ended == .finished true &&
                late == .finished false &&
                words == canonicalWords number &&
                replays &&
                jobsReplay &&
                crate == some .completed &&
                processes == some .completed)
              s!"pending {pending}, answered {repr answered}, cancelled {repr cancelSent}, ended {repr ended}, late {repr late}, posts {words}, the runner's trace replays {jobsReplay}, the flushes {repr crate} and {repr processes}" }]

end AcpTest.Linked
