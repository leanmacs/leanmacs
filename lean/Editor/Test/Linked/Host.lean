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
import Editor.Headless.Journal.Fake
import Editor.Headless.Stepped
import Editor.InferredWait
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
import Editor.RealHost
import Editor.Scene
import Editor.Setup
import Editor.State
import Editor.SyntaxTree
import Editor.SyntaxTree.Fake
import Editor.SyntaxTree.Real
import Editor.Test.Linked.Listings
import Editor.Test.Linked.Services
import Editor.Test.Linked.Stepping
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
stepped on the check's thread (`onStage`, `staged`, `withHost`, each over a
stepped stage by default, `Stage.stepped`, whose jobs and services are the
fakes the check steps with `Session.step`) or on a loop thread of its own
(`onRealStage`, `stagedReal`, `withRealHost`), and the
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
  (`Headless.Collaborators.loopStarted`), so a check can show that a
  stepped host, or a refused real one, started none. Which checks may run
  one at all is `lake build`'s `linter.realHost`'s
  (`docs/dev-practices/real-thread-checks.md`). -/
  realLoops : IO.Ref Nat

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

/-- The mark of `HostContext.fileWaits`: it runs a real background service (`Editor/RealHost.lean`). -/
def HostContext.fileWaits.realHost : RealHost :=
  .service

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

/-- The fakes of a stepped stage (`Stage.stepped`), which the check steps on
its own thread: the job services (`SteppedServices`: the fake scheduler, the
fake pump, the file and process fakes), the memory queue the host drains,
and the session journal's and the syntax service's fakes once the stage's
makers have added them (`Stage.recordingJournal`, `Stage.fakeSyntaxService`),
which are refs so the loop's end, made with the stage, steps them too: the
kit's stepped fakes (`SteppedFakes`, `Editor/Test/Linked/Stepping.lean`),
with their `stepWork` and `unquiet`. -/
abbrev Stage.Fakes :=
  SteppedFakes

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
  /-- The fakes the check steps, on a stepped stage (`Stage.stepped`); none
  on a stage whose jobs run on Lean's pool. -/
  fakes : Option Stage.Fakes := none
  /-- Whether the stage's services are the library's real ones
  (`Stage.overFiles`), which a stepped stage refuses. -/
  realServices : Bool := false

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

/-- `stage` with its host's session journal the recording fake
(`Headless.RecordingJournal`, `Editor/Headless/Journal/Fake.lean`) and its
state directory `state`, and the fake, which the check steps on its own
thread; on a stepped stage (`Stage.stepped`) it is recorded with the
stage's fakes, so the session's steps step it too. The fake reads a save's text from the stage's published table when
the host hands the order, as the real journal finds the library's snapshot
then. Nothing is written to `state`: the fake works its orders on a model
of files. -/
def Stage.recordingJournal {β σ : Type} (stage : Stage β σ) (state : System.FilePath) :
    IO (Stage β σ × Headless.RecordingJournal) := do
  let fake ←
    Headless.RecordingJournal.new (snapshots :=
        some (Job.realSnapshots stage.collaborators.published.reader))
  let collaborators :=
    { stage.collaborators with
      journal := fake.journal, stateDirectory := some state }
  if let some fakes := stage.fakes then
    fakes.journal.set (some fake)
  return ({ stage with collaborators }, fake)

/-- `stage` with its host's syntax tree handler the fake of the syntax
service's deliveries (`FakeSyntaxService`, `Editor/SyntaxTree/Fake.lean`),
and the fake, which the check steps on its own thread. The fake learns a
snapshot's text from the stage's published table the first time a request
names it; the table does not say which document a snapshot is of, so each
snapshot is a text of its own, as the model's contract runs have it, until
phase 4 meets an edit. Each step posts the library's report that a parse
was delivered (`Event.parsed`, from the library's source) to the stage's
memory queue, so on a stepped host the delivery reaches the loop as it
would from the library. On a stepped stage (`Stage.stepped`) the fake is
recorded with the stage's fakes, so the session's steps step it too. -/
def Stage.fakeSyntaxService {β σ : Type} (stage : Stage β σ) : IO (Stage β σ × FakeSyntaxService) :=
  do
  let parsed : Ffi.Event :=
    { source := { kind := .library, id := 0 }, kind := .parsed, code := 0, text := "", stamp := 0 }
  let fake ←
    FakeSyntaxService.new (post := discard <| stage.memory.push parsed) (learn :=
        Job.realSnapshots stage.collaborators.published.reader)
  let collaborators := { stage.collaborators with syntaxTree := fun _ => pure fake.handle }
  if let some fakes := stage.fakes then
    fakes.syntaxService.set (some fake)
  return ({ stage with collaborators }, fake)

/-- `stage` with every background collaborator of its host's jobs a fake the
check steps on its own thread (`Stage.Fakes`): the fake scheduler, so a
job's code runs only on a step; the file service's fake over `files`, as
the files, the diffs and the searches, and the process service's over
`processes`, both answering through the fake pump; the stage's fake clock
and watches, as before; and a fake of each of `packages`, the services a
package brings (`Job.FakePackageService`), over the fake pump, its
hand-offs taken from the process fake. A published snapshot a save, a diff
or a search names is read from the stage's published table when the request
is taken.

Its loop's end steps the fakes on the end's thread, the check's, until
each job it cancelled has ended, and throws, naming it, when nothing can
run first. A stage over the library's services (`Stage.overFiles`) is
refused, as is a stage stepped already: a real service's answer comes on
another thread, so "nothing can run" would be racy again. -/
def Stage.stepped {β σ : Type} (stage : Stage β σ) (files : FileModel := {})
    (processes : ProcessModel := {}) (packages : Array Job.FakePackageService.Spec := #[]) :
    IO (Stage β σ) := do
  if stage.realServices then
    throw <|
        IO.userError
          "a stepped stage refuses a stage over the library's services (Stage.overFiles): its fakes cannot be stepped beside a real service"
  if stage.fakes.isSome then
    throw (IO.userError "the stage is stepped already")
  let collaborators := stage.collaborators
  let services ←
    SteppedServices.new collaborators.services.completions stage.clock stage.watches
        (Job.realSnapshots collaborators.published.reader) collaborators.held files processes
        packages
  let fakes : Stage.Fakes :=
    { services, memory := stage.memory, journal := ← IO.mkRef none,
      syntaxService := ← IO.mkRef none }
  let endCancelled := fakes.endCancelled
  return { stage with
      fakes := some fakes
      collaborators :=
        { collaborators with
          services :=
            { collaborators.services with
              files := services.jobs.files, processes := services.jobs.processes
              diffs := services.jobs.diffs, greps := services.jobs.greps
              scheduler := services.jobs.scheduler, packages := services.jobs.packages }
          endCancelled } }

/-- A host as a check drives it, whichever kind it is: a real one, whose loop
runs on a thread of its own (`Headless.Host`, `Driven.ofHost`), or one
stepped on the check's own thread (`Headless.Stepped`, `Driven.ofStepped`).
It is the script runner's port (`Headless.Driven`), so a check written on
it runs on either host, and a check's waits are the core's named ones; the
wrappers below keep the kit's names for them. -/
abbrev Driven :=
  Headless.Driven

namespace Driven

/-- A real host, driven. -/
def ofHost (host : Headless.Host) : Driven :=
  Headless.Driven.ofHost host

/-- A stepped host, driven. -/
def ofStepped (stepped : Headless.Stepped) : Driven :=
  Headless.Driven.ofStepped stepped

/-- Sends a press of `key`, with no text, as the window would report it. -/
def press (driven : Driven) (key : Key) : IO Unit :=
  Headless.Driven.press driven key

/-- Sends `text` as an input method's composition would end with it. -/
def commit (driven : Driven) (text : String) : IO Unit :=
  Headless.Driven.commit driven text

/-- Sends a resize of the frame to `width` by `height` physical pixels, at a
scale of 1 and out of fullscreen. -/
def resize (driven : Driven) (width height : Nat) : IO Unit :=
  Headless.Driven.resize driven width height

/-- `Headless.Host.await` on the driven host: a `settle`'s wait
(`Headless.Wait.Kind.settle`).
 -/
def await (driven : Driven) (waitGuard : HangGuard) (answer : HangGuard := waitGuard)
    (line : Option Nat := none) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Headless.Wait :=
  Headless.Driven.await driven waitGuard answer line waitHung waitBlocked

/-- `join` is an inferred wait (`Editor/InferredWait.lean`). -/
def join.inferredWait : InferredWait :=
  .idle []

/-- `Headless.Host.join` on the driven host: a `join`'s wait
(`Headless.Wait.Kind.join`).
 -/
def join (driven : Driven) (waitGuard : HangGuard) (answer : HangGuard := waitGuard)
    (line : Option Nat := none) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Headless.Wait :=
  Headless.Driven.join driven waitGuard answer line waitHung waitBlocked

/-- `Headless.Host.settle` on the driven host.
 -/
def settle (driven : Driven) (waitGuard : HangGuard) (answer : HangGuard := waitGuard)
    (line : Option Nat := none) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Bool :=
  Headless.Driven.settle driven waitGuard answer line waitHung waitBlocked

/-- A wait only until the host has handled everything sent so far
(`Headless.Wait.Kind.handled`), publishing nothing.
 -/
def handled (driven : Driven) (waitGuard : HangGuard) : IO Headless.Wait :=
  Headless.Driven.handled driven waitGuard

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
  /-- The stage's fakes, on a stepped stage (`Stage.stepped`), which the
  session's steps step (`Session.step`); none otherwise. -/
  fakes : Option Stage.Fakes := none
  /-- The memory queue a stepped host drains, on a host stepped on the
  check's thread (`Session.ofStage`); none for a real host, whose loop
  thread takes its own queue. -/
  queue : Option (Headless.Queue.Memory Ffi.Event) := none

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
    log := stage.log, waitHung, waitBlocked, fakes := stage.fakes, queue := some stage.memory }

/-- The session of the real host `host` over `stage`. -/
def RealSession.ofStage {β σ : Type} (host : Headless.Host) (directory : System.FilePath)
    (stage : Stage β σ) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : RealSession :=
  { Session.ofStage host directory stage waitHung waitBlocked with
    host, queue := none }

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

/-- On a stepped stage (`Stage.stepped`), the host's queue drained and, while
a restore is in flight, the fakes stepped round by round: a restore holds
the driver's requests until its jobs have run, and on a stepped stage they
run only on a step, so a settle would wait for them in vain. Throws when a
round moves nothing with the restore still in flight, a stall. Nothing on
a stage with no fakes. -/
private partial def stepRestoring (session : Session) : IO Unit := do
  let some fakes := session.fakes | return
  if (← session.drive.handled hangGuard) == .ended then
    return
  unless (← session.drive.progress).restoring do
    return
  let mut moved := false
  while ← fakes.stepWork do
    moved := true
  unless moved || (← fakes.memory.size) > 0 do
    throw <|
        IO.userError
          "a stall: a restore is in flight and nothing of the stepped stage's fakes can run"
  stepRestoring session

/-- Sends `requests` to the host in order, and waits until it has handled
them and no reload is running (`settled`): for the reload's end, with the
session's `waitHung` and `waitBlocked`. On a stepped stage a restore in
flight is stepped to its end first (`stepRestoring`). Throws a hang if the
wait reaches `hangGuard`, and says the loop ended, with what it ended with,
if it ended first. -/
def ask (session : Session) (requests : List Headless.Request) : IO Unit := do
  for request in requests do
    session.drive.send request
  session.stepRestoring
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
`waitBlocked`: whether it did. On a stepped stage a restore in flight is
stepped to its end first (`stepRestoring`). -/
def settle (session : Session) : IO Bool := do
  session.stepRestoring
  session.drive.settle hangGuard (waitHung := session.waitHung) (waitBlocked := session.waitBlocked)

/-- Waits until the host has handled everything sent so far, with
`hangGuard`, and publishes nothing (`Driven.handled`): whether it did. -/
def handled (session : Session) : IO Bool :=
  return (← session.drive.handled hangGuard) == .settled

/-- One round of a stepped session (`step`): the host's queue drained
(`handled`, which publishes nothing), then every piece of the fakes' work
that can run (`Stage.Fakes.stepWork`). Whether anything moved: the queue
held an event, or a piece ran; nothing moves once the loop has ended.
Throws on a session with no fakes. -/
def round (session : Session) : IO Bool := do
  let some fakes := session.fakes
    | throw (IO.userError "a session's step needs a stepped stage (Stage.stepped), and this one has no fakes")
  let queued ← fakes.memory.size
  match ← session.drive.handled hangGuard with
  | .settled =>
    pure ()
  | .ended =>
    -- A loop that has ended takes nothing more: what is left is the
    -- loop's end's to step.
    return false
  | _ =>
    throw <|
        IO.userError
          s!"a hang: the editor thread had not handled its queue within {hangGuard.ms} ms"
  let mut moved := decide (queued > 0)
  while ← fakes.stepWork do
    moved := true
  return moved

/-- Steps the session to rest, on the check's own thread: in rounds, the
host's queue drained and every piece of the fakes' work that can run run
(the scheduler's, the pump's, the syntax fake's and the journal fake's, in
that order), until a round moves nothing. It waits for nothing: what it
steps is the check's own, and it does not move the clock, which the check
moves itself. Throws on a session with no fakes. -/
partial def step (session : Session) : IO Unit := do
  if ← session.round then
    session.step

/-- Steps the session round by round (`step`) until its output holds of
`done`: `true` once it does, `false` when a round moved nothing first, a
stall said at once, never a hang. -/
partial def stepUntil (session : Session) (done : Array String → Bool) : IO Bool := do
  if done (← session.output.get) then
    return true
  if ← session.round then
    session.stepUntil done
  else
    return done (← session.output.get)

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

/-- Runs `check` against a host stepped on the check's own thread over
`collaborators` and the memory queue `memory` (`Headless.withStepped`),
which returns only once the host's loop has ended, whether the check
returned or threw. `false` if the check did not hold or the host did not
settle after it, `hangGuard` its guard against a hang (`waitHung`,
`waitBlocked`). It also fails the check if the library's editor queue grew
across it (`leavingLibraryQueue`), and, over a stepped stage's `fakes`,
throws if any of them still holds work once the loop has ended
(`Stage.Fakes.unquiet`). -/
def stepping {β σ : Type} {scheme : InputScheme} (collaborators : Headless.Collaborators β σ scheme)
    (memory : Headless.Queue.Memory Ffi.Event) (check : Driven → IO Bool)
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) (fakes : Option Stage.Fakes := none) :
    IO Bool := do
  let held ←
    leavingLibraryQueue <|
        Headless.withStepped collaborators memory (guard := hangGuard) (grace := some hangGuard)
          fun stepped => do
          let drive := Driven.ofStepped stepped
          let held ← check drive
          let wait ← drive.await hangGuard (waitHung := waitHung) (waitBlocked := waitBlocked)
          return held && (wait == .settled || wait == .ended)
  -- Quiescent once stepped to its end: the loop's end has stepped what its
  -- cancels let go, and anything a check left unstepped is still held.
  if let some fakes := fakes then
    let unquiet ← fakes.unquiet
    unless unquiet.isEmpty do
      throw <|
          IO.userError
            s!"the check left its stage's fakes holding work once the host's loop had ended: {"; ".intercalate unquiet.toList}"
  return held

/-- The mark of `hostingReal`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def hostingReal.realHost : RealHost :=
  .loop

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
    stage.fakes

/-- Throws if `stage` is stepped (`Stage.stepped`): a real host's loop thread
cannot step its fakes, so `what` refuses it. -/
def refuseFakes {β σ : Type} (stage : Stage β σ) (what : String) : IO Unit := do
  if stage.fakes.isSome then
    throw <|
        IO.userError
          s!"{what} refuses a stepped stage (Stage.stepped): a real host's loop thread cannot step its fakes"

/-- The mark of `onRealStage`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def onRealStage.realHost : RealHost :=
  .loop

/-- Runs `check` against a real host started on `stage` (`hostingReal`). It
refuses a stepped stage (`refuseFakes`). -/
def onRealStage {β σ : Type} (stage : Stage β σ) (check : Headless.Host → Stage β σ → IO Bool)
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Bool := do
  refuseFakes stage "onRealStage"
  hostingReal stage.collaborators (fun host => check host stage) waitHung waitBlocked

/-- Runs `check` against a stepped host started on a stepped stage of its
own over `elaborator` and `source`, with what `compiled` hands it: the
stage's jobs and services are the fakes the check steps (`Stage.stepped`).
`false` if the check did not hold or the host did not settle. -/
def staged {β σ : Type} (context : HostContext) (elaborator : Config.Elaborator β σ)
    (source : Config.Source) (check : Driven → Stage β σ → IO Bool) (compiled : Compiled := {})
    (fuzzy : FuzzyHandler := Fuzzy.real) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Bool := do
  let stage ← (← Stage.new context elaborator source compiled (fuzzy := fuzzy)).stepped
  onStage stage check waitHung waitBlocked

/-- The mark of `stagedReal`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def stagedReal.realHost : RealHost :=
  .loop

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

/-- The mark of `withRealHostOver`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def withRealHostOver.realHost : RealHost :=
  .loop

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

/-- The mark of `withRealHost`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def withRealHost.realHost : RealHost :=
  .loop

/-- `withHost` with a real host (`withRealHostOver`). -/
def withRealHost (context : HostContext) (files : List (String × String))
    (check : RealSession → IO Bool) (compiled : Compiled := {}) (fuzzy : FuzzyHandler := Fuzzy.real)
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Bool :=
  withRealHostOver context files id id check compiled fuzzy waitHung waitBlocked

/-- The mark of `HostContext.withFiles`: it runs a real background service (`Editor/RealHost.lean`). -/
def HostContext.withFiles.realHost : RealHost :=
  .service

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

/-- The mark of `Stage.overFiles`: it runs a real background service (`Editor/RealHost.lean`). -/
def Stage.overFiles.realHost : RealHost :=
  .service

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
      realServices := true
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

/-- Whether every job `lines` says started (`job N name: started`) has an end
line after it (`job N name: ` and anything but `started`). -/
def startedJobsEnded (lines : Array String) : Bool :=
  (List.range lines.size).all fun index =>
    let line := lines[index]!
    if line.startsWith "job " && line.endsWith ": started" then
      let label := String.ofList (line.toList.take (line.length - ": started".length)) ++ ": "
      ((lines.extract (index + 1) lines.size).any fun later =>
        later.startsWith label && !later.endsWith ": started")
    else true

/-- Runs the command called `name` through the host, on a stepped stage
(`Stage.stepped`), and steps it to rest (`Session.step`): whether every job
it started has ended, each `job N x: started` line printed since the ask
followed by its end line. The run's own jobs' ends, never an idle. -/
def Session.ranStepped (session : Session) (name : String) : IO Bool := do
  let before := (← session.output.get).size
  session.ask [.run name]
  session.step
  let lines ← session.output.get
  return startedJobsEnded (lines.extract before lines.size)

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
Whether it came before `hangGuard`, which only a hang reaches. On a stepped
stage (`Stage.stepped`) it steps the session until it holds
(`Session.stepUntil`) in place of blocking: `false` at a stall. On a host
stepped on the check's thread over real services it drains the host's
queue at each post to it until it holds. -/
def Session.outputReaches (session : Session) (done : Array String → Bool) : IO Bool := do
  if session.fakes.isSome then
    return ← session.stepUntil done
  -- A host stepped on the check's thread over real services takes its
  -- queue only in a wait: each round arms the queue's next push, drains,
  -- and blocks on that push, an event, until the output holds.
  if let some queue := session.queue then
    repeat
      let arrived ← queue.arrived
      unless ← session.handled do
        return false
      if done (← session.output.get) then
        return true
      -- hang guard: the next post to the host's queue; only a hang reaches
      -- the bound.
      if (← Job.awaitWithin hangGuard arrived).isNone then
        return false
    return false
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
