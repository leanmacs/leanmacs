import AgentsApiTest.Check
import AgentsApiTest.Fake

/-!
# Model tests: `AgentsApiTest/Fake.lean`

`fakeChecks`: the fake of the service `agents`, at the port the runner
reaches it through, over a table of waits whose completions it finishes at
once: what `open`, `next` and `send` answer, when a `next` completes, a
cancel's withdrawals, a withdrawn `next`, and when it holds nothing; a
fresh fake's independent state, the agent's own sends into a parked
`next`, a cancel that leaves the `cancellable` session open, and the
`permissionRequest` agent's parked request and its answer; a load and a
refused load; and the agent table's script's four prompts. The test
driver's root, `AgentsApiTest/Model.lean`, runs them.
-/

namespace AgentsApiTest

open AgentsApi

/-- A request of the fake's port, started as a fresh wait of `completions`:
the wait's id and promise, and whether it was taken. -/
def started (service : Editor.PackageService) (completions : Editor.Job.Completions)
    (request : Request) : IO (UInt64 × IO.Promise Editor.Job.Completion × Bool) := do
  let (id, wait) ← completions.register
  return (id, wait, ← service.start id request.toPackage)

/-- Starts `request`, and takes its reply if its wait has ended. -/
def answered (service : Editor.PackageService) (completions : Editor.Job.Completions)
    (request : Request) : IO (Option Editor.PackageReply) := do
  let (id, wait, taken) ← started service completions request
  if taken && (← wait.isResolved) then
    return some (← service.take id request.toPackage)
  return none

/-- The events of a `next` of session 1, taken at once. -/
def eventsNow (service : Editor.PackageService) (completions : Editor.Job.Completions) :
    IO (Option (Array Event)) := do
  match ← answered service completions (.next 1) with
  | some (.ok reply) =>
    return (reply.get? Batch).map (·.events)
  | _ =>
    return none

/-- Whether `reply` is a `Sent` for `turn`. -/
def sentFor (reply : Option Editor.PackageReply) (turn : Option Nat) : Bool :=
  match reply with
  | some (.ok reply) => (reply.get? Sent) == some { turn }
  | _ => false

/-- Whether `reply` is a refusal. -/
def refusedReply (reply : Option Editor.PackageReply) : Bool :=
  match reply with
  | some (.error (.refused _)) => true
  | _ => false

/-- A fake of the canonical script with session 1 opened, its port over a
fresh table. -/
def openedFake : IO (Fake × Editor.PackageService × Editor.Job.Completions) := do
  let fake ← Fake.new
  let completions ← Editor.Job.Completions.new
  let service := fake.service completions
  discard <| answered service completions (.open 0 Contract.cwd #[])
  return (fake, service, completions)

/-- The checks of the fake of the service `agents`. -/
def fakeChecks : List Check :=
  [{  name :=
        "a fresh fake is made anew by each make: a pending next of one leaves the other quiescent, and each opens its own session 1"
      run := do
        let fresh := Fake.fresh Fake.canonical
        let completions ← Editor.Job.Completions.new
        let first ← fresh.make completions .atOnce
        let second ← fresh.make completions .atOnce
        let opened (service : Editor.PackageService) : IO (Option Nat) := do
          match ← answered service completions (.open 0 Contract.cwd #[]) with
          | some (.ok reply) =>
            return (reply.get? Opened).map (·.session)
          | _ =>
            return none
        let one ← opened first.service
        let (_, _, taken) ← started first.service completions (.next 1)
        let busy ← first.quiescent
        let idle ← second.quiescent
        let two ← opened second.service
        saw (one == some 1 && taken && !busy && idle && two == some 1)
            s!"first {one}, busy {!busy}, idle {idle}, second {two}" },
    { name :=
        "the agent's own sends complete a parked next with exactly their events, through the model"
      run := do
        let (fake, service, completions) ← openedFake
        let (id, wait, _) ← started service completions (.next 1)
        let pendingFirst := !(← wait.isResolved)
        fake.agentSends 1 [.event (.chunk (some "msg-1") "a"), .event (.chunk (some "msg-1") "b")]
        let woken ← wait.isResolved
        let events ←
          match ← service.take id (Request.next 1).toPackage with
          | .ok reply =>
            pure ((reply.get? Batch).map (·.events))
          | .error _ =>
            pure none
        saw
            (pendingFirst && woken &&
              events == some #[.chunk (some "msg-1") "a", .chunk (some "msg-1") "b"])
            s!"pending first {pendingFirst}, woken {woken}, events {repr events}" },
    { name :=
        "the cancellable agent's cancel withdraws the parked ticket and ends the turn cancelled, and the session stays open with nothing parked"
      run := do
        let fake ← Fake.new Fake.cancellable
        let completions ← Editor.Job.Completions.new
        let service := fake.service completions
        discard <| answered service completions (.open 0 Contract.cwd #[])
        discard <| answered service completions (.send 1 (.prompt Contract.promptText))
        discard <| eventsNow service completions
        discard <| answered service completions (.send 1 .cancel)
        let events ← eventsNow service completions
        let session ← fake.session?
        let again ← answered service completions (.send 1 (.prompt Contract.promptText))
        saw
            (events == some #[.withdrawn 1, .turnEnded 1 "cancelled"] &&
              (session.map (·.ended)) == some false &&
              (session.map (·.protocol.parked)) == some [] &&
              sentFor again (some 2))
            s!"events {repr events}" },
    { name :=
        "the permission-request agent's prompt gives the pending edit and parks ticket 1 for the edit with its raw input and diff, offering the adapter's three options; its answer completes the call and ends the turn"
      run := do
        let fake ← Fake.new Fake.permissionRequest
        let completions ← Editor.Job.Completions.new
        let service := fake.service completions
        discard <| answered service completions (.open 0 Contract.cwd #[])
        discard <| answered service completions (.send 1 (.prompt Contract.promptText))
        let asked ← eventsNow service completions
        let parked := (← fake.session?).map (·.protocol.parked)
        let sent ← answered service completions (.send 1 (.answer 1 "allow-once"))
        let after ← eventsNow service completions
        saw
            (asked ==
                some
                  #[.toolCall Fake.editPending,
                    .permission 1 (some 1) Fake.editAsked Fake.adapterOptions] &&
              parked == some [(1, some 1)] &&
              Fake.editAsked.rawInput ==
                "{\"file_path\":\"/work/example/notes.txt\",\"old_string\":\"beta\",\"new_string\":\"gamma\"}" &&
              Fake.editAsked.content == #[.diff Fake.notesPath (some "beta") "gamma"] &&
              (Fake.adapterOptions.map fun option => (option.id, option.name, option.kind)) ==
                #[("allow-once", "Yes", "allow_once"),
                  ("allow-session", "Yes, for this session", "allow_always"),
                  ("reject", "No", "reject_once")] &&
              sentFor sent none &&
              after == some #[.toolCall Fake.editCompleted, .turnEnded 1 "end_turn"])
            s!"asked {repr asked}, parked {repr parked}, after {repr after}" },
    { name := "open answers a session of the script's session id, mode and modes"
      run := do
        let fake ← Fake.new
        let completions ← Editor.Job.Completions.new
        let reply ← answered (fake.service completions) completions (.open 0 Contract.cwd #[])
        let opened :=
          match reply with
          | some (.ok reply) => reply.get? Opened
          | _ => none
        saw
            (opened ==
              some
                { session := 1, sessionId := Contract.sessionId, mode := some Contract.mode
                  modes := Contract.modes })
            s!"{repr opened}" },
    { name :=
        "a prompt is answered with its turn and queues the canonical events, which a next takes at once; a next with nothing queued stays pending until an order makes some"
      run := do
        let (_, service, completions) ← openedFake
        let (id, wait, taken) ← started service completions (.next 1)
        let pendingFirst := taken && !(← wait.isResolved)
        let sent ← answered service completions (.send 1 (.prompt Contract.promptText))
        let woken ← wait.isResolved
        let events ←
          match ← service.take id (Request.next 1).toPackage with
          | .ok reply =>
            pure ((reply.get? Batch).map (·.events))
          | .error _ =>
            pure none
        saw (pendingFirst && sentFor sent (some 1) && woken && events == some Contract.asked)
            s!"pending first {pendingFirst}, woken {woken}, events {repr events}" },
    { name := "a second next of a session while one is pending is refused at its start"
      run := do
        let (_, service, completions) ← openedFake
        let (_, _, first) ← started service completions (.next 1)
        let (_, _, second) ← started service completions (.next 1)
        saw (first && !second) s!"first {first}, second {second}" },
    { name :=
        "an answer to a parked ticket advances the script, and a second answer to it is refused"
      run := do
        let (_, service, completions) ← openedFake
        discard <| answered service completions (.send 1 (.prompt Contract.promptText))
        discard <| eventsNow service completions
        let first ← answered service completions (.send 1 (.answer 1 Contract.allow))
        let events ← eventsNow service completions
        let second ← answered service completions (.send 1 (.answer 1 Contract.allow))
        saw (sentFor first none && events == some Contract.answered && refusedReply second)
            s!"events {repr events}" },
    { name :=
        "a cancel withdraws the turn's parked tickets, then the turn ends cancelled and the agent exits; a next after the end is refused"
      run := do
        let (_, service, completions) ← openedFake
        discard <| answered service completions (.send 1 (.prompt Contract.promptText))
        discard <| answered service completions (.send 1 (.answer 1 Contract.allow))
        discard <| eventsNow service completions
        let cancel ← answered service completions (.send 1 .cancel)
        let events ← eventsNow service completions
        let after ← answered service completions (.next 1)
        saw (sentFor cancel none && events == some Contract.cancelled && refusedReply after)
            s!"events {repr events}, after {repr (after.map (·.toOption.isSome))}" },
    { name := "a withdrawn next is never completed, and the events go to the next one"
      run := do
        let (_, service, completions) ← openedFake
        let (id, wait, _) ← started service completions (.next 1)
        service.cancel id
        discard <| answered service completions (.send 1 (.prompt Contract.promptText))
        let events ← eventsNow service completions
        saw (!(← wait.isResolved) && events == some Contract.asked) s!"events {repr events}" },
    { name :=
        "the fake is quiescent once nothing is pending, and its log records each request with the model state it arrived in, on the thread that handed it"
      run := do
        let (fake, service, completions) ← openedFake
        let (id, _, _) ← started service completions (.next 1)
        let busy ← fake.quiescent
        service.cancel id
        let idle ← fake.quiescent
        discard <| answered service completions (.send 1 (.prompt Contract.promptText))
        let log ← fake.log
        let thread ← IO.getTID
        let last := log.back?.map fun (request, state, _) => (request, state.outstanding)
        saw
            (!busy && idle && log.all (·.2.2 == thread) &&
              last == some (.send 1 (.prompt Contract.promptText), []))
            s!"busy {!busy}, idle {idle}, log {log.size}" },
    { name :=
        "a load of a session the script holds opens a session answered with that id, whose first next is its history; a load of another is refused, and both are logged"
      run := do
        let fake ← Fake.new Fake.resumable
        let completions ← Editor.Job.Completions.new
        let service := fake.service completions
        let loaded ← answered service completions (.load 0 Contract.cwd #[] "sess-0001")
        let opened :=
          match loaded with
          | some (.ok reply) =>
            (reply.get? Opened).map fun opened => (opened.session, opened.sessionId)
          | _ => none
        let events ← eventsNow service completions
        let other ← answered service completions (.load 0 Contract.cwd #[] "sess-0002")
        let words :=
          match other with
          | some (.error (.refused words)) => words
          | _ => ""
        let log := (← fake.log).map (·.1)
        saw
            (opened == some (1, "sess-0001") && events == some Fake.resumedHistory &&
              words == "the agent has no session sess-0002" &&
              log ==
                #[.load 0 Contract.cwd #[] "sess-0001", .next 1,
                  .load 0 Contract.cwd #[] "sess-0002"])
            s!"opened {opened}, events {repr events}, words {words}, log {repr log}" },
    { name :=
        "the table's script: work leaves a tool call in flight and its turn open, ask parks a request, bg ends its turn with a call in flight, and anything else is the conversation's turn; each session has its own id"
      run := do
        let fake ← Fake.new Fake.table
        let completions ← Editor.Job.Completions.new
        let service := fake.service completions
        let ids ←
          [1, 2, 3, 4].mapM fun _ => do
              match ← answered service completions (.open 0 Contract.cwd #[]) with
              | some (.ok reply) =>
                return (reply.get? Opened).map (·.sessionId)
              | _ =>
                return none
        let take (session : Nat) (text : String) : IO (Option (Array Event)) := do
          discard <| answered service completions (.send session (.prompt text))
          match ← answered service completions (.next session) with
          | some (.ok reply) =>
            return (reply.get? Batch).map (·.events)
          | _ =>
            return none
        let work ← take 1 "work"
        let ask ← take 2 "ask"
        let bg ← take 3 "bg"
        let done ← take 4 "done"
        let answer ← answered service completions (.send 2 (.answer 1 "allow-once"))
        let afterAnswer ←
          match ← answered service completions (.next 2) with
          | some (.ok reply) =>
            pure ((reply.get? Batch).map (·.events))
          | _ =>
            pure none
        saw
            (ids == [some "sess-0001", some "sess-0002", some "sess-0003", some "sess-0004"] &&
              work == some #[.chunk (some "msg-w") "Working.", .toolCall Fake.bashRunning] &&
              ask ==
                some
                  #[.toolCall Fake.editPending,
                    .permission 1 (some 1) Fake.editAsked Fake.adapterOptions] &&
              bg ==
                some
                  #[.chunk (some "msg-1") "Started.", .toolCall Fake.bashRunning,
                    .turnEnded 1 "end_turn"] &&
              (done.map (·.back?)) == some (some (.turnEnded 1 "end_turn")) &&
              (done.map (·.contains (.title "Example title"))) == some true &&
              sentFor answer none &&
              afterAnswer == some #[.toolCall Fake.editCompleted, .turnEnded 1 "end_turn"])
            s!"ids {ids}, work {repr work}, ask {repr ask}, bg {repr bg}, done {repr done}, after {repr afterAnswer}" }]

end AgentsApiTest
