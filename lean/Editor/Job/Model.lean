import Editor.File.Model
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
- A process request is answered by the model of the processes the job runs
  (`JobModel.processes`, `Editor/Process/Model.lean`), which is part of this
  model. A scripted run moves the clock on by the time it takes, as a wait
  does, so a cancellation that falls inside it ends the run as `cancelled`
  at that instant, and the process model records the command as killed.

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
    (reply,
      { model with
        processes, now })

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
  | .done value, model => (if model.cancelled then none else some value, model)
  | .step request next, model =>
    if model.cancelled then (none, model)
    else
      let (reply, after) := handle request model
      match model.cancelAt with
      | some instant =>
        if instant ≤ after.now then (none, { after with now := instant })
        else run (next reply) after
      | none => run (next reply) after

end JobModel

/-- Runs `job` against the model, from `model`: how it ended, and the model
after its last request. -/
def JobM.runModel {α : Type} (job : JobM α) (model : JobModel) : Job.Outcome α × JobModel :=
  match JobModel.run job.run model with
  | (some (.ok value), model) => (.finished value, model)
  | (some (.error message), model) => (.failed message, model)
  | (none, model) => (.cancelled, model)

end Editor
