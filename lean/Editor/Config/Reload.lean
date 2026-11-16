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
  commands, jobs, key bindings, modes, ex bindings and faces
  (`Registry.replace`, `Registry.replaceJobs`, `Registry.replaceBindings`,
  `Registry.replaceModes`, `Registry.replaceEx`, `Registry.replaceFaces`,
  never an append) and meets the config's stores with the cells there are
  (`Cells.install`). A rejected outcome changes none of them: the config that
  was loaded stays.
- **The theme follows the registry and the theme in force.** The theme in
  force is a name (`State.themeName`), `default` to start with, and
  `State.theme` is the registry's theme of that name followed by the
  installed config's definitions of faces, so config's faces are over
  whichever theme is in force, and survive a switch. It changes when a
  reload installs and when a theme is chosen (`Event.choose`), and only
  then. The runtime that owns a display hands it the theme then
  (`Config.retheme`, `Editor/Config/Display.lean`).
- **Which theme is in force.** An install also replaces config's themes
  (`Registry.replaceThemes`), then: a config that names a registered theme
  (`useTheme`) puts it in force; one that names a theme nobody registered
  keeps the theme in force and its report names the unknown theme, which
  the echo area says (`Report.echo`); one that names none keeps the theme in
  force, so a theme chosen by the command survives a reload that does not
  name one. A theme in force that is no longer registered, because config
  defined it and dropped it, falls back to `default` (`chooseAt`). A
  rejected outcome changes none of it.
- **Choosing a theme** (`Event.choose`, which the host feeds for a command
  that loaded one) puts a registered theme in force, with the effect
  `themed`; a name nobody registered changes nothing and has no effect,
  since the command has already said so.
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
writes is this state. `State.command?` is the lookup an invocation uses:
given what the command is called with (`Editor/Command/Call.lean`), the
program to run against the editor's port. `State.program?` is the same for a
command run by its name alone, as the driver's `run <name>` does. Each
program's value is what the command asks to be written
(`Write`, `Editor/Config/Stores.lean`), and `State.written` takes it back.
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
  /-- The theme the installed config named that no theme is registered
  under, if it named one: the theme in force stayed. -/
  unknownTheme : Option String := none

/-- What a reload says in the echo area: for a rejected one, its first
error, `reload: <source>:<line>:<column>: error: ` and the first line of its
message, then ` (and <n> more)` when it has more errors; for one rejected
with no error to name, `reload: rejected`. A reload that installs says
nothing, so a working config does not cover what a command said, unless its
config named a theme nobody registered: then `reload: ` and
`Theme.unknown`. The whole report is the host's to print. -/
def Report.echo (report : Report) : Option String :=
  if report.installed then report.unknownTheme.map fun name => s!"reload: {Theme.unknown name}"
  else
    let errors := report.diagnostics.filter (·.severity == .error)
    match errors[0]? with
    | none => some "reload: rejected"
    | some first =>
      let line := (first.message.splitOn "\n").headD ""
      let more := if errors.size > 1 then s!" (and {errors.size - 1} more)" else ""
      some s!"reload: {first.source}:{first.line}:{first.column}: error: {line}{more}"

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
  /-- The name of the theme in force: set by an install whose config names
  a registered theme, and by `choose`. -/
  themeName : String := Theme.defaultName

/-- What happened, as far as reloads go. -/
inductive Event (σ : Type) where
  /-- A reload was asked for. -/
  | requested
  /-- The reload job finished with `outcome`. -/
  | finished (outcome : Outcome σ)
  /-- The theme called `name` was chosen, by a command, to be the theme in
  force. -/
  | choose (name : String)

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
  /-- The theme in force was switched, with no reload: the display is to
  be handed the new theme. -/
  | themed

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

/-- What the faces look like now: the theme in force (`themeName`), then
the definitions the installed config made, in the order its `setup` made
them. A later definition of a name is over an earlier one, so a face the
config sets takes the config's attributes over the theme's, whichever theme
is in force, and a face it does not set is the theme's. The theme in force
stands in for the built-in theme wholesale: a face it does not define is not
the built-in theme's. A registry that holds no theme of the name in force
draws in the built-in theme. -/
def theme (state : State σ) : Theme :=
  (((state.registry.theme? state.themeName).map (·.theme)).getD Theme.builtin) ++
    state.registry.definitions

/-- The theme in force once a config that named `named` is installed over
`registry`, from `current`, the one in force before: a name registered under
is in force; with an unregistered name, or none, `current` stays, unless no
theme is registered under it any more, when `default` is. The second is the
unregistered name, for the report. -/
def chooseAt (registry : Registry) (current : String) (named : Option String) :
    String × Option String :=
  let kept := if (registry.theme? current).isSome then current else Theme.defaultName
  match named with
  | some name => if (registry.theme? name).isSome then (name, none) else (kept, some name)
  | none => (kept, none)

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
          ((((((state.registry.replace .config built.registrations.commands).replaceJobs .config
                                built.registrations.jobs).replaceBindings
                            .config built.registrations.bindings).replaceModes
                        .config built.registrations.modes).replaceEx
                    .config built.registrations.ex).replaceFaces
                .config built.registrations.faces).replaceThemes
            .config built.registrations.themes,
        cells }
    let (themeName, unknownTheme) :=
      chooseAt state.registry state.themeName built.registrations.theme
    ({ state with themeName },
      { number := state.finished, installed := true, diagnostics := outcome.diagnostics ++ lost,
        chunks := state.chunks.size, commands := state.commands, unknownTheme })

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
  | .choose name =>
    if (state.registry.theme? name).isSome then ({ state with themeName := name }, #[.themed])
    else (state, #[])

namespace State

variable {σ : Type}

/-- The program of a plain command: `run`, which asks for nothing to be
written. -/
private def plainly (run : EditorM Unit) : EditorM (Option Write) := do
  run
  return none

/-- The program of `owner`'s command over the store called `store`: `step`
applied to the tree of the store's cell, whose value is what to write back;
`none` if there is no such cell.

The install rule makes a cell for every store a config declares, and a
`setup` that registers a command over a store it does not declare is
refused, so such a command always finds its cell. -/
private def overStore? (state : State σ) (owner : Owner) (store : String)
    (step : Value → EditorM Value) : Option (EditorM (Option Write)) := do
  let cell ← state.cells.find? owner store
  return do
    let value ← step cell.value
    return some { owner, store, value }

/-- What an invocation of the command called `name` runs: given the call,
the program to run against the editor's port, whose value is what to write
back if it succeeds; `none` if there is no such command. It is the latest
entry of the name, so config's command runs in place of a compiled one of
the same name.

A plain command and a command over a store are not told of the call; a
command that is given its call is handed it. -/
def command? (state : State σ) (name : String) : Option (Call → EditorM (Option Write)) := do
  let entry ← state.registry.find? name
  match entry.registration.action with
  | .plain run =>
    return fun _ => plainly run
  | .call run =>
    return fun call => plainly (run call)
  | .store store step =>
    let program ← state.overStore? entry.owner store step
    return fun _ => program

/-- The program that running the command called `name` by its name runs
against the editor's port, as the driver's `run <name>` does, and whose
value is what to write back if it succeeds; `none` if there is no such
command.

No key ran it, so a command that is given its call is handed `target` and
nothing else: no arguments and no keys. With no target there is no call to
hand it, and it is not run: `none`. -/
def program? (state : State σ) (name : String) (target : Option Target := none) :
    Option (EditorM (Option Write)) := do
  let entry ← state.registry.find? name
  match entry.registration.action with
  | .plain run =>
    return plainly run
  | .call run =>
    target.map fun target => plainly (run { target })
  | .store store step =>
    state.overStore? entry.owner store step

/-- The state once what a command wrote is written back. -/
def written (state : State σ) : Option Write → State σ
  | none => state
  | some write => { state with cells := state.cells.set write.owner write.store write.value }

/-- The job registered under `name`, to be started with `arguments`, and the
owner the runtime is to start it for; `none` if there is no such job. -/
def work? (state : State σ) (name : String) (arguments : List Argument := []) :
    Option (Owner × Work) :=
  (state.registry.findJob? name).map fun entry => (entry.owner, entry.registration.work arguments)

end State

end Editor.Config
