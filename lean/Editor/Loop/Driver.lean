import Editor.Command.Model
import Editor.Job.Model
import Editor.Loop

/-!
# The loop's driver on the models

A host of the command loop (`Editor/Loop.lean`) with no thread, no queue and
no library: the loop run on the editor's models (`EditorModel`), with the
jobs its commands start run on the job model (`JobModel`). It is published
for tests of what crosses the loop and the job port: a command that starts
a job, and the job's result coming back as a command.

A `Loop.Driver` is a value: the loop, the models, the jobs that are
registered, and the jobs that were started and not yet delivered. Two
operations take it on:

- **`feed`** takes one event off an imagined queue, as a host does
  (`Loop.take`), and runs each job the step hands back
  (`Loop.Stepped.starts`): the job registered under the start's name,
  applied to its arguments, on the job model. What it ended with is kept,
  under the next id, as started and not delivered.
- **`finish id`** is the job's wake-up arriving: the job leaves the ones
  not delivered, and for a job that finished the loop is handed the command
  it finished with (`Loop.deliver`), labelled `job <id> <name>` as the
  headless host labels one. A job that failed or was cancelled has no
  command, and nothing is delivered. The jobs a delivered command starts
  are run as a fed step's are.

## The rules

- **The test says when a job ends.** A real job ends when its waits are
  over, and its wake-up is queued behind whatever arrived before it. Here
  the job's outcome is computed when it starts, since the job model needs
  no time to pass, and it reaches the loop only at `finish`. So a test
  feeds events between a start and its `finish`, and what it sees is what
  the queue's order guarantees a host: each of them handled before the
  result's command.
- **One job model for every job**, whose clock each job's waits move on.
- **A step that is refused changes the models and not the loop.** No
  program of the loop is refused today (`Editor/Loop.lean`, "When
  publishing is refused"); one that is hands back the refusal.
- **What a job loaded is not handed to its command.** The snapshots a job
  holds when it ends are for the phase that loads files to hand over; a
  delivered command here is handed nothing.

Pinned by `ModelTest.driverChecks`.
-/

namespace Editor

/-- A job the driver started that has not been delivered. -/
structure Loop.Driver.Pending where
  /-- The job's id: its number among the jobs this driver started, from
  1. -/
  id : Nat
  /-- The name it was started under. -/
  name : String
  /-- How it ended on the job model, with the command it finished with. -/
  outcome : Job.Outcome (EditorM Unit)

/-- The command loop on the editor's models, with the jobs its commands
start run on the job model, for a loop that runs the input scheme
`scheme`. -/
structure Loop.Driver (scheme : InputScheme) where
  /-- The loop. -/
  loop : Loop scheme
  /-- The editor's models, which the loop's programs run against. -/
  model : EditorModel
  /-- The job model, which every job runs against. -/
  jobs : JobModel := {}
  /-- What a step is handed, but for the registered jobs' names, which are
  `registered`'s. -/
  keys : Loop.Keys scheme := {}
  /-- The registered jobs, by name: given the arguments it is started with,
  the job. `none` for a name no job is registered under. -/
  registered : String → Option (List Argument → Work) := fun _ => none
  /-- The jobs started and not delivered, oldest first. -/
  pending : Array Loop.Driver.Pending := #[]
  /-- The id the next job started gets. -/
  next : Nat := 1

namespace Loop.Driver

variable {scheme : InputScheme}

/-- A driver over the state `start` makes on `model`, with `keys` and the
registered jobs `registered`. Refused when making the state is. -/
def over (keys : Loop.Keys scheme) (registered : String → Option (List Argument → Work))
    (start : TextM EditorState) (model : EditorModel) : Except TextError (Loop.Driver scheme) :=
  match (TextM.lift start).runModel model with
  | (.ok state, model) => .ok { loop := { state }, model, keys, registered }
  | (.error refusal, _) => .error refusal

/-- What a step of the driver's loop is handed: its `keys`, told which names
a job is registered under. -/
def handed (driver : Loop.Driver scheme) : Loop.Keys scheme :=
  { driver.keys with
    registered :=
      { driver.keys.registered with jobs := fun name => (driver.registered name).isSome } }

/-- The driver once each of `starts` is started: the job registered under
its name, applied to its arguments, is run on the job model, and what it
ended with is kept as not delivered, under the next id. A start whose name
no job is registered under is passed over: the loop refused it when the
command asked. -/
def started (driver : Loop.Driver scheme) (starts : Array JobStart) : Loop.Driver scheme :=
  starts.foldl
    (fun driver start =>
      match driver.registered start.name with
      | none => driver
      | some work =>
        let (outcome, jobs) := (work start.arguments ()).runModel driver.jobs
        { driver with
          jobs
          pending := driver.pending.push { id := driver.next, name := start.name, outcome }
          next := driver.next + 1 })
    driver

/-- Runs `step`, a program of the loop that hands back a step, on the
models: the driver with the loop the step left and the jobs it asked for
started, and the step, or the refusal of a program that was refused, with
the loop as it was. -/
def stepped (driver : Loop.Driver scheme) (step : EditorM (Loop.Stepped scheme)) :
    Loop.Driver scheme × Except TextError (Loop.Stepped scheme) :=
  match step.runModel driver.model with
  | (.ok stepped, model) =>
    (({ driver with
            loop := stepped.loop, model }).started
        stepped.starts,
      .ok stepped)
  | (.error refusal, model) => ({ driver with model }, .error refusal)

/-- Takes `received` off the queue, as a host does (`Loop.take`), and starts
each job the step asked for. -/
def feed (driver : Loop.Driver scheme) (received : Received) :
    Loop.Driver scheme × Except TextError (Loop.Stepped scheme) :=
  driver.stepped (driver.loop.take driver.handed received)

/-- The job `id` is finished: it leaves the jobs not delivered, and the loop
is handed the command it finished with (`Loop.deliver`), labelled
`job <id> <name>`. The step the delivery handed back; `none`, with nothing
delivered, for an id that names no job started and not delivered, for a job
that failed or was cancelled, and for a delivery that was refused. -/
def finish (driver : Loop.Driver scheme) (id : Nat) :
    Loop.Driver scheme × Option (Loop.Stepped scheme) :=
  match driver.pending.find? (·.id == id) with
  | none => (driver, none)
  | some job =>
    let driver := { driver with pending := driver.pending.filter (·.id != id) }
    match job.outcome with
    | .finished command =>
      let (driver, stepped) :=
        driver.stepped (driver.loop.deliver driver.handed s!"job {job.id} {job.name}" command)
      (driver, stepped.toOption)
    | .failed _ | .cancelled => (driver, none)

end Loop.Driver

end Editor
