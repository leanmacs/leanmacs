import Editor.File.Model
import Editor.FileWatch.Model
import Editor.Fuzzy.Model
import Editor.Job
import Editor.Process.Model

/-!
# The pure model of the job port

What a job waits on, as a pure structure: a clock, and the instant at which
the job is cancelled, if it is. `JobM.runModel` runs a job against it, with
no task, no thread and no library, so the logic above the job port is tested
by `lake test` alone and a theorem about a job can be stated about its run
here.

- `now` reads the clock. `waitUntil` moves it to its deadline, and leaves it
  where it is if the deadline has passed: a wait is the only thing that moves
  the model's clock, so the clock after a run says which waits the job made.
- A wait that would reach `cancelAt` ends the run as `cancelled` at that
  instant. A job that is already cancelled makes no request, and is
  `cancelled` whatever it would have returned.
- Cancellation is not a reply (`Editor/Job.lean`): the run stops, and the
  job's continuation, its `catch` handlers included, is not applied again.
- A file request is answered by the model of the files the job reaches
  (`JobModel.files`, `Editor/File/Model.lean`), which is part of this
  model. It does not move the clock. A load adds to what the job holds
  there (`FileModel.held`), and a save names its source in the tables
  there, so whoever plays a command, a job and the job's command hands the
  snapshots across as values: the published ones in, and what the job held
  out.
- A diff request is answered by the model of the files (`FileModel.diff`),
  which holds the snapshots it names, with the model of a line diff
  (`Editor/Diff/Model.lean`). It moves no clock and changes nothing.
- A process request is answered by the model of the processes the job runs
  (`JobModel.processes`, `Editor/Process/Model.lean`), which is part of this
  model. A scripted run moves the clock on by the time it takes, as a wait
  does, so a cancellation that falls inside it ends the run as `cancelled`
  at that instant, and the process model records the command as killed.
- A watch request is answered by the model of what the job's watches see
  (`JobModel.fileWatches`, `Editor/FileWatch/Model.lean`). A run of a
  command touches those watches with what the command changes on disk,
  when the run ends; a `next` moves the clock to when its delivery is due.
- **A watch does not outlive its job.** When the run ends, however it ends,
  every watch is recorded as ended and forgotten (`FileWatchModel.endAll`).
- **A streaming child does not outlive its job.** When the run ends, finished,
  failed or cancelled, every streaming child the job started that is still
  running is recorded as killed, and every one is forgotten
  (`ProcessModel.endAll`): the model of the runner's cancelling them.

- An environment request is answered by the environments the host's jobs
  share (`JobModel.environments`, `Editor/Process/Environment.lean`), at
  once, without moving the clock; a message one says for the echo area is
  appended to `JobModel.reported`, as the host would say it.
- A post is answered at once, without moving the clock, and recorded in
  `JobModel.posted`, oldest first: what a host would run on the editor
  thread. `runParking` parks a job at each post, so a driver runs it before
  the job goes on.
- A fuzzy request is answered at once, without moving the clock, with the
  fuzzy model's answer (`Editor/Fuzzy/Model.lean`); while
  `JobModel.fuzzyRefusal` is set, with an error, `fuzzy: ` and the refusal,
  as the runner answers a service that threw. A test sets it, as it sets
  the files.

The model's clock is exact, where a real clock only promises "not before".
So the contract of the port (`Editor/Job/Contract.lean`) holds inequalities
only, and what needs equality is checked against the model alone
(`ModelTest.jobModelChecks`).
-/

namespace Editor

/-- The model of what a job waits on. -/
structure JobModel where
  /-- The clock, in milliseconds. -/
  now : Nat := 0
  /-- The instant at which the job is cancelled; `none` if it never is. -/
  cancelAt : Option Nat := none
  /-- The files the job reaches, and the snapshots its file requests may
  name (`Editor/File/Model.lean`). -/
  files : FileModel := {}
  /-- The processes the job runs (`Editor/Process/Model.lean`). -/
  processes : ProcessModel := {}
  /-- What the job's watches see (`Editor/FileWatch/Model.lean`). -/
  fileWatches : FileWatchModel := {}
  /-- The environments the host's jobs share
  (`Editor/Process/Environment.lean`). -/
  environments : Process.Environments := {}
  /-- What the environments said for the echo area, oldest first. -/
  reported : Array String := #[]
  /-- What the job posted to the editor (`post`), oldest first. -/
  posted : Array Invocation := #[]
  /-- What the matcher is refused with, if it is: every fuzzy request is
  then answered `fuzzy: ` and this, as an error. `none` answers with the
  fuzzy model. -/
  fuzzyRefusal : Option String := none
  deriving DecidableEq

namespace JobModel

/-- The model's answer to each request, and the model after it. -/
def handle : (request : JobRequest) → JobModel → request.Reply × JobModel
  | .now, model => (model.now, model)
  | .waitUntil deadline, model => ((), { model with now := max model.now deadline })
  | .file request, model =>
    let (reply, files) := model.files.handle request
    (reply, { model with files })
  | .process request, model =>
    let (reply, processes, now) := model.processes.handle model.now model.cancelAt request
    -- A run changes the disk as its command does, when it ends.
    let fileWatches :=
      match request with
      | .run command _ | .runWithin command _ _ | .runInput command _ _ _ =>
        model.fileWatches.touch (model.fileWatches.effectsOf command) now
      | _ => model.fileWatches
    (reply,
      { model with
        processes, fileWatches, now })
  | .fileWatch request, model =>
    let (reply, fileWatches, now) := model.fileWatches.handle model.now model.cancelAt request
    (reply,
      { model with
        fileWatches, now })
  | .diff request, model => (model.files.diff request, model)
  | .environment request, model =>
    let (reply, environments, said) := model.environments.handle request
    (reply,
      { model with
        environments, reported := model.reported ++ said.toArray })
  | .post invocation, model => ((), { model with posted := model.posted.push invocation })
  | .fuzzy request, model =>
    match model.fuzzyRefusal with
    | some refusal => (.error s!"fuzzy: {refusal}", model)
    | none => (.ok (FuzzyModel.handle request ()).1, model)

/-- The model once the job has ended: every streaming child it started is
ended (`ProcessModel.endAll`), as the runner cancels them, and every watch
(`FileWatchModel.endAll`), however the job ended. -/
def ended (model : JobModel) : JobModel :=
  { model with
    processes := model.processes.endAll, fileWatches := model.fileWatches.endAll }

/-- Whether the job is cancelled by now. -/
def cancelled (model : JobModel) : Bool :=
  model.cancelAt.any (· ≤ model.now)

/-- Runs `program` against the model, from `model`, until it ends or is
cancelled: its value, or `none` if it was cancelled, and the model after its
last request.

Cancellation is looked for before each request and when each reply arrives,
and never told to the program: the run stops there. A wait that would reach
`cancelAt` leaves the clock at that instant. -/
def run {α : Type} : Program jobPort α → JobModel → Option α × JobModel
  | .done value, model => (if model.cancelled then none else some value, model.ended)
  | .step request next, model =>
    if model.cancelled then (none, model.ended)
    else
      let (reply, after) := handle request model
      match model.cancelAt with
      | some instant =>
        if instant ≤ after.now then (none, { after with now := instant }.ended)
        else run (next reply) after
      | none => run (next reply) after

/-- How a run that may park ended: with its value, or `none` if it was
cancelled, and the model after its last request; or parked, at a `next` of
the watch `watch` that nothing recorded can answer yet, with the model as it
then was and the rest of the program. -/
inductive Ran (α : Type) where
  /-- It ended. -/
  | ended (value : Option α) (model : JobModel)
  /-- It is parked at a `next` of `watch`. -/
  |
  parked (watch : Nat) (model : JobModel)
    (resume : Except FileWatchError (Array FileWatch.Change) → Program jobPort α)
  /-- It is parked at a post of `invocation`, which the model has recorded
  (`posted`): the editor has not run it yet. -/
  | posted (invocation : Invocation) (model : JobModel) (resume : Unit → Program jobPort α)

/-- Runs `program` as `run` does, but parks it at a `next` of a watch that has
nothing recorded, when no cancel is due: what a driver that holds a waiting
job needs (`Loop.Driver.touch`, `Editor/Loop/Driver.lean`). It parks it at
every post too, when no cancel is due, the post recorded: so a driver hands
the editor each post before the job goes on (`Loop.Driver.posted`). Parked,
no watch and no child is ended: the job has not ended. -/
def runParking {α : Type} : Program jobPort α → JobModel → Ran α
  | .done value, model => .ended (if model.cancelled then none else some value) model.ended
  | .step request next, model =>
    if model.cancelled then .ended none model.ended
    else
      let waiting : Option Nat :=
        match request with
        | .fileWatch (.next watch) =>
          match model.fileWatches.watches.find? (·.id == watch.number) with
          | some found =>
            if found.opened.isNone && model.cancelAt.isNone then some found.id else none
          | none => none
        | _ => none
      match request, next, waiting with
      | .fileWatch (.next _), next, some watch => .parked watch model next
      | .post invocation, next, _ =>
        if model.cancelAt.isNone then .posted invocation (handle (.post invocation) model).2 next
        else
          let (reply, after) := handle (.post invocation) model
          runParking (next reply) after
      | request, next, _ =>
        let (reply, after) := handle request model
        match model.cancelAt with
        | some instant =>
          if instant ≤ after.now then .ended none { after with now := instant }.ended
          else runParking (next reply) after
        | none => runParking (next reply) after

end JobModel

/-- Runs `job` against the model, from `model`: how it ended, and the model
after its last request. -/
def JobM.runModel {α : Type} (job : JobM α) (model : JobModel) : Job.Outcome α × JobModel :=
  match JobModel.run job.run model with
  | (some (.ok value), model) => (.finished value, model)
  | (some (.error message), model) => (.failed message, model)
  | (none, model) => (.cancelled, model)

end Editor
