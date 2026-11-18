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
- **`posted id`** is the job's next post arriving: the loop is handed what
  it posted (`runPosted`), labelled `job <id> <name>` as its command is,
  and then the job goes on, so it ends, parks or posts again.
- **A spawn** (`Loop.Stepped.spawns`, a prompt's match) is run as a start
  is, after the step's cancels and starts: the job of its key is cancelled,
  and its work is run on the job model under the next id, kept under its
  label, so `finish` delivers it labelled `job <id> <label>` (`spawned`).

Each step is taken in as a host takes one in (`took`): the jobs it asked
for are started, and each invocation it answered, the continuation of a
prompt its command accepted, is run as a step of its own with
`Loop.invoke` before anything else is fed, and taken in the same way
(`Editor/Loop.lean`, "Prompts"). So an event fed after the accept key is
handled after the answer's command.

## The rules

- **The test says when a job ends.** A real job ends when its waits are
  over, and its wake-up is queued behind whatever arrived before it. Here
  the job's outcome is computed when it starts, since the job model needs
  no time to pass, and it reaches the loop only at `finish`. So a test
  feeds events between a start and its `finish`, and what it sees is what
  the queue's order guarantees a host: each of them handled before the
  result's command.
- **A job that posts is held at each post until the test says it
  arrives** (`posted`), as a job is held at its end until `finish`: a
  real job's post is queued behind whatever arrived before it, so a test
  feeds events between two posts. A job's posts arrive in the order it
  made them, and all before its command: it makes no request after a post
  until the post has arrived.
- **A held job keeps its own streaming children**, out of the shared
  process model, as it keeps its own watches: so another job's end, which
  ends every child in the model (`JobModel.ended`), leaves them running. A
  cancel of a held job's key records each of its children still running
  as killed, as the runner's cancel kills them.
- **One job model for every job**, whose clock each job's waits move on.
- **A step that says stop is recorded** (`stopped`), whichever step it
  was: one fed, a delivery, or one the driver ran for an invocation a
  command asked for. A host ends its loop there (`Editor/Loop.lean`,
  "Quit"), so the driver runs no further invocation of that step. It does
  not refuse what a test feeds it afterwards: a test reads `stopped`.
- **A reload a step asked for is counted** (`reloads`), and **a theme a step
  asked for is recorded** (`themes`). The driver has no config session to
  reload or to switch the theme of: a host feeds its reload reducer
  (`Editor/Headless.lean`).
- **A step that is refused changes the models and not the loop.** No
  program of the loop is refused today (`Editor/Loop.lean`, "When
  publishing is refused"); one that is hands back the refusal.

## Snapshots across the two models

A job reads the snapshots commands took, and its command takes in what the
job loaded. The driver hands both across as values, as the runtime does for
real (`Job.finishWith`, `Editor/Job/Real.lean`) and as the cases across the
two ports are played (`Editor/File/Cases.lean`):

- **A job reads what the editor has published.** When a job is started,
  the job model's published snapshots (`FileModel.snapshots`) are set to
  the text model's, as they are after the step that asked for the job. So
  a job saves a snapshot its command took, by its id, and reads one's text
  (`JobRequest.snapshot`), as the `words` source's job does.
- **What a job loaded is kept with the job** (`Pending.held`): the ids its
  loads made, until its command has run.
- **A finished job's command is handed what its job held, and nothing
  else.** For the delivery the text model's `arrived` holds those
  snapshots, under the job's ids; it is emptied after the delivery, and
  the job's snapshots are released in the file model
  (`FileModel.released`). So a command adopts what its own job loaded, and
  is refused another job's id, and its own job's once it has run.
- **A job that failed or was cancelled holds nothing.** No command will
  run for it, so what it loaded is released when it ends, which here is
  when it is started.
- **What a job's environments say is said in the echo area.** Each message
  a job's run appended to `jobs.reported`, a lookup that failed in a
  directory among them (`Editor/Process/Environment.lean`), is put in the
  loop's echo area when the job is started, in order, as the host's
  `Running.said` does, so the next scene shows the last of them.
- **The files are the driver's `jobs.files`.** A test sets them before it
  feeds an event, and changes them between two events to stand for another
  program writing a file.

Pinned by `ModelTest.driverChecks`, and the answers by
`ModelTest.promptChecks`.
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
  /-- The snapshots its loads made, which it holds until its command has
  run; none for a job that did not finish. -/
  held : Array JobSnapshotId := #[]
  /-- The key it was started with, if any (`JobStart.key`). -/
  key : Option String := none

/-- A job the driver holds waiting: parked at a `next` of one of its watches
that nothing recorded can answer yet (`JobModel.runParking`). -/
structure Loop.Driver.Parked where
  /-- The job's id. -/
  id : Nat
  /-- The name it was started under. -/
  name : String
  /-- The key it was started with, if any. -/
  key : Option String := none
  /-- The watch it waits on. -/
  watch : Nat
  /-- Its own watches: a job sees only its own. -/
  watches : Array FileWatchModel.Watch
  /-- Its own streaming children, out of the shared process model while it
  is held. -/
  children : Array ProcessModel.Child := #[]
  /-- The rest of the job, given the reply to its `next`. -/
  resume :
    Except FileWatchError (Array FileWatch.Change) → Program jobPort (Except String (EditorM Unit))

/-- A job the driver holds at a post (`JobModel.Ran.posted`): the editor has
not run what it posted, and the job goes on only once it has
(`Loop.Driver.posted`). -/
structure Loop.Driver.Posting where
  /-- The job's id. -/
  id : Nat
  /-- The name it was started under. -/
  name : String
  /-- The key it was started with, if any. -/
  key : Option String := none
  /-- What it posted. -/
  invocation : Invocation
  /-- Its own watches. -/
  watches : Array FileWatchModel.Watch := #[]
  /-- Its own streaming children, out of the shared process model while it
  is held, so that another job's end does not end them. -/
  children : Array ProcessModel.Child := #[]
  /-- The rest of the job. -/
  resume : Unit → Program jobPort (Except String (EditorM Unit))

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
  /-- The jobs held waiting at a watch, oldest first. -/
  parked : Array Loop.Driver.Parked := #[]
  /-- The jobs held at a post, oldest first. -/
  posting : Array Loop.Driver.Posting := #[]
  /-- The id the next job started gets. -/
  next : Nat := 1
  /-- Whether a step the driver took in said stop (`Loop.Next.stop`): a
  host ends its loop then. -/
  stopped : Bool := false
  /-- How many steps the driver took in asked for the config to be
  reloaded (`Loop.Stepped.reload`). The driver has no config session: a
  host feeds its reload reducer for each. -/
  reloads : Nat := 0
  /-- The themes steps the driver took in asked to be loaded
  (`Loop.Stepped.theme`), in order. The driver has no config session: a
  host feeds its reload reducer a choice for each. -/
  themes : Array String := #[]

namespace Loop.Driver

variable {scheme : InputScheme}

/-- A driver over the state `start` makes on `model`, with `keys` and the
registered jobs `registered`. The state begins with the heights `model`'s
display answers (`EditorState.heights`), as a host's has them once it has
published: so a step that changes nothing leaves the state as it was. Refused
when making the state is. -/
def over (keys : Loop.Keys scheme) (registered : String → Option (List Argument → Work))
    (start : TextM EditorState) (model : EditorModel) : Except TextError (Loop.Driver scheme) :=
  match (TextM.lift start).runModel model with
  | (.ok state, model) =>
    let state := { state with heights := model.display.cells.heights }
    .ok { loop := { state }, model, keys, registered }
  | (.error refusal, _) => .error refusal

/-- What a step of the driver's loop is handed: its `keys`, told which names
a job is registered under. -/
def handed (driver : Loop.Driver scheme) : Loop.Keys scheme :=
  { driver.keys with
    registered :=
      { driver.keys.registered with jobs := fun name => (driver.registered name).isSome } }

/-- The job model with each of the job snapshots `held` released. -/
def releasing (jobs : JobModel) (held : Array JobSnapshotId) : JobModel :=
  { jobs with files := held.foldl FileModel.released jobs.files }

/-- The driver's editor models with `arrived` as what a run of a command is
handed (`TextModel.arrived`). -/
def handing (driver : Loop.Driver scheme) (arrived : Array (JobSnapshotId × TextContent)) :
    Loop.Driver scheme :=
  { driver with model := { driver.model with texts := { driver.model.texts with arrived } } }

/-- The driver once the job `id`, called `name`, has run `program` on the
job model from where the driver's is, seeing only its own watches and its
own streaming children: kept as not delivered when it ended, as parked when
it waits at a watch with nothing recorded, and as posting when it posted.
What its environments said is said in the echo area, in order, as the host
says it (`Running.said`). The watches' and the children's ids come from the
shared counters. -/
def ranOn (driver : Loop.Driver scheme) (id : Nat) (name : String) (key : Option String)
    (program : Program jobPort (Except String (EditorM Unit)))
    (own : Array FileWatchModel.Watch := #[]) (children : Array ProcessModel.Child := #[]) :
    Loop.Driver scheme :=
  let files := { driver.jobs.files with snapshots := driver.model.texts.snapshots }
  let shared := driver.jobs.fileWatches
  let sharedChildren := driver.jobs.processes.children
  let start :=
    { driver.jobs with
      files, fileWatches := { shared with watches := own }
      processes := { driver.jobs.processes with children } }
  -- A job held at a watch or a post takes its children out with it.
  let apart (jobs : JobModel) : JobModel :=
    { jobs with
      fileWatches := { jobs.fileWatches with watches := #[] }
      processes := { jobs.processes with children := sharedChildren } }
  let saidBy (jobs : JobModel) : Loop scheme :=
    let said := jobs.reported.extract driver.jobs.reported.size jobs.reported.size
    said.foldl (fun loop text => { loop with state := { loop.state with echo := text } })
      driver.loop
  match JobModel.runParking program start with
  | .ended value jobs =>
    let driver := { driver with loop := saidBy jobs }
    let outcome : Job.Outcome (EditorM Unit) :=
      match value with
      | some (.ok command) => .finished command
      | some (.error message) => .failed message
      | none => .cancelled
    let loaded : Array JobSnapshotId :=
      (Array.range (jobs.files.held.size - files.held.size)).map (⟨files.held.size + ·⟩)
    let finished := outcome matches .finished _
    let jobs := apart jobs
    { driver with
      jobs := if finished then jobs else releasing jobs loaded
      pending :=
        driver.pending.push { id, name, outcome, held := if finished then loaded else #[], key } }
  | .parked watch jobs resume =>
    { driver with
      loop := saidBy jobs
      jobs := apart jobs
      parked :=
        driver.parked.push
          { id, name, key, watch, watches := jobs.fileWatches.watches
            children := jobs.processes.children, resume } }
  | .posted invocation jobs resume =>
    { driver with
      loop := saidBy jobs
      jobs := apart jobs
      posting :=
        driver.posting.push
          { id, name, key, invocation, watches := jobs.fileWatches.watches
            children := jobs.processes.children, resume } }

/-- Ends the job of `key`, parked, posting or finished and not delivered: its
command never runs, nor do the posts it has not made, a held job's watches
are recorded as ended, and each of its streaming children still running as
killed (`ProcessModel.killed`), as the runner's cancel kills it. Nothing for
a key no such job has. -/
def cancel (driver : Loop.Driver scheme) (key : String) : Loop.Driver scheme :=
  let ending := driver.parked.filter (·.key == some key)
  let posting := driver.posting.filter (·.key == some key)
  let shared := driver.jobs.fileWatches
  let children := ending.flatMap (·.children) ++ posting.flatMap (·.children)
  let processes := driver.jobs.processes
  { driver with
    parked := driver.parked.filter (·.key != some key)
    posting := driver.posting.filter (·.key != some key)
    pending := driver.pending.filter (·.key != some key)
    jobs :=
      { driver.jobs with
        fileWatches :=
          { shared with
            ended :=
              shared.ended ++ ending.flatMap (·.watches.map (·.id)) ++
                posting.flatMap (·.watches.map (·.id)) }
        processes :=
          { processes with
            killed := processes.killed ++ (children.filter (!·.done)).map (·.script.command) } } }

/-- How many watches the parked jobs hold open. -/
def openWatches (driver : Loop.Driver scheme) : Nat :=
  driver.parked.foldl (fun count job => count + job.watches.size) 0

/-- The driver once `changes` happened on disk: each is recorded in every
parked job's watches, and each job whose watch now has a delivery is resumed
with it, on the job clock, and then ends or parks again as a started job
does. -/
def touch (driver : Loop.Driver scheme) (changes : Array (System.FilePath × FileWatch.Kind)) :
    Loop.Driver scheme :=
  let jobs := driver.parked
  let driver := { driver with parked := #[] }
  jobs.foldl
    (fun driver job =>
      let shared := driver.jobs.fileWatches
      let watches :=
        ({ shared with watches := job.watches } : FileWatchModel).touch changes driver.jobs.now
      let due := watches.watches.any fun watch => watch.id == job.watch && watch.opened.isSome
      if !due then
        { driver with parked := driver.parked.push { job with watches := watches.watches } }
      else
        let (reply, answered, now) := watches.handle driver.jobs.now none (.next ⟨job.watch⟩)
        let driver := { driver with jobs := { driver.jobs with now } }
        driver.ranOn job.id job.name job.key (job.resume reply) answered.watches job.children)
    driver

/-- The driver once each of `starts` is started: the job registered under
its name, applied to its arguments, is run on the job model, and what it
ended with is kept as not delivered, under the next id, or the job is held
parked at a watch; either way what its environments said is said in the
echo area. A start of a key first cancels the job of that key. A start
whose name no job is registered under is passed over: the loop refused it
when the command asked.

The job reads the text model's snapshots as the published ones. What its
loads made is kept with it when it finished, and released otherwise
("Snapshots across the two models", in the module docs). -/
def started (driver : Loop.Driver scheme) (starts : Array JobStart) : Loop.Driver scheme :=
  starts.foldl
    (fun driver start =>
      match driver.registered start.name with
      | none => driver
      | some work =>
        let driver :=
          match start.key with
          | some key => driver.cancel key
          | none => driver
        let id := driver.next
        ({ driver with next := driver.next + 1 } : Loop.Driver scheme).ranOn id start.name start.key
          (work start.arguments ()).run)
    driver

/-- The driver once each of `spawns` is run (`Loop.Spawn`): the job of its
key is cancelled first, and its work is run on the job model as a started
job's is, under the next id, kept under its label and its key. -/
def spawned (driver : Loop.Driver scheme) (spawns : Array Loop.Spawn) : Loop.Driver scheme :=
  spawns.foldl
    (fun driver spawn =>
      let driver := driver.cancel spawn.key
      let id := driver.next
      ({ driver with next := driver.next + 1 } : Loop.Driver scheme).ranOn id spawn.label
        (some spawn.key) (spawn.work ()).run)
    driver

/-- Takes in `stepped`, a step the driver's loop took, which left the models
as `model`, as a host does: the driver with the loop the step left, its
cancels made, the jobs it asked for started and the work it spawned run, in
that order, and each invocation it answered run as a step
of its own (`Loop.invoke`), which is taken in the same way, before anything
else is fed. An answer's step that is refused changes the models and not
the loop. A step that said stop is recorded (`stopped`), and no invocation
is run once one has. A step that asked for a reload is counted
(`reloads`), and the theme a step asked for is recorded (`themes`).

It has no termination proof: an answer's command can ask and accept again,
for ever, which is runaway code (`docs/design/concurrency.md`, "Runaway
code is not a design driver"). -/
partial def took (driver : Loop.Driver scheme) (stepped : Loop.Stepped scheme)
    (model : EditorModel) : Loop.Driver scheme :=
  let driver :=
    (stepped.cancels.foldl Loop.Driver.cancel
          { driver with
            loop := stepped.loop, model
            stopped := driver.stopped || stepped.next == Loop.Next.stop
            reloads := driver.reloads + if stepped.reload then 1 else 0
            themes := driver.themes ++ stepped.theme.toArray }).started
      stepped.starts
  let driver := driver.spawned stepped.spawns
  stepped.answered.foldl
    (fun driver invocation =>
      -- A host whose loop has ended runs nothing more.
      if driver.stopped then driver
      else
        match (driver.loop.invoke driver.handed invocation).runModel driver.model with
        | (.ok answered, model) => driver.took answered model
        | (.error _, model) => { driver with model })
    driver

/-- Runs `step`, a program of the loop that hands back a step, on the
models, and takes the step in (`took`): the driver after it, and the step,
or the refusal of a program that was refused, with the loop as it was. The
step handed back is the program's own: the steps of the invocations it
answered are taken in and not handed back. -/
def stepped (driver : Loop.Driver scheme) (step : EditorM (Loop.Stepped scheme)) :
    Loop.Driver scheme × Except TextError (Loop.Stepped scheme) :=
  match step.runModel driver.model with
  | (.ok stepped, model) => (driver.took stepped model, .ok stepped)
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
that failed or was cancelled, and for a delivery that was refused.

The delivery is handed what the job held, and nothing is handed or held
once it has run ("Snapshots across the two models", in the module docs). -/
def finish (driver : Loop.Driver scheme) (id : Nat) :
    Loop.Driver scheme × Option (Loop.Stepped scheme) :=
  match driver.pending.find? (·.id == id) with
  | none => (driver, none)
  | some job =>
    let driver := { driver with pending := driver.pending.filter (·.id != id) }
    match job.outcome with
    | .finished command =>
      let arrived :=
        job.held.filterMap fun held => (driver.jobs.files.held[held.number]?).join.map (held, ·)
      let (driver, stepped) :=
        (driver.handing arrived).stepped
          (driver.loop.deliver driver.handed s!"job {job.id} {job.name}" command)
      (({ driver with jobs := releasing driver.jobs job.held } : Loop.Driver scheme).handing #[],
        stepped.toOption)
    | .failed _ | .cancelled => (driver, none)

/-- The job `id`'s post arrives: the loop is handed what it posted, as a
command labelled `job <id> <name>` (`Loop.deliver`, `runPosted`), and the
step is taken in as `finish` takes one in; then the job goes on, with its
own watches and children, and ends, parks or posts again. The step the
delivery handed back; `none`, with nothing delivered, for an id no job held
at a post has, and for a delivery that was refused. A delivery whose step
cancels the job's own key leaves it cancelled, and it does not go on. -/
def posted (driver : Loop.Driver scheme) (id : Nat) :
    Loop.Driver scheme × Option (Loop.Stepped scheme) :=
  match driver.posting.find? (·.id == id) with
  | none => (driver, none)
  | some job =>
    let (driver, stepped) :=
      driver.stepped
        (driver.loop.deliver driver.handed s!"job {job.id} {job.name}" (runPosted job.invocation))
    -- The job is held through its delivery, so the delivery's own cancel
    -- of its key reaches it.
    if driver.posting.any (·.id == id) then
      (({ driver with posting := driver.posting.filter (·.id != id) } : Loop.Driver scheme).ranOn
          job.id job.name job.key (job.resume ()) job.watches job.children,
        stepped.toOption)
    else (driver, stepped.toOption)

end Loop.Driver

end Editor
