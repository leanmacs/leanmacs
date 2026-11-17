import Editor.Appearance
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
  commands, jobs, key bindings, modes, ex bindings, faces, themes,
  segments, languages, compile contributions, completion sources and
  completion styles
  (`Registry.replace`, `Registry.replaceJobs`, `Registry.replaceBindings`,
  `Registry.replaceModes`, `Registry.replaceEx`, `Registry.replaceFaces`,
  `Registry.replaceThemes`, `Registry.replaceSegments`,
  `Registry.replaceLanguages`, `Registry.replaceContributions`,
  `Registry.replaceSources`, `Registry.replaceStyles`, never an append),
  sets config's choices of completion style (`Registry.styleChoices`),
  sets the registry's process
  environment to the one the config set, `none` when it set none
  (`Registry.environment`), and meets the config's stores with the cells
  there are (`Cells.install`). A rejected outcome changes none of them: the config that
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
- **The mode line follows the registry and config's listing.** An install
  replaces config's segments (`Registry.replaceSegments`) and sets the
  listing in force (`State.modeLine`) to the one the config made, or none
  for the default order, so a reload that lists none goes back to the
  default. A listed name no segment is registered under is left out, and
  the report names it (`Report.unknownSegments`), which the echo area says
  after the unknown theme's sentence. The host resolves the listing over
  the registry for each step (`Headless.keys`). A rejected outcome changes
  none of it.
- **The completion styles follow the registry and config's choices.** An
  install replaces config's styles and sets its choices, none for a config
  that chooses none, so a reload that chooses none goes back to the fuzzy
  style for every prompt. A chosen name no style is registered under
  leaves its category to the default, and the default to the fuzzy style,
  and the report names it (`Report.unknownStyles`), which the echo area
  says after the segments' sentences. The host resolves the choices over
  the registry for each step (`Registry.matching`, `Headless.keys`). A
  rejected outcome changes none of it.
- **The frame padding follows config.** An install sets the padding in
  force (`State.framePadding`) to the one the config set, or none for the
  editor's 8 (`Loop.padding`), so a reload that sets none goes back to it.
  The host hands it to the loop for each step (`Headless.keys`), so it
  changes with no restart. A rejected outcome changes none of it.
- **The layout follows config.** An install sets the layout in force
  (`State.layout`) to the one the config chose, or none for the editor's
  (`Layout.default`), so a reload that chooses none goes back to it. The
  host hands it to the loop for each step (`Headless.keys`,
  `Loop.Keys.layout`), so it changes with no restart. A rejected outcome
  changes none of it.
- **The tab bar follows config.** An install sets when the tab bar is
  shown (`State.tabBar`) to what the config chose, or none for the
  editor's own (`TabBar.Shown.several`), so a reload that chooses none
  goes back to it. The host hands it to the loop for each step
  (`Headless.keys`, `Loop.Keys.tabBar`). A rejected outcome changes none
  of it.
- **The display rules follow config.** An install checks each display
  rule the config made (`displayRule`) against the layout it chose, or the
  editor's when it chose none (`DisplayTarget.missing?`): a rule whose
  target does not exist is left out, and the report says so in a sentence
  (`Report.unusableRules`, `Report.leftOut`), which the echo area says
  after the segments'. The rest are set in the registry
  (`Registry.displayRules`), so a reload that makes none clears them, and
  the loop is handed them (`Registry.registered`). A rejected outcome
  changes none of it.
- **The window's appearance follows the paper.** Once the window has
  opened (`Event.windowOpened`), the reducer asks for the appearance that
  contrasts with the effective paper (`Theme.paper` of `State.theme`,
  classified by `Appearance.ofPaper`, `Editor/Appearance.lean`) with the
  effect `appearance`, and after that only when the classification
  changes: after a reload, installed or not, and after a choice of a
  theme. So a switch between two dark themes, or a reload that keeps the
  paper dark, asks for nothing, and one that keeps the theme and overrides
  the paper from light to dark asks for dark. Nothing is asked before the
  window has opened, since a request asked of no running window is lost
  (`editor-platform`'s crate docs, "What a window is asked"), and a window
  that opens again is asked afresh. A theme that states no paper asks for
  nothing. The effect comes after `themed` and after a reload's report.
- **The title bar follows config, at the next start.** An install sets the
  title bar in force (`State.titleBar`) to the one the config chose, or
  none for the themed one. The window mode reads it once, when it opens the
  window after the start-up reload (`Window.titleBarAtOpen`), so a reload
  that changes it takes effect at the next start. A rejected outcome
  changes none of it.
- **Every install is a new config generation.** An install sets config's
  workspace roots in the registry (`Registry.workspaceRoots`) and bumps
  its generation (`Registry.generation`), which a directory's cached
  workspace is stamped with (`Editor/Workspace.lean`): so the next file
  opened after an install asks its directory's workspace again, as an
  install drops every directory's cached environment. A rejected outcome
  changes neither.
- **An install replaces config's compile contributions and project
  commands** (`Registry.replaceContributions`, `Registry.projectCommands`):
  a file opened after it turns on the modes they give, and the compile mode
  uses their commands at its next use. A rejected outcome changes neither.
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
  /-- The segment names the installed config's mode line lists that no
  segment is registered under, in order, each once: they are left out, and
  the rest are drawn. -/
  unknownSegments : Array String := #[]
  /-- The completion style names the installed config chose that no style is
  registered under, in order, each once: their categories fall to the
  default, and the default to the fuzzy style. -/
  unknownStyles : Array String := #[]
  /-- What is said of each display rule of the installed config whose target
  the layout it chose lacks, in order (`Report.leftOut`): those rules are
  left out, and the rest are kept. -/
  unusableRules : Array String := #[]

/-- What is said of the display rule at `place` of a `setup`, 1-based, left
out at install for `reason`, its target's `DisplayTarget.missing?`. -/
def Report.leftOut (place : Nat) (reason : String) : String :=
  s!"display rule {place} is left out: {reason}"

/-- What a reload says in the echo area: for a rejected one, its first
error, `reload: <source>:<line>:<column>: error: ` and the first line of its
message, then ` (and <n> more)` when it has more errors; for one rejected
with no error to name, `reload: rejected`. A reload that installs says
nothing, so a working config does not cover what a command said, unless its
config named a theme, listed segments or chose completion styles nobody
registered, or made display rules whose targets do not exist: then
`reload: ` and the sentences, `Theme.unknown`'s, then each
`ModeLine.unknown`, then each `Completion.Styles.unknown` and then each
rule left out (`unusableRules`), joined by `; `. The whole report is the host's to
print. -/
def Report.echo (report : Report) : Option String :=
  if report.installed then
    let sentences :=
      report.unknownTheme.toArray.map Theme.unknown ++
        report.unknownSegments.map ModeLine.unknown ++
        report.unknownStyles.map Completion.Styles.unknown ++
        report.unusableRules
    if sentences.isEmpty then none else some s!"reload: {"; ".intercalate sentences.toList}"
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
  /-- The listing of the mode line the installed config made, or none for
  the default order (`ModeLine.Order.standard`): set at every install, so a
  config that lists none goes back to the default. -/
  modeLine : Option ModeLine.Order := none
  /-- The frame padding the installed config set, in points, or none for the
  editor's own (`Loop.padding`): set at every install, so a config that
  sets none goes back to it. -/
  framePadding : Option Nat := none
  /-- The layout the installed config chose (`layout`), or none for the
  editor's own (`Layout.default`): set at every install, so a config that
  chooses none goes back to it. -/
  layout : Option Layout := none
  /-- When the installed config chose the tab bar to be shown (`tabBar`), or
  none for the editor's own (`TabBar.Shown.several`): set at every install,
  so a config that chooses none goes back to it. -/
  tabBar : Option TabBar.Shown := none
  /-- The title bar the installed config chose (`titleBar`), or none for the
  themed one: set at every install, so a config that chooses none goes
  back to it. The window mode reads it when it opens the window. -/
  titleBar : Option Window.TitleBar := none
  /-- Whether the window has opened (`Event.windowOpened`): only then is an
  appearance asked of it. -/
  windowOpen : Bool := false
  /-- The appearance the window was last asked, since it last opened; none
  before one is. -/
  appearance : Option Appearance := none

/-- What happened, as far as reloads go. -/
inductive Event (σ : Type) where
  /-- A reload was asked for. -/
  | requested
  /-- The reload job finished with `outcome`. -/
  | finished (outcome : Outcome σ)
  /-- The theme called `name` was chosen, by a command, to be the theme in
  force. -/
  | choose (name : String)
  /-- The window opened. Whatever was asked of it before is lost. -/
  | windowOpened

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
  /-- Ask the window to draw its title and buttons in this appearance. -/
  | appearance (appearance : Appearance)

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
    -- A rule whose target the chosen layout lacks is left out, and said.
    let chosen := built.registrations.layout.getD Layout.default
    let checked :=
      built.registrations.displayRules.mapIdx fun index rule =>
        (rule, (rule.target.missing? chosen).map (Report.leftOut (index + 1)))
    let displayRules := (checked.filter (·.2.isNone)).map (·.1)
    let unusableRules := checked.filterMap (·.2)
    let (cells, lost) := state.cells.install .config built.registrations.stores
    let state :=
      { state with
        chunks := built.chunks,
        registry :=
          {
            (((((((((((state.registry.replace .config built.registrations.commands).replaceJobs
                                                  .config built.registrations.jobs).replaceBindings
                                              .config built.registrations.bindings).replaceModes
                                          .config built.registrations.modes).replaceEx
                                      .config built.registrations.ex).replaceFaces
                                  .config built.registrations.faces).replaceThemes
                              .config built.registrations.themes).replaceSegments
                          .config built.registrations.segments).replaceLanguages
                      .config built.registrations.languages).replaceContributions
                  .config built.registrations.contributions).replaceSources
              .config built.registrations.sources).replaceStyles
              .config
              built.registrations.styles with
            styleChoices := built.registrations.styleChoices
            environment := built.registrations.environment
            autoReload := built.registrations.autoReload.back?.getD false
            workspaceRoots := built.registrations.workspaceRoots
            generation := state.registry.generation + 1
            displayRules
            shellTimeLimit := built.registrations.shellTimeLimit
            syntaxRefreshDelay := built.registrations.syntaxRefreshDelay
            projectCommands := built.registrations.projectCommands },
        cells }
    let (themeName, unknownTheme) :=
      chooseAt state.registry state.themeName built.registrations.theme
    let modeLine := built.registrations.modeLine
    let unknownSegments := (modeLine.map fun order => (state.registry.resolve order).2).getD #[]
    let unknownStyles := state.registry.unknownStyles
    ({ state with
        themeName, modeLine, framePadding := built.registrations.framePadding
        layout := built.registrations.layout, tabBar := built.registrations.tabBar
        titleBar := built.registrations.titleBar },
      { number := state.finished, installed := true, diagnostics := outcome.diagnostics ++ lost,
        chunks := state.chunks.size, commands := state.commands, unknownTheme, unknownSegments
        unknownStyles, unusableRules })

/-- The appearance the window is to be asked for, and the state that
remembers it: when the window is open and the paper of the theme now in
force (`theme`) classifies as an appearance other than the one last asked,
that one; nothing otherwise. -/
def ask (state : State σ) : State σ × Array (Effect σ) :=
  match state.theme.paper.map Appearance.ofPaper with
  | some appearance =>
    if state.windowOpen && state.appearance != some appearance then
      ({ state with appearance := some appearance }, #[.appearance appearance])
    else (state, #[])
  | none => (state, #[])

end State

/-- The reducer before the window's appearance is asked. -/
private def stepTheme {σ : Type} (state : State σ) : Event σ → State σ × Array (Effect σ)
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
  | .windowOpened =>
    ({ state with
        windowOpen := true, appearance := none },
      #[])

/-- The reducer: the state after `event`, and the effects to perform. The
window's appearance is asked last (`State.ask`), after whatever the event
did to the theme in force. -/
def step {σ : Type} (state : State σ) (event : Event σ) : State σ × Array (Effect σ) :=
  let (state, effects) := stepTheme state event
  let (state, asked) := state.ask
  (state, effects ++ asked)

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
