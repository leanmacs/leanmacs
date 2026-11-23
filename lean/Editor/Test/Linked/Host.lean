import Editor.Clipboard
import Editor.Clipboard.InProcess
import Editor.Completion
import Editor.Config.Directory
import Editor.Config.Elaborate
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Session
import Editor.Ex.Line
import Editor.Face
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Fuzzy
import Editor.Fuzzy.Real
import Editor.Headless
import Editor.Headless.Stepped
import Editor.InputScheme.Test
import Editor.Job.Fake
import Editor.Job.Real
import Editor.Job.Runner
import Editor.Language
import Editor.Loop
import Editor.Mode
import Editor.ModuleLookup
import Editor.Package
import Editor.Process
import Editor.Program
import Editor.Scene
import Editor.Setup
import Editor.State
import Editor.SyntaxTree
import Editor.SyntaxTree.Real
import Editor.Test.Linked.Listings
import Editor.Test.Linked.Services
import Editor.Test.Shipped
import Editor.Text
import Editor.Text.Real
import Editor.Watch

/-!
# The linked test kit: Host

Hosts over the real elaborator: the context a harness of hosts is handed
(`HostContext`: the elaborator, the source ids, the shared table of waits,
the toolchain's directory, the `.olean` directories and the packages its set
hands its editor), a config file's
header, a config held in memory and built once, files written into a
directory, a stage and what compiled code hands it, a host as a check
drives it, stepped or real (`Driven`), a session of a host and what it
printed (`Session`, with `Session.scene` and `Session.shown`, and
`RealSession` for a real host), a host started over a stage or over files,
stepped on the check's thread (`onStage`, `staged`, `withHost`) or on a loop
thread of its own (`onRealStage`, `stagedReal`, `withRealHost`), and the
guard of a check's waits for its host (`hangGuard`, `settled`; `patience`
is the linked kit's, `Editor/Test/Linked/Jobs.lean`). It holds no checks of
its own.

Published for a package's linked tests: it is a module of the core's linked
test kit, a test double in the namespace `Editor.Test.Linked`, which a
package's linked test modules may import and its library may not
(`docs/design/packages.md`, "What a package may import"). It does not import
the config base `Editor`: a host is handed
its packages (`Compiled.packages`), and the harness that runs it imports the
base for the link. The core's config tests (`ConfigTest`) are written on it.
-/

namespace Editor.Test.Linked

open Editor

/-- What a harness of hosts over the real elaborator is handed, and hands
every check: the config tests' `ConfigTest.Context` holds it, and a
package's linked root is handed it too. -/
structure HostContext where
  /-- The real elaborator, whose `base` hands back, and grows, the one base
  the checks share. -/
  elaborator : Config.Elaborator Config.Elaborate.Base Config.Elaborate.Handle
  /-- The next source id no host of this process has posted under. -/
  ids : IO.Ref UInt64
  /-- The table of waits the hosts over the library's file service share,
  once the first of them has asked for it (`HostContext.fileWaits`); none
  until then. -/
  waits : IO.Ref (Option Job.Completions)
  /-- The Lean toolchain's directory, as the executable was handed it. -/
  sysroot : String
  /-- The directories of the `.olean` files the base was imported from, as
  the executable was handed them. -/
  oleanDirs : List System.FilePath
  /-- The packages the set the harness stands for hands its editor: what a
  host made as the executable's are (`withShippedHost`) is handed when a check
  names no others. -/
  packages : Array Package
  /-- How many real editor loop threads the harness's hosts have started: a
  stage's host bumps it on its loop's own thread
  (`Headless.Collaborators.loopStarted`), so a harness that keeps an
  inventory (`ConfigTest.inventory`) names the checks that ran one. -/
  realLoops : IO.Ref Nat

/-- `real` with one base shared by every caller, kept in `latest`: whatever
base a caller hands in, `base` grows the one in `latest` to hold the
modules asked for, keeps it and returns it. A module of the toolchain is
then read once in the process, whichever check first imports it: a second
read of a module file about doubles its memory. A base holds at least what
was asked for, which is all the port says of it. -/
def sharing (latest : IO.Ref (Option Config.Elaborate.Base))
    (real : Config.Elaborator Config.Elaborate.Base Config.Elaborate.Handle) :
    Config.Elaborator Config.Elaborate.Base Config.Elaborate.Handle :=
  { real with
    base := fun _ modules => do
      let base ← real.base (← latest.get) modules
      latest.set (some base)
      return base }

/-- Runs `run` with the context of a harness of hosts over the real
elaborator, as a package's linked test makes it: the elaborator over the
toolchain in `sysroot` and the `.olean` directories `oleanDir` names (one,
or several joined with `:`, as the editor reads its own), on the base
`imports`, `Editor` by default, imported once before `run` and shared by
every host (`sharing`); the module data of the config files the hosts
elaborate in a temporary directory removed when it ends; source ids from
100; and `packages` as the set's. -/
def HostContext.run {α : Type} (sysroot oleanDir : String) (packages : Array Package)
    (run : HostContext → IO α) (imports : Array Lean.Name := #[`Editor]) : IO α :=
  IO.FS.withTempDir fun scratch => do
    let files ← Config.Elaborate.ModuleFiles.over (pure scratch)
    let oleanDirs := (ModuleLookup.searchPath oleanDir).map System.FilePath.mk
    let elaborator :=
      sharing (← IO.mkRef none) (Config.Elaborate.elaborator { sysroot, oleanDirs, imports } files)
    discard <| elaborator.base none #[]
    run { elaborator, ids := ← IO.mkRef 100, waits := ← IO.mkRef none, sysroot, oleanDirs
          packages, realLoops := ← IO.mkRef 0 }

/-- The table of waits every host over the library's file service is staged
over, with the process's one completion pump running over it. It is made,
and the pump started on a dedicated task, the first time it is asked for,
and handed back as it is afterwards: a second pump would take the first
one's completions, so the checks of files share one table and one pump.
The executable exits explicitly, which a pump parked in its pull needs. -/
def HostContext.fileWaits (context : HostContext) : IO Job.Completions := do
  if let some completions← context.waits.get then
    return completions
  let completions ← Job.Completions.new
  discard <| IO.asTask (prio := .dedicated) (Job.pump completions)
  context.waits.set (some completions)
  return completions

/-- What a config file starts with: the import of the editor's base, and
the `open` that lets it name the base's declarations with no prefix. -/
def configHeader : String :=
  "import Editor\nopen Editor\n"

/-- The text of a config file that imports `imports` beside the editor's
base, opens `Editor`, and goes on with `body`: what a file that imports
config files or other modules starts with. -/
def importing (imports : List String) (body : String) : String :=
  "import Editor\n" ++ String.join (imports.map fun module => s!"import {module}\n") ++
    "open Editor\n" ++
    body

/-- The text a check's config file is written with: `text` itself when it
writes its own header, which is when one of its lines starts with
`import`, and otherwise the standard header (`configHeader`) and then
`text`, so that a line of `text` is two lines further down in the file. -/
def headed (text : String) : String :=
  if (text.splitOn "\n").any (·.startsWith "import ") then text else configHeader ++ text

/-- The config files of the config directory `directory`, each with its
path below the directory and its text: the root, and every file under
`Config/`, in the byte order of their paths. -/
partial def configFiles (directory : System.FilePath) : IO (List (String × String)) := do
  let rec walk (below : String) : IO (List (String × String)) := do
    let entries ← (directory / below).readDir
    let names := (entries.map (·.fileName)).qsort (· < ·)
    let mut found := []
    for name in names do
      let path := s!"{below}/{name}"
      if ← (directory / path).isDir then
        found := found ++ (← walk path)
      else if name.endsWith ".lean" then
        found := found ++ [(path, ← IO.FS.readFile (directory / path))]
    return found
  let root := directory / Config.rootPath
  let rootFile ←
    if ← root.pathExists then
      pure [(Config.rootPath, ← IO.FS.readFile root)]
    else
      pure []
  let under ←
    if ← (directory / "Config").isDir then
      walk "Config"
    else
      pure []
  return rootFile ++ under

/-- A source over the files `files` gives each time it is asked, each a
module name and a text, as they are: the root is the module `init`, a
config file is found by exactly its module name, and nothing is stray. -/
def sourceOver (files : IO (List (String × String))) : Config.Source :=
  let find (module : String) : IO (Option Config.SourceFile) := do
    return ((← files).find? (·.1 == module)).map fun (_, text) =>
        { module,
          path := if module == Config.rootModule then Config.rootPath else Config.pathOf module
          text }
  { root := find Config.rootModule,
    file := fun module => do
      match ← find module with
      | some file =>
        return .found file
      | none =>
        return .absent,
    stray := pure #[] }

/-- A source over `files` held in memory, each a module name and a text,
which is headed as a file a check writes is (`headed`): the root is the
module `init`, and nothing is stray. -/
def memorySource (files : List (String × String)) : Config.Source :=
  sourceOver (pure (files.map fun (module, text) => (module, headed text)))

/-- One reload of the config `files` hold in memory (`memorySource`), on
the real elaborator and the base the checks share, with nothing loaded and
no package port. -/
def buildConfig (context : HostContext) (files : List (String × String)) :
    IO (Config.Outcome Config.Elaborate.Base Config.Elaborate.Handle) :=
  Config.build TestScheme.scheme context.elaborator (memorySource files) Config.PackageFiles.none
    none none #[]

/-- Writes each of `files`, a path below `directory` and a text, as it is,
making the directories on the way. -/
def writeFiles (directory : System.FilePath) (files : List (String × String)) : IO Unit :=
  for (path, text) in files do
    let file := directory / path
    if let some parent := file.parent then
      IO.FS.createDirAll parent
    IO.FS.writeFile file text

/-- Writes each of `files`, a path below `directory` and a text, as a
config file: with its header (`headed`). -/
def writeConfig (directory : System.FilePath) (files : List (String × String)) : IO Unit :=
  writeFiles directory (files.map fun (path, text) => (path, headed text))

/-- The guard of the event each of a check's waits ends on (its host's
answer, a reload's or a job's end, idle, a promise a hold resolves); only a
hang reaches it, and the check then fails as a hang.

The guard of a check's waits for its host (`Headless.Host.waitWhile`), its
brackets and its `Job.awaitWithin`s: only a real hang
trips it, even under heavy load. A check that
reaches it fails, reported as a hang, never as a timing result; a check
that pins a bound of the headless mode on purpose holds a reload or the
editor thread for good and gives a short guard of its own.

Set from a measurement: ten times the slowest check of config-test under
the stress loop's load on each platform, rounded up to the next ten
seconds. A check's wall time, which `config-test --timings` writes for each
check, bounds any one wait in it. Measured on 2026-11-22 and 2026-11-23
(`docs/dev-practices/on-demand-checks.md`, "The load on Linux"), the
slowest check of a round, on every platform "the real elaborator: a handle
is one version of a file…":

- macOS, 18 cores under 36 hogs, `taskpolicy -c utility`, 40 rounds: at
  most 13 216 ms.
- The Linux container, aarch64, 8 CPUs under 16 hogs, `nice -n 5`, 40
  rounds: at most 10 448 ms.
- `ubuntu-24.04`, the CI runner, under `2 x nproc` hogs, `nice -n 5`, the 50
  rounds of stress run 45097785021: 16 053 to 25 080 ms.

Ten times 25 080 ms, rounded up, is 260 000 ms. It was 120 000 ms, then
130 000 ms, while only the first two had been measured. -/
def hangGuard : HangGuard :=
  .on "the event the check's wait ends on" 260000

/-- A guard of 0 ms run out on purpose: what the check holds for good (a
reload, the editor thread, the loop's end), so the hang is said at once and
is what lets it go. -/
def heldAtOnce : HangGuard :=
  .held "what the check holds for good, whose hang is said at once" 0

/-- A short guard run out on purpose: a check that pins a bound of the
headless mode holds a reload or the editor thread for good, and its wait
runs out after 200 ms. -/
def heldShort : HangGuard :=
  .held "the reload or the editor thread the check holds for good" 200

/-- Waits until the fake clock `clock` has reached `arrival`
(`Job.FakeClock.arrivedAt`): on the step that makes it, on whichever thread
takes it, never by a poll of the readout. Whether it came before
`hangGuard`, which only a hang reaches. -/
def clockReaches (clock : Job.FakeClock) (arrival : Job.FakeClockArrival) : IO Bool := do
  let reached ← clock.arrivedAt arrival
  return (← Job.awaitWithin hangGuard reached.result?).isSome

/-- What a check hands a host of its own: the collaborators, and what the
check keeps of them. The host's output goes to a buffer, with the thread
that emitted each line; its jobs wait on a fake clock the check moves; and it
posts under source ids no other host of this process has. Its input scheme
is the test scheme, so no check names a shipped scheme's keys.

Its loop's end waits for the jobs it cancels (`Collaborators.endCancelled`):
a cancelled job ends on a pool thread and then posts its wake-up, and a real
host's queue is the library's, which the next check's host shares, so a
wake-up that came after the host's bracket had returned would be handled,
and publish a scene, in a later check. The bound is `hangGuard`: past it
the loop's end throws a hang. -/
structure Stage (β σ : Type) where
  /-- What the host is started with. -/
  collaborators : Headless.Collaborators β σ TestScheme.scheme
  /-- Every line the host has emitted, oldest first. -/
  output : IO.Ref (Array String)
  /-- The thread that emitted each line of `output`. -/
  threads : IO.Ref (Array UInt64)
  /-- What checks wait for the output to come to (`Session.outputReaches`):
  each a test of the whole output and the promise the emit resolves once
  the test holds, after the line that makes it is in `output`. -/
  outputWaits : IO.Ref (Array ((Array String → Bool) × IO.Promise Unit))
  /-- The clock the host's jobs wait on, and the loop times a command on. -/
  clock : Job.FakeClock
  /-- The watch service the host's jobs watch through: a fake over a model
  whose one directory is the made-up `/watched`. -/
  watches : Job.FakeFileWatches
  /-- Every entry the host has logged, oldest first. -/
  log : IO.Ref (Array String)
  /-- One entry for each time the host's collaborators were disposed of
  (`Headless.Collaborators.dispose`): how many lines the host had emitted
  by then. -/
  disposed : IO.Ref (Array Nat)
  /-- The memory queue a stepped host over the stage drains
  (`Headless.withStepped`), which a poster built before the host can post
  to; a real host leaves it unused, its collaborators' queue being the
  library's. -/
  memory : Headless.Queue.Memory Ffi.Event

/-- What a check hands a host to register before any config: packages, and
registrations written as arrays, its commands, its jobs, its key
bindings, its modes, its ex bindings, its themes, its languages, its completion sources, which the
host is handed as the package `test` (`Compiled.package`); and how long
a command may take before it is logged, and the major mode the scratch buffer starts in. -/
structure Compiled where
  /-- The packages the host is handed, in order, before the package `test`
  of the arrays below. -/
  packages : Array Package := #[]
  /-- The compiled commands. -/
  commands : Array Config.Registration := #[]
  /-- The compiled jobs. -/
  jobs : Array Config.JobRegistration := #[]
  /-- The compiled key bindings. -/
  bindings : Array Config.KeyBinding := #[]
  /-- The compiled modes. -/
  modes : Array Mode := #[]
  /-- The compiled ex bindings. -/
  ex : Array Ex.Binding := #[]
  /-- The compiled themes. -/
  themes : Array NamedTheme := #[]
  /-- The compiled languages. -/
  languages : Array Language := #[]
  /-- The compiled completion sources. -/
  sources : Array Completion.Source := #[]
  /-- The package's style for a category, each a category and a style's
  name (`useStyleFor` in a package). -/
  styleDefaults : Array (String × String) := #[]
  /-- How long a command may take before it is logged, in milliseconds. -/
  slowAfter : Nat := Loop.slowAfter
  /-- The major mode the scratch buffer starts in, if any: the host's frame
  is made with it set, so the mode's keys hold from the first key and no
  on-enter action runs. -/
  major : Option String := none

/-- The name of the package a stage makes of a `Compiled`'s arrays. -/
def Compiled.packageName : String :=
  "test"

/-- The arrays of `compiled` as one package, `test`, which replays each
through the setup port: its commands, jobs, key bindings, modes, ex
bindings, themes, languages, completion sources and style defaults. One
`setup` registers a name once, so a check that hands a host two
registrations of one name hands them in two packages
(`Compiled.packages`). -/
def Compiled.package (compiled : Compiled) : Package :=
  { name := Compiled.packageName
    setup := do
      for registration in compiled.commands do
        match registration.action with
        | .plain run =>
          command registration.name run
        | .call run =>
          commandWith registration.name run
        | .store store step =>
          ExceptT.lift
              (Program.request (port := setupPort) (.storeCommand registration.name store step))
      for job in compiled.jobs do
        workJob job.name job.work
      for binding in compiled.bindings do
        ExceptT.lift
            (Program.request (port := setupPort)
              (.bind binding.keys binding.command binding.states binding.desc binding.category))
      for mode in compiled.modes do
        defineMode mode
      for binding in compiled.ex do
        ExceptT.lift (Program.request (port := setupPort) (.ex binding))
      for named in compiled.themes do
        defineTheme named.name named.theme
      for language in compiled.languages do
        defineLanguage language
      for source in compiled.sources do
        defineSource source
      for (category, name) in compiled.styleDefaults do
        useStyleFor category name }

/-- A stage for a host over `elaborator` and `source`, with what `compiled`
hands it: the package `listings`, so every stage's host has a style and a
display written for these tests (`Editor/Test/Linked/Listings.lean`), and
the package `mode-line`, so it has the shipped segments, then
`compiled.packages`,
then the package `test` of its arrays (`Compiled.package`). A `compiled`
whose arrays one `setup` would refuse fails the stage, naming why: such a
host would start without them. Hosts follow one another on one queue: each gets source ids of its
own, so none takes a late event of an earlier one for its own. A real loop
over it counts itself in `HostContext.realLoops` as it starts
(`Headless.Collaborators.loopStarted`). Its jobs wait
in a table of waits of its own, unless it is handed one (`waits`), as a
stage over a real service is. Its jobs ask the library's matcher
(`Fuzzy.real`), as the executable's do, unless it is handed another
(`fuzzy`). -/
def Stage.new {β σ : Type} (context : HostContext) (elaborator : Config.Elaborator β σ)
    (source : Config.Source) (compiled : Compiled := {}) (waits : Option Job.Completions := none)
    (fuzzy : FuzzyHandler := Fuzzy.real) : IO (Stage β σ) := do
  if let .error reason := compiled.package.collected then
    throw (IO.userError s!"the stage's registrations are refused: {reason}")
  let output ← IO.mkRef #[]
  let threads ← IO.mkRef #[]
  let outputWaits : IO.Ref (Array ((Array String → Bool) × IO.Promise Unit)) ← IO.mkRef #[]
  let log ← IO.mkRef #[]
  let disposed ← IO.mkRef #[]
  let completions ←
    match waits with
    | some completions =>
      pure completions
    | none =>
      Job.Completions.new
  let clock ← Job.FakeClock.new completions
  let watches ← Job.FakeFileWatches.new completions { directories := #["/watched"] }
  let published ← Snapshots.new
  let requests ← context.ids.modifyGet fun next => (next, next + 6)
  return {
      collaborators :=
        { elaborator, source,
          emit := fun line => do
            threads.modify (·.push (← IO.getTID))
            let lines ← output.modifyGet fun lines => (lines.push line, lines.push line)
            -- After the line is in `output`: a wait armed later reads it.
            let reached ←
              outputWaits.modifyGet fun waits =>
                  (waits.filter (·.1 lines), waits.filter (!·.1 lines))
            for (_, promise) in reached do
              promise.resolve (),
          services :=
            { completions, timers := clock.timers, fileWatches := watches.fileWatches, fuzzy
              snapshots := Job.realSnapshots published.reader }
          published, held := ← Job.HeldSnapshots.new, requests, wakeups := requests + 1,
          jobs := requests + 2, environment := requests + 3
          posts := requests + 4, pauseEvents := requests + 5
          packages :=
            #[listingsPackage, Test.Shipped.modeLine] ++ compiled.packages ++ #[compiled.package]
          log := fun entry => log.modify (·.push entry), slowAfter := compiled.slowAfter
          dispose := do
            let emitted := (← output.get).size
            disposed.modify (·.push emitted)
          clock := some clock, tracksIdle := true
          endCancelled := fun cancelled => do
            for job in cancelled do
              -- hang guard: the runner's last step for a job the loop's end
              -- cancelled; only a hang reaches the bound, and the loop's end
              -- then fails as a hang.
              unless (← Job.awaitWithin hangGuard job).isSome do
                throw <|
                    IO.userError
                      s!"a hang: a job the loop's end cancelled had not ended within {hangGuard.ms} ms"
          loopStarted := context.realLoops.modify (· + 1)
          start := do
            let loop ← Loop.start TestScheme.scheme ⟨0, 0⟩
            match compiled.major with
            | some name =>
              return { loop with state := (loop.state.setMajorMode ⟨0⟩ name).2 }
            | none =>
              return loop },
      output, threads, outputWaits, clock, watches, log, disposed
      memory := ← Headless.Queue.Memory.new }

/-- A host as a check drives it, whichever kind it is: a real one, whose loop
runs on a thread of its own (`Headless.Host`, `Driven.ofHost`), or one
stepped on the check's own thread (`Headless.Stepped`, `Driven.ofStepped`).
Each field is a closure over the host, so a check written on it runs on
either. Nothing but checks drives two kinds of host, so it is test support,
not the core's. -/
structure Driven where
  /-- Asks the host to do a request, after everything asked before. -/
  send : Headless.Request → IO Unit
  /-- Sends an event as the window would report it. -/
  input : Event → IO Unit
  /-- The host's `waitWhile` (`Headless.Host.waitWhile`,
  `Headless.Stepped.waitWhile`): its guard, the kind of wait
  (`Headless.Wait.Kind`), the answer's guard, the script's line, where a
  hang is said, and what is called before a block. What each kind waits
  for is the core's, never this record's. -/
  waitWhile :
    HangGuard →
      Headless.Wait.Kind →
      HangGuard → Option Nat → (String → IO Unit) → (String → IO Unit) → IO Headless.Wait
  /-- The host's activity count and its epoch, read in one step. -/
  activitySeen : BaseIO Job.Activity.Seen
  /-- How far the host's loop has got, as it published after its last
  event. -/
  progress : IO Headless.Progress
  /-- How the host's loop ended, once it has: `ok` for a loop that stopped
  by itself or was stopped, or the error it threw. -/
  ended? : IO (Option (Except IO.Error Unit))
  /-- The fake clock the host's jobs wait on, if they wait on one. -/
  clock : Option Job.FakeClock

namespace Driven

/-- A real host, driven. -/
def ofHost (host : Headless.Host) : Driven where
  send := host.send
  input event := do
    unless ← Event.post event do
      throw (IO.userError "the editor queue refused an event: it has been quit")
  waitWhile guard kind answer line waitHung waitBlocked :=
    host.waitWhile guard kind answer line waitHung waitBlocked
  activitySeen := host.activitySeen
  progress := host.progress.get
  ended? := do
    if ← IO.hasFinished host.thread then
      return some host.thread.get
    return none
  clock := host.clock

/-- A stepped host, driven. -/
def ofStepped (stepped : Headless.Stepped) : Driven where
  send := stepped.send
  input := stepped.input
  waitWhile guard kind answer line waitHung waitBlocked :=
    stepped.waitWhile guard kind answer line waitHung waitBlocked
  activitySeen := stepped.activitySeen
  progress := stepped.progress
  ended? := stepped.ended?
  clock := stepped.clock

/-- Sends a press of `key`, with no text, as the window would report it. -/
def press (driven : Driven) (key : Key) : IO Unit :=
  driven.input (.key key true "")

/-- Sends `text` as an input method's composition would end with it. -/
def commit (driven : Driven) (text : String) : IO Unit :=
  driven.input (.commit text)

/-- Sends a resize of the frame to `width` by `height` physical pixels, at a
scale of 1 and out of fullscreen. -/
def resize (driven : Driven) (width height : Nat) : IO Unit :=
  driven.input (.resize { width, height, scale := 1.0 })

/-- `Headless.Host.await` on the driven host: a `settle`'s wait
(`Headless.Wait.Kind.settle`).
 -/
def await (driven : Driven) (waitGuard : HangGuard) (answer : HangGuard := waitGuard)
    (line : Option Nat := none) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Headless.Wait :=
  driven.waitWhile waitGuard .settle answer line waitHung waitBlocked

/-- `Headless.Host.join` on the driven host: a `join`'s wait
(`Headless.Wait.Kind.join`).
 -/
def join (driven : Driven) (waitGuard : HangGuard) (answer : HangGuard := waitGuard)
    (line : Option Nat := none) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Headless.Wait :=
  driven.waitWhile waitGuard .join answer line waitHung waitBlocked

/-- `Headless.Host.settle` on the driven host.
 -/
def settle (driven : Driven) (waitGuard : HangGuard) (answer : HangGuard := waitGuard)
    (line : Option Nat := none) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Bool :=
  return (← driven.await waitGuard answer line waitHung waitBlocked) == .settled

/-- A wait only until the host has handled everything sent so far
(`Headless.Wait.Kind.handled`), publishing nothing.
 -/
def handled (driven : Driven) (waitGuard : HangGuard) : IO Headless.Wait :=
  driven.waitWhile waitGuard .handled waitGuard none IO.eprintln fun _ => pure ()

/-- A `join`'s wait that publishes nothing (its marker is a probe): what
replaces a poll for a state the host reaches by itself, such as a job in
its sleep, so the scene count stays the poll's.
 -/
def idle (driven : Driven) (waitGuard : HangGuard) : IO Headless.Wait :=
  driven.waitWhile waitGuard { Headless.Wait.Kind.join with marker := false } waitGuard none
    IO.eprintln fun _ => pure ()

/-- A wait until the host is idle (`docs/design/concurrency.md`, "The idle
signal": everything sent handled, nothing that can end by itself running,
no fake-clock wait due), publishing nothing: what it waits for always
holds, so it answers only at idle, `settled`. What replaces a poll for a
state work reaches by itself after the jobs table has let it go, such as a
cancelled job's end. -/
def quiet (driven : Driven) (waitGuard : HangGuard) : IO Headless.Wait :=
  driven.waitWhile waitGuard
    { what := "idle", busy := fun _ => pure true, still := some .settled, hung := .busy
      marker := false } waitGuard none IO.eprintln fun _ => pure ()

end Driven

/-- A real host is driven as `Driven.ofHost` drives it, so a helper written
on `Driven` takes either. -/
instance : Coe Headless.Host Driven :=
  ⟨Driven.ofHost⟩

/-- A host running for one check, stepped or real (`drive`), the real text
binding, and a config directory the check owns. -/
structure Session where
  /-- The host, as the check drives it. -/
  drive : Driven
  /-- The config directory: a temporary directory of this check's. -/
  directory : System.FilePath
  /-- Every line the host has emitted, oldest first. -/
  output : IO.Ref (Array String)
  /-- The thread that emitted each line of `output`. -/
  threads : IO.Ref (Array UInt64)
  /-- What the check waits for the output to come to (`Stage.outputWaits`). -/
  outputWaits : IO.Ref (Array ((Array String → Bool) × IO.Promise Unit))
  /-- The clock the host's jobs wait on, which the check moves. -/
  clock : Job.FakeClock
  /-- The watch service the host's jobs watch through, which the check
  tells of changes. -/
  watches : Job.FakeFileWatches
  /-- Every entry the host has logged, oldest first. -/
  log : IO.Ref (Array String)
  /-- Where the check's waits for the host say a hang (`Driven.waitWhile`):
  stderr unless the check counts them. -/
  waitHung : String → IO Unit := IO.eprintln
  /-- What the check's waits for the host call as they are about to block
  (`Driven.waitWhile`): nothing unless the check lets a held step go on
  it. -/
  waitBlocked : String → IO Unit := fun _ => pure ()

/-- A session over a real host, whose loop runs on a thread of its own: the
session, and the host itself, for a check of what only a loop thread shows
(`docs/dev-practices/real-thread-checks.md`). -/
structure RealSession extends Session where
  /-- The real host. -/
  host : Headless.Host

/-- A real host's session is a session, as its parent: a helper written on
`Session` takes either. -/
instance : Coe RealSession Session :=
  ⟨RealSession.toSession⟩

/-- The session of the host `drive` over `stage`, with the config directory
`directory`. -/
def Session.ofStage {β σ : Type} (drive : Driven) (directory : System.FilePath) (stage : Stage β σ)
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : Session :=
  { drive, directory, output := stage.output, threads := stage.threads
    outputWaits := stage.outputWaits, clock := stage.clock, watches := stage.watches
    log := stage.log, waitHung, waitBlocked }

/-- The session of the real host `host` over `stage`. -/
def RealSession.ofStage {β σ : Type} (host : Headless.Host) (directory : System.FilePath)
    (stage : Stage β σ) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : RealSession :=
  { Session.ofStage host directory stage waitHung waitBlocked with host }

/-- What a check says of a driven host's loop when it ended before what was
sent to it settled (`Headless.Wait.ended`): that it ended, and what it ended
with, the error it threw or a quit. Not a hang: nothing was waited for in
vain. -/
def loopEnded (drive : Driven) : IO String := do
  let how :=
    match ← drive.ended? with
    | some (.error error) => s!"it threw: {error}"
    | _ => "it ended by itself, as a quit ends it"
  return s!"the editor loop ended before the requests sent to it settled: {how}"

/-- Waits until `drive`'s loop has handled everything sent so far and no
reload is running: for the reload's end, however long a real elaboration
takes, with `hangGuard` as a guard against a hang only. `true` once it has;
`false` at a guard, the hang said once through `waitHung`. Throws when the
loop ended first (`loopEnded`), with what it ended with: a loop that ended
is not a hang. -/
def settled (drive : Driven) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Bool := do
  match ← drive.await hangGuard (waitHung := waitHung) (waitBlocked := waitBlocked) with
  | .settled =>
    return true
  | .ended =>
    throw (IO.userError (← loopEnded drive))
  | _ =>
    return false

namespace Session

/-- Sends `requests` to the host in order, and waits until it has handled
them and no reload is running (`settled`): for the reload's end, with the
session's `waitHung` and `waitBlocked`. Throws a hang if the wait reaches
`hangGuard`, and says the loop ended, with what it ended with, if it ended
first. -/
def ask (session : Session) (requests : List Headless.Request) : IO Unit := do
  for request in requests do
    session.drive.send request
  unless ← settled session.drive session.waitHung session.waitBlocked do
    throw (IO.userError s!"a hang: the editor thread had not settled within {hangGuard.ms} ms")

/-- Asks the host to do `request`, after everything asked before, and does
not wait. -/
def send (session : Session) (request : Headless.Request) : IO Unit :=
  session.drive.send request

/-- Sends a press of `key`, as the window would report it. -/
def press (session : Session) (key : Key) : IO Unit :=
  session.drive.press key

/-- Sends `text` as an input method's composition would end with it. -/
def commit (session : Session) (text : String) : IO Unit :=
  session.drive.commit text

/-- Sends a resize of the frame to `width` by `height`. -/
def resize (session : Session) (width height : Nat) : IO Unit :=
  session.drive.resize width height

/-- Waits until the host has handled everything sent so far and no reload
is running, with `hangGuard` and the session's `waitHung` and
`waitBlocked`: whether it did. -/
def settle (session : Session) : IO Bool :=
  session.drive.settle hangGuard (waitHung := session.waitHung) (waitBlocked := session.waitBlocked)

/-- `join` with `hangGuard` that publishes nothing (`Driven.idle`): what a
check waits on in place of a poll for a job in its sleep. -/
def idle (session : Session) : IO Headless.Wait :=
  session.drive.idle hangGuard

/-- Waits until the host is idle, with `hangGuard`, publishing nothing
(`Driven.quiet`): whether it came to idle. -/
def quiet (session : Session) : IO Bool :=
  return (← session.drive.quiet hangGuard) == .settled

/-- Waits until the host has handled everything sent so far, with
`hangGuard`, and publishes nothing (`Driven.handled`): whether it did. -/
def handled (session : Session) : IO Bool :=
  return (← session.drive.handled hangGuard) == .settled

/-- Waits until the host has handled everything sent so far and no job is
running, with `hangGuard` and the session's `waitHung` and `waitBlocked`:
`settled`, `working` at idle with a job still running, or a hang. -/
def join (session : Session) : IO Headless.Wait :=
  session.drive.join hangGuard (waitHung := session.waitHung) (waitBlocked := session.waitBlocked)

/-- Replaces the text of the config file at `path` below the config
directory, or adds it, with its header (`headed`). -/
def write (session : Session) (path text : String) : IO Unit :=
  writeConfig session.directory [(path, text)]

/-- A line as a check compares it. A diagnostic's position and message are
Lean's, so a diagnostic line is cut down to its source and its severity;
every other line is kept whole. -/
def comparable (line : String) : String :=
  match line.splitOn ": " with
  | "diagnostic" :: place :: severity :: _ =>
    s!"diagnostic: {(place.splitOn ":").headD ""}: {severity}"
  | _ => line

/-- Every line the host has emitted, as a check compares them. -/
def lines (session : Session) : IO (Array String) :=
  return (← session.output.get).map comparable

end Session

/-- The number of events the library's editor queue holds, before and after
`body`: a stepped host's check must leave none there, where the next real
host would take them. Throws, naming them, when the queue grew, and takes
every event the queue held off it, so no later host takes them. -/
def leavingLibraryQueue {α : Type} (body : IO α) : IO α := do
  let before ← Ffi.queued .editor
  let result ← body
  let after ← Ffi.queued .editor
  if after > before then
    -- Taken off the queue, so the failure says what they were and no later
    -- host takes them; `takeQueued` never parks.
    let mut held := #[]
    for _ in [0:after.toNat] do
      let some event ← Ffi.takeQueued .editor | break
      held :=
        held.push
          s!"{repr event.source.kind} {event.source.id} {repr event.kind} {event.code} {event.text.quote}"
    throw <|
        IO.userError
          s!"a stepped host's check posted to the library's editor queue: it held {before} events and then {after}: {held}"
  return result

/-- Runs `check` against a host stepped on the check's own thread over
`collaborators` and the memory queue `memory` (`Headless.withStepped`),
which returns only once the host's loop has ended, whether the check
returned or threw. `false` if the check did not hold or the host did not
settle after it, `hangGuard` its guard against a hang (`waitHung`,
`waitBlocked`). It also fails the check if the library's editor queue grew
across it (`leavingLibraryQueue`). -/
def stepping {β σ : Type} {scheme : InputScheme} (collaborators : Headless.Collaborators β σ scheme)
    (memory : Headless.Queue.Memory Ffi.Event) (check : Driven → IO Bool)
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Bool :=
  leavingLibraryQueue <|
    Headless.withStepped collaborators memory (guard := hangGuard) (grace := some hangGuard)
      fun stepped => do
      let drive := Driven.ofStepped stepped
      let held ← check drive
      let wait ← drive.await hangGuard (waitHung := waitHung) (waitBlocked := waitBlocked)
      return held && (wait == .settled || wait == .ended)

/-- Runs `check` against a real host over `collaborators`, inside the host's
bracket (`Headless.withHost`), which returns only once the host's loop has
ended, whether the check returned or threw. `false` if the check did not
hold or the host did not settle after it, for the reload's end, `hangGuard`
its guard against a hang (`waitHung`, `waitBlocked`). -/
def hostingReal {β σ : Type} {scheme : InputScheme}
    (collaborators : Headless.Collaborators β σ scheme) (check : Headless.Host → IO Bool)
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Bool :=
  -- A loop not ended `hangGuard` after its hang was said is given up on,
  -- and the check fails as a hang: the suite always finishes.
  Headless.withHost collaborators (guard := hangGuard) (grace := some hangGuard) fun host => do
    let held ← check host
    let wait ← host.await hangGuard (waitHung := waitHung) (waitBlocked := waitBlocked)
    return held && (wait == .settled || wait == .ended)

/-- Runs `body` against a host over `stage` stepped on the check's own
thread (`Headless.withStepped`, over the stage's memory queue), driven, and
fails it if the library's editor queue grew across it
(`leavingLibraryQueue`): for a check that drives its host itself, in place
of `Headless.withHost`. -/
def onSteppedStage {α β σ : Type} (stage : Stage β σ) (body : Driven → IO α) : IO α :=
  leavingLibraryQueue <|
    Headless.withStepped stage.collaborators stage.memory (guard := hangGuard) (grace :=
      some hangGuard) fun stepped => body (Driven.ofStepped stepped)

/-- Runs `check` against a host started on `stage`, stepped on the check's
own thread (`stepping`, over the stage's memory queue). -/
def onStage {β σ : Type} (stage : Stage β σ) (check : Driven → Stage β σ → IO Bool)
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Bool :=
  stepping stage.collaborators stage.memory (fun drive => check drive stage) waitHung waitBlocked

/-- Runs `check` against a real host started on `stage` (`hostingReal`). -/
def onRealStage {β σ : Type} (stage : Stage β σ) (check : Headless.Host → Stage β σ → IO Bool)
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Bool :=
  hostingReal stage.collaborators (fun host => check host stage) waitHung waitBlocked

/-- Runs `check` against a stepped host started on a stage of its own over
`elaborator` and `source`, with what `compiled` hands it. `false` if the
check did not hold or the host did not settle. -/
def staged {β σ : Type} (context : HostContext) (elaborator : Config.Elaborator β σ)
    (source : Config.Source) (check : Driven → Stage β σ → IO Bool) (compiled : Compiled := {})
    (fuzzy : FuzzyHandler := Fuzzy.real) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Bool := do
  onStage (← Stage.new context elaborator source compiled (fuzzy := fuzzy)) check waitHung
      waitBlocked

/-- `staged` with a real host (`onRealStage`). -/
def stagedReal {β σ : Type} (context : HostContext) (elaborator : Config.Elaborator β σ)
    (source : Config.Source) (check : Headless.Host → Stage β σ → IO Bool)
    (compiled : Compiled := {}) (fuzzy : FuzzyHandler := Fuzzy.real)
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Bool := do
  onRealStage (← Stage.new context elaborator source compiled (fuzzy := fuzzy)) check waitHung
      waitBlocked

/-- Runs `check` against a stepped host started on a fresh temporary
directory holding `files`. The host's elaborator is `around` the real one
and its source `through` the directory's: a check that controls elaboration
or counts reads passes a decorator. The directory is removed. -/
def withHostOver (context : HostContext) (files : List (String × String))
    (around :
      Config.Elaborator Config.Elaborate.Base Config.Elaborate.Handle →
        Config.Elaborator Config.Elaborate.Base Config.Elaborate.Handle)
    (through : Config.Source → Config.Source) (check : Session → IO Bool)
    (compiled : Compiled := {}) (fuzzy : FuzzyHandler := Fuzzy.real)
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeConfig directory files
    staged context (around context.elaborator) (through (Config.Directory.source directory))
        (fun drive stage => check (Session.ofStage drive directory stage waitHung waitBlocked))
        compiled fuzzy waitHung waitBlocked

/-- `withHostOver` with a real host (`stagedReal`). -/
def withRealHostOver (context : HostContext) (files : List (String × String))
    (around :
      Config.Elaborator Config.Elaborate.Base Config.Elaborate.Handle →
        Config.Elaborator Config.Elaborate.Base Config.Elaborate.Handle)
    (through : Config.Source → Config.Source) (check : RealSession → IO Bool)
    (compiled : Compiled := {}) (fuzzy : FuzzyHandler := Fuzzy.real)
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeConfig directory files
    stagedReal context (around context.elaborator) (through (Config.Directory.source directory))
        (fun host stage => check (RealSession.ofStage host directory stage waitHung waitBlocked))
        compiled fuzzy waitHung waitBlocked

/-- Runs `check` against a stepped host started on a fresh temporary
directory holding `files`, with the real elaborator. `false` if the check
did not hold or the host did not settle. The directory is removed. Its jobs
ask `fuzzy` for the matcher, the library's unless a check holds it. -/
def withHost (context : HostContext) (files : List (String × String)) (check : Session → IO Bool)
    (compiled : Compiled := {}) (fuzzy : FuzzyHandler := Fuzzy.real)
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Bool :=
  withHostOver context files id id check compiled fuzzy waitHung waitBlocked

/-- `withHost` with a real host (`withRealHostOver`). -/
def withRealHost (context : HostContext) (files : List (String × String))
    (check : RealSession → IO Bool) (compiled : Compiled := {}) (fuzzy : FuzzyHandler := Fuzzy.real)
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Bool :=
  withRealHostOver context files id id check compiled fuzzy waitHung waitBlocked

/-- Runs `body` in a fresh temporary directory, removed only once the
library's services among `targets` have worked what was handed to them under
it (`Editor.Test.Linked.withFiles`): the file service unless a check names
others. The flushes go through the table of waits the checks of files share
(`HostContext.fileWaits`), whose pump runs, over services made of it here
(`Linked.Services.over`): refs and no threads, and the library's services
are process-wide, so a flush through them covers every check's requests. A
check that runs a host over the directory nests the host's bracket inside,
so the loop has ended before the flushes are asked. It is the context's
(`context.withFiles`), since the kit's bracket over services is
`withFiles` here. -/
def HostContext.withFiles {α : Type} (context : HostContext) (body : System.FilePath → IO α)
    (targets : List Job.Service := [.files]) : IO α := do
  let services ← Editor.Test.Linked.Services.over (← context.fileWaits)
  Editor.Test.Linked.withFiles services.jobs body targets

/-- Asks the host for the scene, and returns every line it printed for it:
the scene's line, then each view's line followed by its status line. -/
def Session.sceneLines (session : Session) : IO (Array String) := do
  let before := (← session.output.get).size
  session.ask [.scene]
  return (← session.output.get).extract before

/-- Asks the host for the scene, and returns its key hint lines: the lines
that start with `hint `. -/
def Session.hints (session : Session) : IO (Array String) := do
  return (← session.sceneLines).filter (·.startsWith "hint ")

/-- A stage for a host whose jobs reach real files: one over the real
elaborator and `source`, with what `compiled` hands it, whose services have
the library's file service, its diff service and its watch service, as the
executable wires them, over the table of waits the file checks share
(`HostContext.fileWaits`), which the one completion pump runs over. Its clock is
still a fake one: the watch service coalesces on the library's own. -/
def Stage.overFiles (context : HostContext) (source : Config.Source) (compiled : Compiled := {}) :
    IO (Stage Config.Elaborate.Base Config.Elaborate.Handle) := do
  let completions ← context.fileWaits
  let stage ← Stage.new context context.elaborator source compiled (some completions)
  let collaborators := stage.collaborators
  let refusedDiffs ← Job.RefusedDiffs.new
  let greps ← Job.RealGreps.new
  let watches ← Job.RealWatches.new
  return { stage with
      collaborators :=
        { collaborators with
          services :=
            { collaborators.services with
              fileWatches := Job.realFileWatches completions watches
              files := Job.realFiles completions collaborators.published.reader collaborators.held
              diffs :=
                Job.realDiffs completions collaborators.published.reader collaborators.held
                  refusedDiffs
              greps :=
                Job.realGreps completions collaborators.published.reader collaborators.held
                  greps } } }

namespace Session

/-- Asks the host for the scene, and returns what it printed of it: the echo
area's text, quoted as the scene line has it, and each view's line. -/
def scene (session : Session) : IO (String × Array String) := do
  let before := (← session.output.get).size
  session.ask [.scene]
  let printed := (← session.output.get).extract before
  -- The echo's text is between `, echo ` and `, echo padding `.
  let echo :=
    match printed[0]?.map (·.splitOn ", echo padding ") with
    | some (head :: _) =>
      match head.splitOn ", echo " with
      | _ :: rest => ", echo ".intercalate rest
      | [] => ""
    | _ => ""
  return (echo, printed.filter (·.startsWith "view "))

/-- Asks the host to show its commands, texts and stores, and returns the
lines it printed for them. -/
def shown (session : Session) : IO (Array String) := do
  let before := (← session.output.get).size
  session.ask [.show]
  return (← session.output.get).extract before

end Session

/-- The echo area's text of the scene the host prints, quoted as the scene
line has it. -/
def Session.echo (session : Session) : IO String :=
  return (← session.scene).1

/-- Runs the command called `name` through the host and waits for the jobs
it started: whether the wait settled. -/
def Session.ran (session : Session) (name : String) : IO Bool := do
  session.ask [.run name]
  return (← session.join) == .settled

/-- Asks the host for the scene, and returns the echo area's text, quoted as
the scene line has it, and every line it printed after the scene's: each
view's line, followed by its status line. -/
def Session.viewsAndStatus (session : Session) : IO (String × Array String) := do
  let before := (← session.output.get).size
  let (echo, _) ← session.scene
  return (echo, (← session.output.get).extract (before + 1))

/-- Waits until the host's output holds of `done`: on the emit of the line
that makes it hold (`Stage.outputWaits`), never by a poll. The wait is armed
before the output is read, so a line emitted in between is not missed.
Whether it came before `hangGuard`, which only a hang reaches. -/
def Session.outputReaches (session : Session) (done : Array String → Bool) : IO Bool := do
  let reached ← IO.Promise.new
  session.outputWaits.modify (·.push (done, reached))
  if done (← session.output.get) then
    return true
  return (← Job.awaitWithin hangGuard reached.result?).isSome

/-- Asks for the scene until `done` holds of its view and status lines, and
between two asks waits for the next line of the host's output that `cue`
accepts (`outputReaches`): the line of what changes the scene, such as a
job's result, so each ask is made on an event and never after a time. A
cue that was emitted before the scene was asked only makes the next ask at
once. Whether it held, and the lines it last saw; a cue that never comes
is a hang, at `hangGuard`. -/
def Session.shownOn (session : Session) (cue : String → Bool) (done : Array String → Bool) :
    IO (Bool × Array String) := do
  repeat
    let start := (← session.output.get).size
    let (_, seen) ← session.viewsAndStatus
    if done seen then
      return (true, seen)
    unless ← session.outputReaches fun lines => (lines.extract start lines.size).any cue do
      return (false, seen)
  return (false, #[])

/-- The text of the file `note.txt` of the file checks: two lines, with
two-byte characters. -/
def noteText : String :=
  "héllo\nwörld\n"

end Editor.Test.Linked
