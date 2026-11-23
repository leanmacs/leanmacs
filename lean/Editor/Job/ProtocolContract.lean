import Editor.Job.Fake
import Editor.Job.Protocol
import Editor.Job.Runner

/-!
# The contract of the runner's protocol

What the job runner's recorded transitions must be (`Editor/Job/Runner.lean`,
"The protocol"): runs of the protocol model (`Editor/Job/Protocol.lean`), in
the order they took effect. It has two parts:

- **The recorded runs** (`recordedRuns`): scenarios over a `ProtocolRig`, a
  runner's services over the fake clock and the fake files with the fake
  recorder in place (`FakeRecorder`). Each spawns jobs, waits on the
  recorder's own events (`FakeRecorder.reached`) and on the jobs'
  `finishedRan`, then requires the trace to replay (`Protocol.replay`). The
  order of the records is checked two ways: a cancel at a job's `ask`, held
  there, shows in the trace before the `park` that withdraws the wait, and a
  thread held inside a section, at its record, holds the table's lock, so
  no other section can apply or record until it is let go.
- **The park** (`ParkSubject`, `parkHolds`): a subject holds a job just after
  the step at which its unit was given back, cancels it there, and reports
  what the cancel withdrew. Wherever the unit has been given back, the
  job's wait must be one the cancel withdraws.

`model-test` runs both on the fakes and the park on the model and on the
model of the protocol before the runner-park fix, where it fails
(`ModelTest.protocolContractChecks`); `config-test` runs a recorded run and
the park on a stepped host (`ConfigTest.protocolContractChecks`); and
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
  /-- A file the services' file port loads. -/
  loadable : System.FilePath

/-- A rig over the fake clock and the fake files, with the file
`/protocol/a.txt` in them. -/
def ProtocolRig.fakes : BaseIO ProtocolRig := do
  let completions ← Completions.new
  let clock ← FakeClock.new completions
  let files ← FakeFiles.new completions (({} : FileModel).withFile "/protocol/a.txt" "a".toUTF8)
  let recorder ← FakeRecorder.new
  return {
      services :=
        { completions, timers := clock.timers, files := files.files, recorder := recorder.recorder
          activity := ← Activity.counting }
      recorder, clock, loadable := "/protocol/a.txt" }

/-- A job that sleeps `duration` on the services' clock. -/
def sleeper (duration : Nat) : Work :=
  Work.of (fun _ => sleep duration) fun _ => pure ()

/-- A job that loads `path`. -/
def loader (path : System.FilePath) : Work :=
  Work.of (fun _ => File.load path 100) fun _ => pure ()

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
  [sleepWoken, sleepCancelled, sleepDue, cancelAtAsk, fileLoad, severalJobs, recordedInside]

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

end Editor.ProtocolContract
