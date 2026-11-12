import Editor.Config.Session
import Editor.Config.Stores

/-!
# Reloads, serialised by a reducer

The config half of the editor's state, and the pure function that moves it.
`step` takes the state and an event (a reload was asked for; a reload job
finished) to the new state and the effects for the runtime to perform (start
a reload job; cancel an owner's jobs; report a reload). It holds no `IO`, so
the model tests run it with outcomes built by hand
(`ModelTest.reloadChecks`).

- **One job at a time.** A request with no job running starts one. A request
  that arrives while one runs only sets a flag, so any number of them make
  exactly one follow-up job, started when the running one's outcome has been
  handled. The follow-up therefore reads the source afresh and starts from
  what was just installed, and two reloads cannot install out of order.
- **Installing is the only place config changes anything.** An accepted
  outcome replaces the chunks, replaces the config's entries in the registry,
  commands and jobs (`Registry.replace`, `Registry.replaceJobs`, never an
  append) and meets the config's stores with the cells there are
  (`Cells.install`). A rejected outcome changes none of them: the config that
  was loaded stays.
- **A reload cancels the old config's jobs when, and only when, it
  installs.** An accepted outcome's effects begin with `cancelJobs config`,
  before its report and before a follow-up job starts; a rejected outcome has
  no such effect, so the old config's jobs run on, with their handlers. Every
  accepted reload cancels, one whose source did not change included. The
  runtime performs the effects of one event in order on the editor thread, so
  no command or handler of the old config runs after the install. The reload
  starts no job of the new config.
- **The base is kept** from the first outcome that has it, accepted or not,
  and handed to every later job, so it is imported once.
- **Every outcome is reported**, with its diagnostics.

The runtime that owns the state calls `step` for each event, on the editor
thread, and performs the effects: the headless loop today
(`Editor/Headless.lean`), the command loop later.

Running a command is here too, because what a command over a store reads and
writes is this state: `State.program?` is the program to run against the
editor's port, and `State.written` takes what it wrote back.
-/

namespace Editor.Config

/-- What a reload came to, for whoever shows it. -/
structure Report where
  /-- Which reload this is: the first to finish is 1. -/
  number : Nat
  /-- Whether the new config was installed; `false` when it was rejected and
  the old one stays. -/
  installed : Bool
  /-- What the reload has to say: the errors that rejected it, warnings, and
  the store values that were lost when it was installed. -/
  diagnostics : Array Diagnostic
  /-- How many chunks the config that is now installed has. -/
  chunks : Nat
  /-- How many commands the config that is now installed registers. -/
  commands : Nat

/-- The config half of the editor's state. -/
structure State (σ : Type) where
  /-- The base, once a reload has imported it. -/
  base : Option σ := none
  /-- The chunks of the config that is installed. -/
  chunks : Array (Chunk σ) := #[]
  /-- The commands. -/
  registry : Registry := {}
  /-- The cells of the stores. -/
  cells : Cells := {}
  /-- Whether a reload job is running. -/
  running : Bool := false
  /-- Whether a reload was asked for while one was running. -/
  pending : Bool := false
  /-- How many reloads have finished. -/
  finished : Nat := 0

/-- What happened, as far as reloads go. -/
inductive Event (σ : Type) where
  /-- A reload was asked for. -/
  | requested
  /-- The reload job finished with `outcome`. -/
  | finished (outcome : Outcome σ)

/-- What the runtime is to do. -/
inductive Effect (σ : Type) where
  /-- Start a reload job: `Config.build` with this base and these loaded
  chunks, whose outcome comes back as a `finished` event. -/
  | start (base : Option σ) (chunks : Array (Chunk σ))
  /-- Cancel every job that runs for `owner`, and drop the handlers of its
  jobs that have ended and not yet been dealt with: the config that started
  them has just been replaced. -/
  | cancelJobs (owner : Owner)
  /-- Show what a reload came to. -/
  | report (report : Report)

namespace State

variable {σ : Type}

/-- The state with a reload job started, and the effect that starts it. -/
def start (state : State σ) : State σ × Array (Effect σ) :=
  ({ state with
      running := true, pending := false },
    #[.start state.base state.chunks])

/-- How many commands the config registers. -/
def commands (state : State σ) : Nat :=
  (state.registry.entries.filter (·.owner == .config)).size

/-- The state once `outcome` is handled, and the report of it: an outcome
that built a config installs it, and any other leaves the config as it was. -/
def install (state : State σ) (outcome : Outcome σ) : State σ × Report :=
  let state :=
    { state with
      base := outcome.base <|> state.base, running := false, finished := state.finished + 1 }
  match outcome.built with
  | none =>
    (state,
      { number := state.finished, installed := false, diagnostics := outcome.diagnostics,
        chunks := state.chunks.size, commands := state.commands })
  | some built =>
    let (cells, lost) := state.cells.install .config built.registrations.stores
    let state :=
      { state with
        chunks := built.chunks,
        registry :=
          (state.registry.replace .config built.registrations.commands).replaceJobs .config
            built.registrations.jobs,
        cells }
    (state,
      { number := state.finished, installed := true, diagnostics := outcome.diagnostics ++ lost,
        chunks := state.chunks.size, commands := state.commands })

end State

/-- The reducer: the state after `event`, and the effects to perform. -/
def step {σ : Type} (state : State σ) : Event σ → State σ × Array (Effect σ)
  | .requested => if state.running then ({ state with pending := true }, #[]) else state.start
  | .finished outcome =>
    let (state, report) := state.install outcome
    -- The old config's jobs go when, and only when, the new one is in.
    let installed :=
      if report.installed then #[.cancelJobs .config, .report report] else #[.report report]
    if state.pending then
      let (state, effects) := state.start
      (state, installed ++ effects)
    else (state, installed)

/-- What a command asks the editor to write when it has run: the new tree of
a store's cell. -/
structure Write where
  /-- Whose store it is. -/
  owner : Owner
  /-- The store's name. -/
  store : String
  /-- The cell's new tree. -/
  value : Value

namespace State

variable {σ : Type}

/-- The program that running the command called `name` runs against the
editor's port, and whose value is what to write back if it succeeds; `none`
if there is no such command.

A command over a store is its step applied to the tree of the store's cell.
The install rule makes a cell for every store a config declares, and a
`setup` that registers a command over a store it does not declare is
refused, so such a command always finds its cell. -/
def program? (state : State σ) (name : String) : Option (EditorM (Option Write)) := do
  let entry ← state.registry.find? name
  match entry.registration.action with
  | .plain run =>
    return do
      run
      return none
  | .store store step =>
    let cell ← state.cells.find? entry.owner store
    return do
      let value ← step cell.value
      return some { owner := entry.owner, store, value }

/-- The state once what a command wrote is written back. -/
def written (state : State σ) : Option Write → State σ
  | none => state
  | some write => { state with cells := state.cells.set write.owner write.store write.value }

/-- The job registered under `name`, and the owner the runtime is to start it
for; `none` if there is no such job. -/
def work? (state : State σ) (name : String) : Option (Owner × Work) :=
  (state.registry.findJob? name).map fun entry => (entry.owner, entry.registration.work)

end State

end Editor.Config
