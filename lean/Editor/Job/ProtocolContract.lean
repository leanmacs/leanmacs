import Editor.Job.Fake
import Editor.Job.Protocol
import Editor.Job.Runner

/-!
# The contract of the runner's protocol

What the job runner's recorded transitions must be (`Editor/Job/Runner.lean`,
"The protocol"): runs of the protocol model (`Editor/Job/Protocol.lean`), in
the order they took effect. It has two parts:

- **The recorded runs** (`recordedRuns`): scenarios over a `ProtocolRig`, a
  runner's services over the fake clock, the fake files and the fake
  processes with the fake recorder in place (`FakeRecorder`). Each spawns jobs, waits on the
  recorder's own events (`FakeRecorder.reached`) and on the jobs'
  `finishedRan`, then requires the trace to replay (`Protocol.replay`). A
  job asks a second wait once it has resumed from its first
  (`sleepThenLoad`), and the loop's end is refused, recording nothing,
  while a cancelled job is not done (`loopEndAfterCancelled`). The order of
  the records is checked two ways: a cancel at a job's `ask`, held there,
  shows in the trace before the `park` or the `serve` that withdraws the
  wait, and a thread held inside a section, at its record, holds the
  table's lock, so no other section can apply or record until it is let
  go. A job held between the wake of a wait its service completed inside its
  start and its `serve`, and cancelled there, drops the wait at the service
  itself, so the service keeps nothing of it: a load's reply
  (`loadCancelAfterWake`) and a streaming start's child
  (`startCancelAfterWake`).
- **The park** (`ParkSubject`, `parkHolds`): a subject holds a job just after
  the step at which its unit was given back (`ParkHold`), cancels it there,
  and reports what the cancel withdrew. Wherever the unit has been given
  back, the job's wait must be one the cancel withdraws.

`model-test` runs both on the fakes and the park on the model and on the
model of the protocol before the runner-park fix, where it fails
(`ModelTest.protocolContractChecks`); `config-test` runs a recorded run and
the park on a stepped host, and the same park check on that host with its
park put in the pre-fix order around the real runner, from the count and
the recorder, where it fails (`ConfigTest.protocolContractChecks`); and
`contract-test` runs a recorded run over the library's real services on
real threads (`ContractTest.protocolContractChecks`).

**A bound here is a hang guard, never a result**: each wait is on an event,
the recorder's or a job's, and `patience` only bounds a hang.

This module imports only the runner, its fakes and the model. The lists are
plain data, so they are constants: nothing in them runs when the module is
initialised.
-/

namespace Editor.ProtocolContract

open Editor.Job

/-- The guard of a runner's step a check waits for, which must come; only a
hang reaches it, and the check then fails as a hang. -/
def patience : HangGuard :=
  .on "the runner's step the check waits for" 120000

/-- `task`'s value, waited for on the task itself, an event that must come:
`what` names it. Past `patience` this throws the hang (`Job.awaitOrHang`). -/
def awaitStep {α : Type} (what : String) (task : Task α) : IO α :=
  Job.awaitOrHang (.on what patience.ms) task

/-- A fresh runner for one scenario: its services, over a table of their
own, with the fake recorder's port in place, and the fakes a scenario moves
or loads through. -/
structure ProtocolRig where
  /-- The services, the recorder's port among them. -/
  services : Services
  /-- The recorder the services record to. -/
  recorder : FakeRecorder
  /-- The fake clock the services' timers are. -/
  clock : FakeClock
  /-- The fake file service the services' files are. -/
  files : FakeFiles
  /-- The fake process service the services' processes are. -/
  processes : FakeProcesses
  /-- A file the services' file port loads. -/
  loadable : System.FilePath
  /-- A command the services' process port starts as a streaming child. -/
  startable : Process.Command

/-- The command `/protocol/stream`, which the rig's process model starts as
a streaming child. -/
def streamCommand : Process.Command :=
  { program := "/protocol/stream", directory := "/protocol" }

/-- A rig over the fake clock, the fake files, with the file
`/protocol/a.txt` in them, and the fake processes, with the streaming
command `streamCommand` scripted. Each fake completes a request inside its
start unless a scenario holds it. -/
def ProtocolRig.fakes : BaseIO ProtocolRig := do
  let completions ← Completions.new
  let clock ← FakeClock.new completions
  let files ← FakeFiles.new completions (({} : FileModel).withFile "/protocol/a.txt" "a".toUTF8)
  let processes ← FakeProcesses.new completions { streams := #[{ command := streamCommand }] }
  let recorder ← FakeRecorder.new
  return {
      services :=
        { completions, timers := clock.timers, files := files.files
          processes := processes.processes, recorder := recorder.recorder
          activity := ← Activity.counting }
      recorder, clock, files, processes, loadable := "/protocol/a.txt"
      startable := streamCommand }

/-- A job that sleeps `duration` on the services' clock. -/
def sleeper (duration : Nat) : Work :=
  Work.of (fun _ => sleep duration) fun _ => pure ()

/-- A job that loads `path`. -/
def loader (path : System.FilePath) : Work :=
  Work.of (fun _ => File.load path 100) fun _ => pure ()

/-- A job that sleeps `duration` on the services' clock, then loads `path`:
a second wait, asked once the first has ended and the job has resumed. -/
def sleepThenLoader (duration : Nat) (path : System.FilePath) : Work :=
  Work.of
    (fun _ => do
      sleep duration
      File.load path 100)
    fun _ => pure ()

/-- A job that starts `command` as a streaming child. -/
def starter (command : Process.Command) : Work :=
  Work.of (fun _ => Process.start command { bound := 64 }) fun _ => pure ()

/-- A job that asks for nothing. -/
def idler : Work :=
  Work.of (fun _ => pure ()) fun _ => pure ()

/-- Spawns `work` on `rig`. -/
def ProtocolRig.spawn (rig : ProtocolRig) (work : Work) : BaseIO Handle :=
  Job.spawn rig.services work (pure ())

/-- Waits for the runner to be done with each of `handles`, on its
`finishedRan`, an event. -/
def finishedAll (handles : Array Handle) : IO Unit := do
  for handle in handles do
    discard <| awaitStep "the runner's last step for a job" handle.finishedRan.result?

/-- Whether `trace` replays, or the refusal, thrown, as a failure. -/
def replays (trace : Array Protocol.Transition) : IO Bool := do
  match Protocol.replay trace with
  | .ok _ =>
    return true
  | .error refusal =>
    throw <| IO.userError s!"{refusal.text}; the trace was {repr trace}"

/-- What `trace` replays to, or the refusal, thrown, as a failure. -/
def replayed (trace : Array Protocol.Transition) : IO Protocol.State := do
  match Protocol.replay trace with
  | .ok state =>
    return state
  | .error refusal =>
    throw <| IO.userError s!"{refusal.text}; the trace was {repr trace}"

/-- Fails with `said` unless `holds`. -/
def saw (holds : Bool) (said : String) : IO Bool := do
  unless holds do
    throw (IO.userError said)
  return true

/-- One recorded run: whether it holds on a fresh rig, or why not, thrown. -/
structure RecordedProperty where
  /-- What must hold, as a sentence. -/
  name : String
  /-- Observes it on a fresh rig. -/
  holds : ProtocolRig → IO Bool

/-- A sleep the check wakes by moving the clock. -/
def sleepWoken : RecordedProperty where
  name :=
    "a sleep the check wakes is recorded in the order it took effect, and is a run of the protocol"
  holds rig := do
    let handle ← rig.spawn (sleeper 10)
    discard <| awaitStep "the job's park" (← rig.recorder.reached (· matches .park _))
    rig.clock.advance 10
    finishedAll #[handle]
    let trace ← rig.recorder.trace
    discard <| replays trace
    saw (trace == #[.start 0, .ask 0 1 .parks, .park 0, .wake 1 .completed, .resume 0, .done 0])
        s!"trace={repr trace}"

/-- A sleep cancelled while the job is parked in it. -/
def sleepCancelled : RecordedProperty where
  name :=
    "a sleep cancelled while its job is parked is withdrawn by the cancel, and the trace is a run of the protocol"
  holds rig := do
    let handle ← rig.spawn (sleeper 10)
    discard <| awaitStep "the job's park" (← rig.recorder.reached (· matches .park _))
    handle.cancel
    finishedAll #[handle]
    let trace ← rig.recorder.trace
    discard <| replays trace
    saw
        (trace ==
          #[.start 0, .ask 0 1 .parks, .park 0, .cancel 0, .wake 1 .cancelled, .resume 0, .done 0])
        s!"trace={repr trace}"

/-- A sleep already due, which the clock ends inside its start. -/
def sleepDue : RecordedProperty where
  name :=
    "a sleep already due ends before its job records it: the job is woken at its park, keeping its unit, and the trace is a run of the protocol"
  holds rig := do
    let handle ← rig.spawn (sleeper 0)
    finishedAll #[handle]
    let trace ← rig.recorder.trace
    let state ← replayed trace
    saw
        (trace == #[.start 0, .ask 0 1 .parks, .wake 1 .completed, .park 0, .resume 0, .done 0] &&
          state.count == 0)
        s!"trace={repr trace}"

/-- A cancel made while the job is held just after its `ask`, before the
clock has the wait. -/
def cancelAtAsk : RecordedProperty where
  name :=
    "a cancel at a job's ask is recorded before the job's park, which withdraws the wait itself: the recorded order is the order of effect"
  holds rig := do
    let (asked, letGo) ← rig.recorder.holdAt (· matches .ask ..)
    let handle ← rig.spawn (sleeper 1000)
    try
      discard <| awaitStep "the job's ask" asked
      handle.cancel
      letGo
      finishedAll #[handle]
      let trace ← rig.recorder.trace
      discard <| replays trace
      let withdrawn ← rig.clock.withdrawn
      -- The cancel found nothing recorded; the job's park took the wait out
      -- of the table and told the clock, which had it by then.
      saw
          (trace == #[.start 0, .ask 0 1 .parks, .cancel 0, .park 0, .resume 0, .done 0] &&
            withdrawn == #[1])
          s!"trace={repr trace} withdrawn={withdrawn}"
    finally
      letGo
      handle.cancel

/-- A sleep, then a load the check holds, asked once the job has resumed. -/
def sleepThenLoad : RecordedProperty where
  name :=
    "a job that sleeps and then loads asks its second wait after it resumes from the first, and the trace is a run of the protocol"
  holds rig := do
    rig.files.holdCompletions
    let handle ← rig.spawn (sleepThenLoader 10 rig.loadable)
    try
      discard <| awaitStep "the job's park" (← rig.recorder.reached (· matches .park _))
      rig.clock.advance 10
      discard <| awaitStep "the job's serve" (← rig.recorder.reached (· matches .serve _))
      rig.files.letGo
      finishedAll #[handle]
      let trace ← rig.recorder.trace
      let state ← replayed trace
      saw
          (trace ==
              #[.start 0, .ask 0 1 .parks, .park 0, .wake 1 .completed, .resume 0,
                .ask 0 2 .service, .serve 0, .wake 2 .completed, .resume 0, .done 0] &&
            state.count == 0)
          s!"trace={repr trace}"
    finally
      rig.files.letGo
      handle.cancel

/-- A cancel made while the job is held just after its `ask` of a service
wait, a load the fake file service holds. -/
def serviceCancelAtAsk : RecordedProperty where
  name :=
    "a cancel at a job's ask of a service wait is recorded before the job's serve, which withdraws the wait itself, and the trace is a run of the protocol"
  holds rig := do
    rig.files.holdCompletions
    let (asked, letGo) ← rig.recorder.holdAt (· matches .ask _ _ .service)
    let handle ← rig.spawn (loader rig.loadable)
    try
      discard <| awaitStep "the job's ask" asked
      handle.cancel
      letGo
      finishedAll #[handle]
      let trace ← rig.recorder.trace
      let state ← replayed trace
      let withdrawn ← rig.files.withdrawn
      -- The cancel found nothing recorded; the job's serve took the wait out
      -- of the table and told the file service, which held it by then.
      saw
          (trace == #[.start 0, .ask 0 1 .service, .cancel 0, .serve 0, .resume 0, .done 0] &&
            withdrawn == #[1] &&
            state.count == 0)
          s!"trace={repr trace} withdrawn={withdrawn}"
    finally
      letGo
      rig.files.letGo
      handle.cancel

/-- A wait its service completes inside its start, before the job records
it: the job `work` is held just after that wake, on its own thread, before
its `serve`, and cancelled there. The cancel finds nothing recorded, so the
job's `serve` must drop the wait at its services itself, though it has
ended: a service keeps a completed request's reply until it is taken or
dropped, and a cancelled job never takes it. `kept` reads the service once
the runner is done with the job: the waits it withdrew, which must be the
job's one, and how much it still keeps of them, which must be nothing. -/
def cancelAfterWake (rig : ProtocolRig) (work : Work) (kept : BaseIO (Array UInt64 × Nat)) :
    IO Bool := do
  let (woken, letGo) ← rig.recorder.holdAt (· matches .wake _ .completed)
  let handle ← rig.spawn work
  try
    discard <| awaitStep "the wait's wake inside its start" woken
    handle.cancel
    letGo
    finishedAll #[handle]
    let trace ← rig.recorder.trace
    let state ← replayed trace
    let (withdrawn, left) ← kept
    let outcome ← handle.outcome?
    saw
        (trace ==
            #[.start 0, .ask 0 1 .service, .wake 1 .completed, .cancel 0, .serve 0, .resume 0,
              .done 0] &&
          withdrawn == #[1] &&
          left == 0 &&
          outcome matches some .cancelled &&
          state.count == 0)
        s!"trace={repr trace} withdrawn={withdrawn} left={left}"
  finally
    letGo
    handle.cancel

/-- A load the fake files complete at once, its job cancelled between the
wake and its `serve`. -/
def loadCancelAfterWake : RecordedProperty where
  name :=
    "a load its service completed before the job recorded it, the job cancelled there, is dropped at the file service by the job's serve, and the trace is a run of the protocol"
  holds rig :=
    cancelAfterWake rig (loader rig.loadable) do
      let files ← rig.files.state.get
      return (files.withdrawn, files.pending.size)

/-- A streaming start the fake processes complete at once, its job
cancelled between the wake and its `serve`: the child it would have
started is never left running. -/
def startCancelAfterWake : RecordedProperty where
  name :=
    "a streaming start its service completed before the job recorded it, the job cancelled there, is dropped at the process service by the job's serve, which kills the child, and the trace is a run of the protocol"
  holds rig :=
    cancelAfterWake rig (starter rig.startable) do
      let model ← rig.processes.model
      return (← rig.processes.withdrawn,
          (← rig.processes.waiting) + model.children.size + (← rig.processes.taken).size)

/-- The loop's end with a job cancelled and not yet done, held at its
resume. -/
def loopEndAfterCancelled : RecordedProperty where
  name :=
    "the loop's end is refused while a cancelled job is not done, and records nothing; once the job is done, which its task among the unsettled says, it is recorded, and the trace is a run of the protocol"
  holds rig := do
    let handle ← rig.spawn (sleeper 10)
    let (resumed, letGo) ← rig.recorder.holdAt (· matches .resume _)
    try
      discard <| awaitStep "the job's park" (← rig.recorder.reached (· matches .park _))
      handle.cancel
      discard <| awaitStep "the job's resume" resumed
      let unsettled ← rig.services.unsettled
      let early ← rig.services.endLoop
      let refused ← rig.recorder.trace
      letGo
      for task in unsettled do
        discard <| awaitStep "the cancelled job's last step" task
      let ended ← rig.services.endLoop
      let settled ← rig.services.unsettled
      let trace ← rig.recorder.trace
      let state ← replayed trace
      saw
          (unsettled.size == 1 && !early && !refused.contains .loopEnd && ended &&
            settled.isEmpty &&
            trace ==
              #[.start 0, .ask 0 1 .parks, .park 0, .cancel 0, .wake 1 .cancelled, .resume 0,
                .done 0, .loopEnd] &&
            state.ended)
          s!"unsettled={unsettled.size} early={early} ended={ended} trace={repr trace}"
    finally
      letGo
      handle.cancel

/-- A load on a file service that ends it by itself. -/
def fileLoad : RecordedProperty where
  name :=
    "a file load keeps the job's unit through its service wait, and the trace is a run of the protocol"
  holds rig := do
    let handle ← rig.spawn (loader rig.loadable)
    finishedAll #[handle]
    let trace ← rig.recorder.trace
    let state ← replayed trace
    saw
        (trace.any (· matches .ask _ _ .service) && trace.back? == some (.done 0) &&
          state.count == 0)
        s!"trace={repr trace}"

/-- Several jobs at once, on pool threads, in whatever order they take. -/
def severalJobs : RecordedProperty where
  name :=
    "several jobs at once, sleeping, loading and cancelled, record a trace that is a run of the protocol, whatever order their threads take"
  holds rig := do
    let short ← rig.spawn (sleeper 10)
    let long ← rig.spawn (sleeper 20)
    let load ← rig.spawn (loader rig.loadable)
    let cancelled ← rig.spawn (sleeper 30)
    let quick ← rig.spawn idler
    for job in [0, 1, 3] do
      discard <| awaitStep s!"job {job}'s park" (← rig.recorder.reached (· == .park job))
    cancelled.cancel
    rig.clock.advance 10
    rig.clock.advance 10
    finishedAll #[short, long, load, cancelled, quick]
    let trace ← rig.recorder.trace
    let state ← replayed trace
    saw (state.count == 0 && state.jobs.length == 5) s!"trace={repr trace}"

/-- A transition held at its record, inside its section. -/
def recordedInside : RecordedProperty where
  name :=
    "a transition is recorded inside the section that applies it: while its record is held, the table's lock is held, no other section applies or records until it is let go, and the lock is free after"
  holds rig := do
    -- Job 0 parks; job 1, which asks for nothing, is held at the record of
    -- its done, inside that section, on its pool thread.
    let parked ← rig.spawn (sleeper 10)
    discard <| awaitStep "job 0's park" (← rig.recorder.reached (· matches .park _))
    let (inside, letGo) ← rig.recorder.holdRecordAt (· matches .done _)
    let held ← rig.spawn idler
    let mut competing : Option (Task (Except IO.Error Unit)) := none
    try
      discard <| awaitStep "job 1's record of its done" inside
      -- Read without waiting: the section's lock is held, as it is only if
      -- the record is inside the section.
      let busy ← rig.services.completions.busy
      -- A competing section, job 0's cancel, on a thread of its own: it can
      -- neither apply nor record until the hold is let go.
      competing := some (← IO.asTask (prio := .dedicated) parked.cancel)
      letGo
      if let some task := competing then
        discard <| awaitStep "the competing cancel" task
      finishedAll #[parked, held]
      let free ← rig.services.completions.busy
      let trace ← rig.recorder.trace
      discard <| replays trace
      let doneAt := trace.findIdx? (· == .done 1)
      let cancelAt := trace.findIdx? (· == .cancel 0)
      saw (busy && !free && doneAt.isSome && cancelAt.isSome && doneAt.getD 0 < cancelAt.getD 0)
          s!"busy while held={busy} busy after={free} trace={repr trace}"
    finally
      letGo
      parked.cancel

/-- Every recorded run, in the order they run. -/
def recordedRuns : List RecordedProperty :=
  [sleepWoken, sleepCancelled, sleepDue, cancelAtAsk, sleepThenLoad, serviceCancelAtAsk,
    loadCancelAfterWake, startCancelAfterWake, fileLoad, severalJobs, recordedInside,
    loopEndAfterCancelled]

/-- Runs every recorded run, each on a fresh rig `fresh` makes, and returns
the failures, each named `<name>: <property>`, with what it saw. -/
def recordedFailures (name : String) (fresh : IO ProtocolRig) : IO (List String) := do
  let mut failed := []
  for property in recordedRuns do
    let label := s!"{name}: {property.name}"
    try
      unless ← property.holds (← fresh) do
        failed := failed ++ [label]
    catch error =>
      failed := failed ++ [s!"{label} ({error})"]
  return failed

/-! ## The park -/

/-- What a park subject saw: the wait its job asked, whether the job's unit
had been given back where the subject held it, and the waits the cancel made
there withdrew before it returned. -/
structure ParkObserved where
  /-- The wait the job asked, if it asked one. -/
  asked : Option Nat
  /-- Whether the job's unit had been given back at the hold. -/
  unitBack : Bool
  /-- The waits the cancel withdrew before it returned. -/
  withdrawn : Array Nat
  deriving Repr

/-- The park property: wherever the job's unit has been given back, its wait
is one a cancel withdraws. A subject whose hold never came, its unit never
given back, has hung, and says so. -/
def parkHolds (observed : ParkObserved) : Bool :=
  observed.unitBack && observed.asked.any (observed.withdrawn.contains ·)

/-- A subject of the park property. Its `run` starts one job that sleeps on
a clock only the check moves, holds it just after the step at which its
unit was given back, cancels it there as a loop's end does, and reports
what it saw (`ParkObserved`). -/
structure ParkSubject where
  /-- Which subject, as a failure names it. -/
  name : String
  /-- Runs the job to the hold, cancels it there, and reports. -/
  run : IO ParkObserved

/-- A count and a recorder that hold a job just after it gave its unit back:
the count notes the thread of each `done`, and the recorder holds that
thread at the first transition it is told was applied after it, until the
check lets it go. The `done` is noted, and the hold made, on the job's own
thread, so where it is held is the runner's order alone. -/
structure ParkHold where
  /-- The count, noting each `done`'s thread. -/
  activity : Activity
  /-- The recorder, holding the thread of a `done` at its next transition
  told applied. -/
  recorder : Recorder
  /-- Resolved with the transition held at, once the job has arrived. -/
  arrived : IO.Promise Protocol.Transition
  /-- Resolved to let the job go. -/
  release : IO.Promise Unit
  /-- Whether the held thread had given a unit back when it was held. -/
  unitBack : IO.Ref Bool

/-- A park hold over `activity` and `inner`, which it forwards to. -/
def ParkHold.over (activity : Activity) (inner : Recorder) : BaseIO ParkHold := do
  let gaveBack ← IO.mkRef (none : Option UInt64)
  let arrived ← IO.Promise.new
  let release ← IO.Promise.new
  let unitBack ← IO.mkRef false
  return {
      activity :=
        { activity with
          done := do
            activity.done
            gaveBack.set (some (← IO.getTID)) }
      recorder :=
        { inner with
          applied := fun transition => do
            inner.applied transition
            let gave := (← gaveBack.get) == some (← IO.getTID)
            if gave then
              unless ← arrived.isResolved do
                unitBack.set gave
                arrived.resolve transition
                discard <| IO.wait release.result? }
      arrived, release, unitBack }

/-- The wait the job `job` asked in `trace`, if it asked one. -/
def askedIn (trace : Array Protocol.Transition) (job : Nat) : Option Nat :=
  trace.findSome? fun
    | .ask asker wait _ => if asker == job then some wait else none
    | _ => none

/-- The park subject of the runner over a fresh rig `fresh` makes: the job
sleeps on its fake clock, the cancel is made on the check's thread at the
hold, and what the clock had withdrawn as the cancel returned is what it
withdrew. -/
def ParkSubject.ofRig (name : String) (fresh : IO ProtocolRig) : ParkSubject where
  name := name
  run := do
    let rig ← fresh
    let hold ← ParkHold.over rig.services.activity rig.services.recorder
    let services :=
      { rig.services with
        activity := hold.activity, recorder := hold.recorder }
    let handle ← Job.spawn services (sleeper 10) (pure ())
    try
      let held ← awaitStep "the job's step after it gave its unit back" hold.arrived.result?
      handle.cancel
      let withdrawn ← rig.clock.withdrawn
      hold.release.resolve ()
      finishedAll #[handle]
      let job := (held.bind (·.job?)).getD 0
      return {
          asked := askedIn (← rig.recorder.trace) job,
          unitBack := held.isSome && (← hold.unitBack.get)
          withdrawn := withdrawn.map (·.toNat) }
    finally
      hold.release.resolve ()
      handle.cancel

end Editor.ProtocolContract
