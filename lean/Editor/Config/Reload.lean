import Editor.Appearance
import Editor.Config.Session
import Editor.Config.Stores
import Editor.PackageSet.Build
import EnvironmentApi

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
  outcome replaces the files, replaces the config's entries in the registry,
  commands, jobs, key bindings, modes, ex bindings, faces, themes,
  segments, languages, completion sources,
  completion styles and completion displays
  (`Registry.replace`, `Registry.replaceJobs`, `Registry.replaceBindings`,
  `Registry.replaceModes`, `Registry.replaceEx`, `Registry.replaceFaces`,
  `Registry.replaceThemes`, `Registry.replaceSegments`,
  `Registry.replaceLanguages`,
  `Registry.replaceSources`, `Registry.replaceStyles`, never an append),
  and its prefix names (`Registry.replacePrefixNames`; a binding's
  description is on the binding, so it is replaced with it),
  sets config's choices of completion style (`Registry.styleChoices`),
  sets the registry's leader and localleader to the ones the config set,
  `none` for the scheme's when it set none (`Registry.leader`,
  `Registry.localLeader`), so its bindings written with `<leader>` and
  every mode's suffixes move from the next key, sets the registry's process
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
- **The completion displays follow the registry and config's choices**, as
  the styles do. An install replaces config's displays and sets its
  choices, none for a config that chooses none, so a reload that chooses
  none goes back to the minibuffer display for every prompt. A chosen name
  no display is registered under leaves its category to the default, and
  the default to the minibuffer display, and the report names it
  (`Report.unknownDisplays`), which the echo area says after the styles'
  sentences. The host resolves the choices over the registry for each step
  and for every publish (`Registry.displaying`, `Headless.Running.keys`), so
  the scene the install itself publishes draws an open prompt's list with
  the new config's display. A display runs only inside the publish, on the
  editor thread, and the state keeps only what it answered, so no code of
  the old config runs after the install. A rejected outcome changes none of
  it.
- **The frame padding follows config.** An install sets the padding in
  force (`State.framePadding`) to the one the config set, or none for the
  editor's 8 (`Loop.padding`), so a reload that sets none goes back to it.
  The host hands it to the loop for each step (`Headless.keys`), so it
  changes with no restart. A rejected outcome changes none of it.
- **The key hint delay follows config.** An install sets the delay in
  force (`State.keyHintDelay`) to the one the config set, or none for the
  editor's 500 milliseconds (`Loop.keyHintDelay`), so a reload that sets
  none goes back to it. The host hands it to the loop for each step and
  for the publish after the install (`Headless.Running.keys`), so a reload
  that turns the hints off closes hints that are open. A rejected outcome
  changes none of it.
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
- **An install replaces config's workspace listers**
  (`Registry.workspaceListers`): the next `find-file-in-workspace` lists
  with them (`packages/workspace/Workspace/Lister.lean`). A rejected outcome keeps
  them.
- **An install replaces config's values at every extension point**
  (`Registry.replaceExtensions`), config's compile contributions and
  project commands among them (`packages/compile-api/CompileApi.lean`): a file opened
  after it turns on the modes they give, and the compile mode uses their
  commands at its next use. A rejected outcome changes neither.
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
- **A reload decides about the package set** (`docs/design/packages.md`,
  "User package sets"). Every outcome, accepted or rejected, keeps what the
  reload read of the config as a package set in `State.packageSet`, and
  asks `PackageSet.decide` whether its fingerprint differs from the running
  editor's (`State.packagesAfter`). One that differs, with no build in
  flight, has the effect `buildPackages` after its report, and marks a
  build in flight (`State.packageBuilding`) until the host says it ended
  (`Event.packageBuild`); the host says so too of a build started
  elsewhere (`:package-update`), so a reload starts none while any is in
  flight. What there is to say instead (no `lake`) is the effect `say`,
  once (`State.packagesSaid`). A reload that matches does nothing.

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
  /-- How many files the config that is now installed has. -/
  files : Nat
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
  /-- The completion display names the installed config chose that no
  display is registered under, in order, each once: their categories fall
  to the default, and the default to the minibuffer display. -/
  unknownDisplays : Array String := #[]
  /-- The at-point source names the installed config's uses and the
  registered modes' lists name that no at-point source is registered under,
  in order, each once: they are never asked. -/
  unknownAtPoints : Array String := #[]
  /-- What is said of the base of a child's environment the registry names
  (`Registry.baseName`) when no base answers to it
  (`EnvironmentApi.unknownBase`): children keep the base they had. -/
  unknownBase : Option String := none
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
config named a theme, listed segments or chose completion styles,
displays or a base nobody registered, or made display rules whose targets do not
exist: then `reload: ` and the sentences, `Theme.unknown`'s, then each
`ModeLine.unknown`, then each `Completion.Style.unknown`, then each
`Completion.Display.unknown`, then each `Completion.AtPoint.unknown`, then
the unknown base (`unknownBase`) and then each rule left out
(`unusableRules`), joined by `; `. The whole report is the host's to
print. -/
def Report.echo (report : Report) : Option String :=
  if report.installed then
    let sentences :=
      report.unknownTheme.toArray.map Theme.unknown ++
        report.unknownSegments.map ModeLine.unknown ++
        report.unknownStyles.map Completion.Style.unknown ++
        report.unknownDisplays.map Completion.Display.unknown ++
        report.unknownAtPoints.map Completion.AtPoint.unknown ++
        report.unknownBase.toArray ++
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
structure State (β σ : Type) where
  /-- The base, once a reload has made it: the linked modules config is
  elaborated on, as the last reload left it. -/
  base : Option β := none
  /-- The files of the config that is installed, each with its handle. -/
  files : Array (LoadedFile σ) := #[]
  /-- The commands. -/
  registry : Registry := {}
  /-- The cells of the stores. -/
  cells : Cells := {}
  /-- The cells of config's stores a session restore kept, parked until a
  config installs (`restoreCells`, `install`). -/
  parked : Array KeptCell := #[]
  /-- How many times the cells or the parked ones changed: bumped by
  `written`, `install`, `restoreCells` and a package's registration, so the
  session's reconciler reads them (`keptCells`) only when they moved. -/
  cellsRevision : Nat := 0
  /-- The names of the packages registered, in the order they were
  (`State.register`, `Editor/Config/Packages.lean`): set when a host starts,
  and never by an install. -/
  packages : Array String := #[]
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
  /-- The key hint delay the installed config set (`keyHintDelay`), or none
  for the editor's own (`Loop.keyHintDelay`): set at every install, so a
  config that sets none goes back to it. -/
  keyHintDelay : Option Completion.Keys.Delay := none
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
  /-- What the running editor knows of its own package set
  (`Editor/PackageSet/Running.lean`): set when a host starts, and its
  `facts` set by every reload that finishes to what that reload read. -/
  packageSet : PackageSet.Running := {}
  /-- Whether a package-set build is in flight: set when a reload starts
  one (`buildPackages`), and by `Event.packageBuild` whoever started it. -/
  packageBuilding : Bool := false
  /-- Whether what a reload had to say of the package set instead of
  building it has been said (`say`): it is said once. -/
  packagesSaid : Bool := false

/-- What happened, as far as reloads go. -/
inductive Event (β σ : Type) where
  /-- A reload was asked for. -/
  | requested
  /-- The reload job finished with `outcome`. -/
  | finished (outcome : Outcome β σ)
  /-- The theme called `name` was chosen, by a command, to be the theme in
  force. -/
  | choose (name : String)
  /-- The window opened. Whatever was asked of it before is lost. -/
  | windowOpened
  /-- A package-set build started (`true`) or ended (`false`), whoever
  started it: the host says so as the job keyed `package-build` comes and
  goes. It has no effect. -/
  | packageBuild (inFlight : Bool)

/-- What the runtime is to do. -/
inductive Effect (β σ : Type) where
  /-- Start a reload job: `Config.build` with this base and these loaded
  files, whose outcome comes back as a `finished` event. -/
  | start (base : Option β) (files : Array (LoadedFile σ))
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
  /-- Start the package-set build with this order: the job `package-build`
  (`Editor/PackageSet/Build.lean`), keyed so. -/
  | buildPackages (order : PackageSet.Order)
  /-- Say this in the echo area: what a reload had to say of the package
  set instead of building it. -/
  | say (text : String)

namespace State

variable {β σ : Type}

/-- The state with a reload job started, and the effect that starts it. -/
def start (state : State β σ) : State β σ × Array (Effect β σ) :=
  ({ state with
      running := true, pending := false },
    #[.start state.base state.files])

/-- How many commands the config registers. -/
def commands (state : State β σ) : Nat :=
  (state.registry.entries.filter (·.owner == .config)).size

/-- What the faces look like now: the theme in force (`themeName`), then
the definitions the installed config made, in the order its `setup` made
them. A later definition of a name is over an earlier one, so a face the
config sets takes the config's attributes over the theme's, whichever theme
is in force, and a face it does not set is the theme's. The theme in force
stands in for the built-in theme wholesale: a face it does not define is not
the built-in theme's. A registry that holds no theme of the name in force
draws in the built-in theme. -/
def theme (state : State β σ) : Theme :=
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
def install (state : State β σ) (outcome : Outcome β σ) : State β σ × Report :=
  let state :=
    { state with
      base := outcome.base <|> state.base, running := false, finished := state.finished + 1 }
  match outcome.built with
  | none =>
    (state,
      { number := state.finished, installed := false, diagnostics := outcome.diagnostics,
        files := state.files.size, commands := state.commands })
  | some built =>
    -- A rule whose target the chosen layout lacks is left out, and said.
    let chosen := built.registrations.layout.getD Layout.default
    let checked :=
      built.registrations.displayRules.mapIdx fun index rule =>
        (rule, (rule.target.missing? chosen).map (Report.leftOut (index + 1)))
    let displayRules := (checked.filter (·.2.isNone)).map (·.1)
    let unusableRules := checked.filterMap (·.2)
    let (cells, lost) :=
      state.cells.install .config built.registrations.stores state.parked built.registrations.codecs
    let state :=
      { state with
        files := built.files,
        registry :=
          { state.registry.replaceOwned .config
              built.registrations with
            styleChoices := built.registrations.styleChoices
            displayChoices := built.registrations.displayChoices
            environmentBase := built.registrations.environmentBases.back?
            autoReload := built.registrations.autoReload.back?.getD false
            workspaceRoots := built.registrations.workspaceRoots
            workspaceListers := built.registrations.workspaceListers
            generation := state.registry.generation + 1
            displayRules
            shellTimeLimit := built.registrations.shellTimeLimit
            leader := built.registrations.leader
            localLeader := built.registrations.localLeader
            syntaxRefreshDelay := built.registrations.syntaxRefreshDelay },
        cells, parked := #[], cellsRevision := state.cellsRevision + 1 }
    let (themeName, unknownTheme) :=
      chooseAt state.registry state.themeName built.registrations.theme
    let modeLine := built.registrations.modeLine
    let unknownSegments := (modeLine.map fun order => (state.registry.resolve order).2).getD #[]
    let unknownStyles := state.registry.unknownStyles
    let unknownDisplays := state.registry.unknownDisplays
    let unknownAtPoints := state.registry.unknownAtPoints
    let unknownBase :=
      (EnvironmentApi.ofRegistry state.registry.extensionsAt state.registry.baseName).2
    ({ state with
        themeName, modeLine, framePadding := built.registrations.framePadding
        keyHintDelay := built.registrations.keyHintDelay
        layout := built.registrations.layout, tabBar := built.registrations.tabBar
        titleBar := built.registrations.titleBar },
      { number := state.finished, installed := true, diagnostics := outcome.diagnostics ++ lost,
        files := state.files.size, commands := state.commands, unknownTheme, unknownSegments
        unknownStyles, unknownDisplays, unknownAtPoints, unknownBase, unusableRules })

/-- The appearance the window is to be asked for, and the state that
remembers it: when the window is open and the paper of the theme now in
force (`theme`) classifies as an appearance other than the one last asked,
that one; nothing otherwise. -/
def ask (state : State β σ) : State β σ × Array (Effect β σ) :=
  match state.theme.paper.map Appearance.ofPaper with
  | some appearance =>
    if state.windowOpen && state.appearance != some appearance then
      ({ state with appearance := some appearance }, #[.appearance appearance])
    else (state, #[])
  | none => (state, #[])

/-- The state once a reload that read `facts` of the package set has
finished, and what to do about the set ("A reload decides about the
package set", in the module docs): `PackageSet.decide` over what the running
editor knows, now with `facts`, and whether a build is in flight. -/
def packagesAfter (state : State β σ) (facts : PackageSet.Facts) : State β σ × Array (Effect β σ) :=
  let packageSet := { state.packageSet with facts }
  let state := { state with packageSet }
  match PackageSet.decide packageSet facts state.packageBuilding with
  | .nothing => (state, #[])
  | .say text =>
    if state.packagesSaid then (state, #[]) else ({ state with packagesSaid := true }, #[.say text])
  | .build order => ({ state with packageBuilding := true }, #[.buildPackages order])

end State

/-- The reducer before the window's appearance is asked. -/
private def stepTheme {β σ : Type} (state : State β σ) : Event β σ → State β σ × Array (Effect β σ)
  | .requested => if state.running then ({ state with pending := true }, #[]) else state.start
  | .finished outcome =>
    let (state, report) := state.install outcome
    -- The old config's jobs go when, and only when, the new one is in.
    let installed :=
      if report.installed then #[.cancelJobs .config, .report report] else #[.report report]
    let (state, packages) := state.packagesAfter outcome.facts
    if state.pending then
      let (state, effects) := state.start
      (state, installed ++ packages ++ effects)
    else (state, installed ++ packages)
  | .choose name =>
    if (state.registry.theme? name).isSome then ({ state with themeName := name }, #[.themed])
    else (state, #[])
  | .windowOpened =>
    ({ state with
        windowOpen := true, appearance := none },
      #[])
  | .packageBuild inFlight => ({ state with packageBuilding := inFlight }, #[])

/-- The reducer: the state after `event`, and the effects to perform. The
window's appearance is asked last (`State.ask`), after whatever the event
did to the theme in force. -/
def step {β σ : Type} (state : State β σ) (event : Event β σ) : State β σ × Array (Effect β σ) :=
  let (state, effects) := stepTheme state event
  let (state, asked) := state.ask
  (state, effects ++ asked)

namespace State

variable {β σ : Type}

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
private def overStore? (state : State β σ) (owner : Owner) (store : String)
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
def command? (state : State β σ) (name : String) : Option (Call → EditorM (Option Write)) := do
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
def program? (state : State β σ) (name : String) (target : Option Target := none) :
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
def written (state : State β σ) : Option Write → State β σ
  | none => state
  | some write =>
    { state with
      cells := state.cells.set write.owner write.store write.value
      cellsRevision := state.cellsRevision + 1 }

/-- The state once it takes in the declared stores' cells a session restore
read (`Loop.Stepped.restoredCells`): a package's, which the restore met
with the package's codec, set as the package's cell; config's parked until
a config installs (`install`); any other's dropped, as the restore said. -/
def restoreCells (state : State β σ) (cells : Array KeptCell) : State β σ :=
  if cells.isEmpty then state
  else
    let (held, parked) :=
      cells.foldl
        (fun (held, parked) cell =>
          let owner : Owner := { name := cell.owner }
          if owner == .config then (held, parked.push cell)
          else
            match held.find? owner cell.name with
            | some _ =>
              ({
                  cells :=
                    held.cells.map fun kept =>
                      if kept.owner == owner && kept.name == cell.name then
                        { kept with
                          version := cell.version, value := cell.value }
                      else kept },
                parked)
            | none => (held, parked))
        (state.cells, state.parked)
    { state with
      cells := held, parked, cellsRevision := state.cellsRevision + 1 }

/-- The declared stores' cells kept across a restart, as the session index
lists them: each cell whose store's codec (`Registry.codec?`) is its owner's,
through the codec's `keep`, then the cells parked for config. -/
def keptCells (state : State β σ) : Array KeptCell :=
  let kept :=
    state.cells.cells.filterMap fun cell => do
      let (owner, codec) ← state.registry.codec? cell.name
      if owner != cell.owner then
        none
      let value ← codec.keep cell.value
      return { owner := cell.owner.name, name := cell.name, version := cell.version, value }
  kept ++ state.parked

/-- The job registered under `name`, to be started with `arguments`, and the
owner the runtime is to start it for; `none` if there is no such job. A job
registered over an extension point is made from the values registered there
now (`JobRegistration.workWith`, `Editor/Extension.lean`, "To a job"). -/
def work? (state : State β σ) (name : String) (arguments : List Argument := []) :
    Option (Owner × Work) :=
  (state.registry.findJob? name).map fun entry =>
    (entry.owner, entry.registration.workWith state.registry.extensionsAt arguments)

end State

end Editor.Config
