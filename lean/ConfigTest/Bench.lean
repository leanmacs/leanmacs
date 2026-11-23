import ConfigTest.Support.Candidates
import ConfigTest.Support.Configs
import ConfigTest.Support.Shipped
import Editor.Api
import Editor.Clipboard
import Editor.Clipboard.InProcess
import Editor.Command
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Later
import Editor.Config.Directory
import Editor.Config.Elaborate
import Editor.Config.Registry
import Editor.Config.Session
import Editor.Event
import Editor.Ex.Line
import Editor.Face
import Editor.File.Model
import Editor.FileJobs
import Editor.Fuzzy
import Editor.Fuzzy.Real
import Editor.Headless
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Fake
import Editor.Job.Pool
import Editor.Job.Real
import Editor.Job.Runner
import Editor.Language
import Editor.Loop
import Editor.Mode
import Editor.Package
import Editor.Program
import Editor.Scene
import Editor.Setup
import Editor.State
import Editor.SyntaxTree
import Editor.SyntaxTree.Real
import Editor.Test.Linked.Bench
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Test.Linked.Lines
import Editor.Test.Linked.Listings
import Editor.Test.Minibuffer
import Editor.Test.Shipped
import Editor.Text
import Editor.Text.Model
import Editor.Text.Real
import Editor.Watch
import FilesApiTest.Fake

/-!
# Config tests: the benchmark

The benchmark of the config session, `ConfigTest.Bench`: the `bench-*` commands
of `config-test`, which the root module `ConfigTest` runs from `main`. It
measures and asserts nothing of its own, so it mirrors no module; its sections
say what each command measures.
-/

-- A bench measures real time: its clock reads, and the sleeps of its
-- cadence, are the measurement and never a wait, and it is never part of
-- `ci` (`linter.rawClock`, `Editor/Lint/Wait.lean`).
set_option linter.rawClock false

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-! ## The benchmark

Three subcommands measure the config session (`mise run config-bench`, which
runs each in a fresh process under `/usr/bin/time -l`). They are a measuring
tool: they assert nothing but that every reload installed, the gate builds
them and never runs them, and no number they print is an expected value.

Each loads config through the headless host, as the editor does, from a
source held in memory, so they touch no files. A time is from the request
for a reload to its report, on Lean's monotonic clock. -/

namespace Bench

/-- The guard of a measurement's reload, settle or join; only a hang
reaches it, and the measurement then fails as a hang. For one reload. -/
def patience : HangGuard :=
  .on "a measurement's reload, settle or join" 120000

/-- The guard of the pool's warming again after a row, run out on purpose:
a warming task a full pool does not start. -/
def rewarm : HangGuard :=
  .held "a warming task a full pool does not start" 5000

/-- The real elaborator a measurement runs on, over the toolchain in
`sysroot` and the `.olean` directories `oleanDir` names, on the base
`imports`, and the files it writes the module data of config files to: in
a temporary directory of the system's, made when the first is written. A
measurement that makes one removes it when it ends (`ModuleFiles.remove`). -/
def measured (sysroot oleanDir : String) (imports : Array Lean.Name := #[`Editor]) :
    IO
      (Config.Elaborator Config.Elaborate.Base Config.Elaborate.Handle ×
        Config.Elaborate.ModuleFiles) :=
  do
  let files ← Config.Elaborate.ModuleFiles.temporary
  return (Config.Elaborate.elaborator { sysroot, oleanDirs := oleanDirs oleanDir, imports } files,
      files)

/-- A config to measure: its files, each a module name and a text, the root
being the module `init`. A text is headed as a file a check writes is
(`headed`). -/
abbrev Files :=
  List (String × String)

/-- A host to measure: its source is `files`, and it notes when each
reload's report is printed. -/
structure Rig where
  /-- The host. -/
  host : Headless.Host
  /-- The config the host's source holds. -/
  files : IO.Ref Files
  /-- The config directory the host's source reads, when it reads one and
  not `files`. -/
  directory : Option System.FilePath := none
  /-- The last reload's report line, and the monotonic time, in nanoseconds,
  at which it was printed. -/
  reported : IO.Ref (Option (String × Nat))
  /-- Every other line the host printed since the last request: the
  diagnostics of a reload that went wrong. -/
  others : IO.Ref (Array String)

namespace Rig

/-- Runs `body` against a host over `elaborator` and a source in memory, or,
with `directory`, over that config directory, which each reload then writes
its config into and reads it back from; the host lives in its bracket
(`Headless.withHost`), so this returns only once its loop has ended. -/
def «with» {α : Type} (elaborator : Config.Elaborator Config.Elaborate.Base Config.Elaborate.Handle)
    (directory : Option System.FilePath) (body : Rig → IO α) : IO α := do
  let files ← IO.mkRef ([] : Files)
  let reported ← IO.mkRef none
  let others ← IO.mkRef #[]
  let emit (line : String) : IO Unit := do
    if line.startsWith "reload " then
      reported.set (some (line, ← IO.monoNanosNow))
    else
      others.modify (·.push line)
  -- The configs measured here start no job: the clock is never asked.
  let completions ← Job.Completions.new
  let clock ← Job.FakeClock.new completions
  let source :=
    match directory with
    | some directory => Config.Directory.source directory
    | none =>
      sourceOver do
        return (← files.get).map fun (module, text) => (module, headed text)
  Headless.withHost (scheme := TestScheme.scheme) (guard := patience)
      { elaborator, source, emit, services := { completions, timers := clock.timers },
        published := ← Snapshots.new, held := ← Job.HeldSnapshots.new, requests := 1, wakeups := 2,
        jobs := 3, environment := 4, posts := 5, pauseEvents := 6 }
      fun host => body { host, files, directory, reported, others }

/-- Makes `config` the source's files, asks for a reload, and returns the
nanoseconds from the request to the report. Throws unless the reload was
installed. -/
def reload (rig : Rig) (config : Files) : IO Nat := do
  rig.files.set config
  -- Written before the clock is read: the time is the reload's.
  if let some directory := rig.directory then
    writeConfig directory
        (config.map fun (module, text) =>
          (if module == Config.rootModule then Config.rootPath else Config.pathOf module, text))
  rig.reported.set none
  rig.others.set #[]
  let asked ← IO.monoNanosNow
  rig.host.send .reload
  unless ← rig.host.settle patience do
    throw (IO.userError "a reload did not finish")
  let some (line, printed) ← rig.reported.get | throw (IO.userError "a reload was not reported")
  unless (line.splitOn "installed").length > 1 do
    throw (IO.userError s!"{line}: {"; ".intercalate (← rig.others.get).toList}")
  return printed - asked

end Rig

/-- A config of one file of one line, which differs with `round`. -/
def oneLine (round : Nat) : Files :=
  [("init", "def setup : SetupM Unit := command \"round" ++ toString round ++ "\" (pure ())\n")]

/-- A config of one file of twenty lines, which differs with `round`. -/
def twentyLines (round : Nat) : Files :=
  [("init",
      "def greet : EditorM Unit := do
  let text ← createText \"hello\"
  append text \", world\"

def shout : EditorM Unit := do
  let text ← createText \"HELLO\"
  append text \"!\"

def twice (command : EditorM Unit) : EditorM Unit := do
  command
  command

def note (round : Nat) : EditorM Unit := do
  discard <| createText (toString round)

def setup : SetupM Unit := do
  command \"greet\" greet
  command \"shout\" shout
  command \"twice\" (twice greet)
  command \"note\" (note " ++
        toString round ++
        ")\n")]

/-- Fifty definitions and a theorem proved by `simp`. -/
def fiftyText : String :=
  String.join
      ((List.range 50).map fun index =>
        s!"def f{index} (n : Nat) : Nat := n * {index} + {index}\n") ++
    "theorem f1_spec (n : Nat) : f1 n = n + 1 := by simp [f1]\n"

/-- A config of one file of fifty definitions, a theorem proved by `simp`
and a `setup`, which differs with `round`. -/
def fiftyDefinitions (round : Nat) : Files :=
  [("init",
      fiftyText ++ s!"def round : Nat := {round}\n" ++
        "def setup : SetupM Unit := command \"round\" (pure ())\n")]

/-- The soak's config of the root alone: `fiftyDefinitions` in a root that
imports `Lean` and uses it, so the base it is elaborated on holds `Lean`.
It differs with `round`. -/
def fiftyWithLean (round : Nat) : Files :=
  [("init",
      importing ["Lean"]
        (fiftyText ++ s!"def round : Lean.Json := Lean.Json.num {round}\n" ++
          "def setup : SetupM Unit := command round.compress (pure ())\n"))]

/-- The soak's config of two files: the fifty definitions in the config file
`Config/Defs.lean`, which differs with `round`, and a root that imports
`Lean` and that file and uses both. So each reload elaborates the config
file, writes its module data, and elaborates the root on an environment
made from the base and that module file. -/
def fiftyInAModule (round : Nat) : Files :=
  [("Config.Defs", fiftyText ++ s!"def round : Nat := {round}\n"),
    ("init",
      importing ["Lean", "Config.Defs"]
        "def named : Lean.Json := Lean.Json.num (f1 round)\ndef setup : SetupM Unit := command named.compress (pure ())\n")]

/-- Nanoseconds as milliseconds with one decimal. -/
def milliseconds (nanoseconds : Nat) : String :=
  let tenths := (nanoseconds + 50000) / 100000
  s!"{tenths / 10}.{tenths % 10}"

/-- The median and the maximum of `times`, as milliseconds. -/
def medianAndMaximum (times : Array Nat) : String :=
  let sorted := times.qsort (· < ·)
  let median := (sorted.getD ((sorted.size - 1) / 2) 0 + sorted.getD (sorted.size / 2) 0) / 2
  s!"median {milliseconds median} ms, maximum {milliseconds (sorted.back?.getD 0)} ms"

/-- `elaborator` with `base` as the base a host with none starts from: the
host's first reload grows it, and does not make another. -/
def over (base : Config.Elaborate.Base)
    (elaborator : Config.Elaborator Config.Elaborate.Base Config.Elaborate.Handle) :
    Config.Elaborator Config.Elaborate.Base Config.Elaborate.Handle :=
  { elaborator with base := fun earlier modules => elaborator.base (earlier <|> some base) modules }

/-- `bench-start`: makes the base of `modules`, then loads the twenty-line
config through a host, and prints how long each took. -/
def start (sysroot oleanDir : String) (modules : List String) : IO UInt8 := do
  let (real, _) ← measured sysroot oleanDir (modules.map String.toName).toArray
  let before ← IO.monoNanosNow
  let base ← real.base none #[]
  let imported := (← IO.monoNanosNow) - before
  Rig.with (over base real) none fun rig => do
      let first ← rig.reload (twentyLines 0)
      IO.println
          s!"bench-start {modules}: import {milliseconds imported} ms, first load {milliseconds first} ms"
      return 0

/-- `bench-reload`: twenty reloads of each of the three configs of one
file, each reload with the text changed, and of the config of two files
with the imported file changed, and prints the median and the maximum of
each. -/
def reload (sysroot oleanDir : String) : IO UInt8 := do
  let (real, files) ← measured sysroot oleanDir
  Rig.with real none fun rig => do
      -- The first load makes the base; it is not one of the twenty.
      discard <| rig.reload (oneLine 0)
      let configs :=
        [("one-line root", oneLine), ("20-line config", twentyLines),
          ("50 definitions and a simp proof", fiftyDefinitions),
          ("50 definitions in an imported file, on a base with Lean", fiftyInAModule)]
      for (name, config) in configs do
        -- The first load of a config may grow the base; it is not one of the
        -- twenty either.
        discard <| rig.reload (config 0)
        let mut times := #[]
        for round in [1:21] do
          times := times.push (← rig.reload (config round))
        IO.println s!"bench-reload: {name}: {medianAndMaximum times}"
  files.remove
  return 0

/-- `bench-reload-directory`: twenty reloads each of the one-line root, of
the fifty-definition config and of the config of two files, read from a
config directory, a
temporary one of its own, and not from memory: what a reload costs with
the directory's lookups in it. It prints the median and the maximum of
each. -/
def reloadDirectory (sysroot oleanDir : String) : IO UInt8 :=
  IO.FS.withTempDir fun directory => do
    let (real, files) ← measured sysroot oleanDir
    Rig.with real (some directory) fun rig => do
        let configs :=
          [("one-line root", oneLine), ("50 definitions and a simp proof", fiftyDefinitions),
            ("50 definitions in an imported file, on a base with Lean", fiftyInAModule)]
        for (name, config) in configs do
          -- The first load makes or grows the base; it is not one of the twenty.
          discard <| rig.reload (config 0)
          let mut times := #[]
          for round in [1:21] do
            times := times.push (← rig.reload (config round))
          IO.println s!"bench-reload-directory: {name}: {medianAndMaximum times}"
    files.remove
    return 0

/-- `bench-modules`: makes the base of `modules` and prints the name of
every module the import read, one a line and unescaped, so that
`tools/stage-bundle.sh --closure` can map each to its files. -/
def modules (sysroot oleanDir : String) (modules : List String) : IO UInt8 := do
  let (real, _) ← measured sysroot oleanDir (modules.map String.toName).toArray
  let base ← real.base none #[]
  for name in base.environment.allImportedModuleNames do
    IO.println (name.toString (escape := false))
  return 0

/-- `count` reloads of `config`, each with the text changed, after a first
load that is not counted, and `name` with the mean time of one on stdout. -/
def soaked (name : String) (config : Nat → Files) (sysroot oleanDir : String) (count : Nat) :
    IO UInt8 := do
  let (real, files) ← measured sysroot oleanDir
  Rig.with real none fun rig => do
      discard <| rig.reload (config 0)
      let mut total := 0
      for round in [1:count + 1] do
        total := total + (← rig.reload (config round))
      IO.println s!"{name}: {count} reloads, mean {milliseconds (total / count)} ms per reload"
  files.remove
  return 0

/-- `bench-soak`: `count` reloads of a config that is its root alone, fifty
definitions in a root that imports `Lean` and uses it (`fiftyWithLean`),
each with the text changed, and prints the mean time of one. -/
def soak (sysroot oleanDir : String) (count : Nat) : IO UInt8 :=
  soaked "bench-soak" fiftyWithLean sysroot oleanDir count

/-- `bench-soak-modules`: `count` reloads of a config of two files, a root
that imports `Lean` and a config file that changes each round
(`fiftyInAModule`), and prints the mean time of one. -/
def soakModules (sysroot oleanDir : String) (count : Nat) : IO UInt8 :=
  soaked "bench-soak-modules" fiftyInAModule sysroot oleanDir count

/-! ### The job benchmark

`bench-jobs` measures the latency of the editor loop while jobs run
(`mise run job-bench`). Like the others it is a measuring tool: the gate
builds it and never runs it, and no number it prints is an expected value.

Each row runs a headless host on the real elaborator, the real queue and the
library's timer service, with the pool warmed and the pump running, as the
editor's headless mode does. A sample is one `run noop`: the driver reads
the monotonic clock, posts the request, and the output port reads the clock
again on the editor thread when `run noop: ok` is printed; the driver waits
for that before the next sample.

A row has a host of its own, and its jobs are ended by ending that host,
whose loop cancels them. A reload cannot end them: Lean's frontend
elaborates on pool tasks, so while a job computes on every pool thread a
reload does not get to elaborate, and never installs. Seen when this
benchmark still ended a row with a reload: with one job fewer than the pool
has threads the reload went through, and with one a thread it had not
finished after 45 seconds (`docs/design/concurrency.md`, "Reload"). -/

/-- The config the job benchmark loads: a command that does nothing, a job
that sleeps a millisecond in a loop, and a job that computes for ever, with a
reading of the clock every 100,000 iterations. A cancelled job ends at its
next request, so the reading is what lets the computing job be ended. -/
def jobsConfig : Files :=
  [("init",
      "partial def ticker (token : Unit) : JobM Unit := do
  sleep 1
  ticker token

def churn (seed : Nat) : Nat := Id.run do
  let mut value := seed
  for index in [0:100000] do
    value := (value * 1103515245 + index) % 2147483648
  return value

partial def spin (seed : Nat) : JobM Unit := do
  let value := churn seed
  let instant ← now
  spin (value + instant % 2)

def setup : SetupM Unit := do
  command \"noop\" (pure ())
  job \"ticker\" ticker fun _ => pure ()
  job \"spin\" (fun _ => spin 1) fun _ => pure ()
")]

/-- A compiled job that reads the clock `count` times and finishes. -/
def readings (count : Nat) : Work := fun _ => do
  for _ in [0:count] do
    discard now
  return pure ()

/-- `bench-jobs`: the latency of the editor loop, over `samples` samples a
row, while nothing runs, while 64 jobs each sleep a millisecond in a loop,
while one interpreted job a pool thread computes, while two a pool thread
do, and while nothing runs again; then the cost of a `now` request in a
compiled job. Each row has a host of its own, and its jobs are ended by
ending that host.

Of two computing jobs a pool thread, half run and half wait in the pool's
queue: a job that never waits keeps its thread. -/
def jobs (sysroot oleanDir : String) (samples : Nat) : IO UInt8 := do
  let pool := (← Job.Pool.warm Job.Pool.size Headless.warmPatience).size
  let completions ← Job.Completions.new
  discard <| IO.asTask (prio := .dedicated) (Job.pump completions)
  let real := Job.realTimers completions
  -- The clock, counting its waits and its readings: how the driver knows
  -- that jobs have got going, and how many completions went through the pump.
  let waits ← IO.mkRef 0
  let reads ← IO.mkRef 0
  let counted : Job.Timers :=
    { real with
      now := do
        reads.modify (· + 1)
        real.now,
      start := fun id deadline => do
        waits.modify (· + 1)
        real.start id deadline }
  let slot ← IO.mkRef (none : Option (IO.Promise Nat))
  let reloads ← IO.mkRef #[]
  let emit (line : String) : IO Unit := do
    if line == "run noop: ok" then
      let ran ← IO.monoNanosNow
      if let some sample← slot.get then
        sample.resolve ran
    else
      if line.startsWith "reload " || line.startsWith "diagnostic: " then
        reloads.modify (·.push line)
  -- The base is imported once, here, and every host is handed it.
  let (adapter, _) ← measured sysroot oleanDir
  let base ← adapter.base none #[]
  let elaborator := over base adapter
  let ids ← IO.mkRef (1 : UInt64)
  -- One row: a host of its own that loads the config and starts `count` jobs
  -- called `job`; `going` waits until they are under way; then the samples.
  -- Returns the samples, how many waits were started while they were taken,
  -- and how long taking them took. The host is ended whatever happens, which
  -- cancels its jobs, and the row is over when every pool thread is free.
  let row (job : String) (count : Nat) (going : IO Unit) : IO (Array Nat × Nat × Nat) := do
    -- Hosts follow one another on one queue: each has source ids of its own.
    let requests ← ids.modifyGet fun next => (next, next + 6)
    reloads.set #[]
    try
      Headless.withHost (scheme := TestScheme.scheme) (guard := patience)
          { elaborator, source := memorySource jobsConfig, emit,
            services := { completions, timers := counted }, published := ← Snapshots.new,
            held := ← Job.HeldSnapshots.new, requests, wakeups := requests + 1,
            jobs := requests + 2, environment := requests + 3, posts := requests + 4
            pauseEvents := requests + 5
            -- It keeps the activity count the headless mode keeps, so the
            -- latency measured is the loop's with the count's steps in it
            -- (`docs/design/concurrency.md`, "The idle signal").
            tracksIdle := true } fun host => do
          host.send .reload
          unless ← host.settle patience do
            throw (IO.userError "the config did not load")
          let lines ← reloads.get
          unless lines.any fun line => (line.splitOn "installed").length > 1 do
            throw (IO.userError ("the config was not installed: " ++ "; ".intercalate lines.toList))
          for _ in [0:count] do
            host.send (.spawn job)
          unless ← host.settle patience do
            throw (IO.userError "the editor thread did not answer")
          going
          let waitsBefore ← waits.get
          let began ← IO.monoNanosNow
          let mut times := #[]
          for _ in [0:samples] do
            let sample ← IO.Promise.new
            slot.set (some sample)
            let asked ← IO.monoNanosNow
            host.send (.run "noop")
            let some ran ← IO.wait sample.result? | throw (IO.userError "a sample was lost")
            times := times.push (ran - asked)
          return (times, (← waits.get) - waitsBefore, (← IO.monoNanosNow) - began)
    finally
      discard <| Job.Pool.warm pool rewarm
  -- Waits until the clock has been read `count` more times: so many jobs
  -- have reached a request, so the pool is computing.
  let computing (count : Nat) : IO Unit := do
    let before ← reads.get
    -- The jobs' reads of the clock, re-read each millisecond in this
    -- opt-in bench (never part of `ci`); only jobs that never get going
    -- reach the guard, and the row then fails as a hang.
    let deadline ← patience.deadline
    while (← reads.get) < before + count do
      if ← deadline.expired then
        throw (IO.userError "a hang: the computing jobs did not get going")
      RealTime.sleep (.under "the bench's re-read of the jobs' clock reads" 1)
  let idle := Row.of "idle" (← row "ticker" 0 (pure ())).1
  let (sleepingTimes, completed, elapsed) ← row "ticker" 64 (pure ())
  let sleeping :=
    Row.of "64 jobs each sleeping 1 ms" sleepingTimes
      s!"   ({completed * 1000000000 / max elapsed 1} completions a second through the pump)"
  let one := Row.of s!"{pool} interpreted jobs computing" (← row "spin" pool (computing pool)).1
  let two :=
    Row.of s!"{2 * pool} interpreted jobs computing" (← row "spin" (2 * pool) (computing pool)).1
  let again := Row.of "idle again" (← row "ticker" 0 (pure ())).1
  -- The cost of a request that needs no wait, in a compiled job on the
  -- library's clock.
  let count := 1000000
  let finished ← IO.Promise.new
  let started ← IO.monoNanosNow
  discard <|
      Job.spawn { completions, timers := real } (readings count) do
        finished.resolve (← IO.monoNanosNow)
  let some ended ← IO.wait finished.result? | throw (IO.userError "the reading job was lost")
  let rows := [idle, sleeping, one, two, again]
  let loaded := [sleeping, one, two]
  IO.println s!"pool: {pool} threads; {samples} samples a row"
  IO.println
      "latency of the editor loop, from posting `run noop` to the editor thread having run it, in µs: median / 99th percentile / maximum"
  for row in rows do
    IO.println row.line
  IO.println
      s!"a `now` request answered by the library: {(ended - started) / count} ns each (mean of {count} in one job)"
  IO.println
      ("within bound (median within twice the larger idle median, 99th percentile under 100 µs): " ++
        "; ".intercalate
          (loaded.map fun row =>
            s!"{row.name}: {if row.withinBound idle again then "yes" else "no"}"))
  let late := rows.filter (·.maximum > 1000000)
  unless late.isEmpty do
    IO.println ("maximum over 1 ms: " ++ ", ".intercalate (late.map (·.name)))
  (← IO.getStdout).flush
  return 0

/-! ### The prompt benchmark

`bench-prompt` measures what a key costs in a prompt over many candidates
(`mise run prompt-bench`), and what the listing costs once the match is
made off the editor thread. Like the others it is a measuring tool: the gate
builds it and never runs it, and no number it prints is an expected value.

Each row runs a headless host on the real queue and the real library, the
matcher among it (`Fuzzy.real`), with the recorder as its display. The
prompt is asked by a compiled command with a source given as a value over
`manyPaths`, paths of about 40 bytes. A sample is one key of the six of
`src/f1`, committed into the open prompt as typed text, and a `run noop`
sent right after it: timed from sending the key to the editor thread
printing that it ran `noop`, read on the editor thread as `bench-jobs`
reads it. So a sample is the key's step, its scene published, and one
empty step after it, which the row with no candidates measures alone. In
the worker row the listing's latency is timed too, from sending the key to
the editor thread printing that the match job's command ran; then the row
joins, so the next key finds no match in flight. After the sixth key the
prompt is cancelled and asked again, untimed.

The file row is `open-file`'s prompt over a fake file service holding one
directory of 10,000 files, its host's working directory: the prompt lists
it once, joined and untimed, and each timed key is typed within the
directory, so no listing is started for it and the match runs off the
editor thread with the path style; each key is joined, as the worker row's
are. It is judged by the same bound.

The row at typing cadence joins nothing: the keys are sent `cadence` ms
apart whatever the match is doing, so a key arrives while a match runs or
while its delivery is handled, which a key typed fast meets. The bound is
judged on it and on the joined worker row.

The insert rows complete at point through the core's test kit's at-point
package (`withKitAtPoint`, `Editor/Test/AtPoint.lean`) and a source written
here (`benchAtPoint`), which answers later from a job of the job model's
(`Completion.Later.batches`) over the words the open buffers hold, and
reads the open buffers' texts, so the snapshots are still taken. The cost of
the shipped `words`' own gathering is not measured here: it left this bench
with the `at-point` package. -/

/-- The command of a host of the prompt benchmark: asks `Pick: ` with a
source given as a value over `manyPaths count`. -/
def askingMany (count : Nat) : Config.Registration :=
  { name := "ask-many"
    action :=
      .plain
        (discard <|
          prompt "Pick: " { command := "picked" } ""
            [.given (.ofTexts "many" "pick" (manyPaths count))]) }

/-- The words `makeWordBuffers`' buffers hold, each once: the one batch the
job of `benchAtPoint`'s source answers. -/
def benchWords : Array Completion.Candidate :=
  (List.range 4999).toArray.map fun i => .ofText s!"word{i}_{i % 97}"

/-- The insert rows' completion at point: the source `bench-words`, which
answers later from its job `bench-words` (`Completion.Later.batches` over
`benchWords`), is asked once and reads the open buffers' texts; the
at-point source `bench-words`, the run of word characters before the
cursor on its line completed from it, asked by itself after a pause of 240
ms; and, when `used`, its use in every buffer, so the insert rows' host
without completion at point differs from the other's in that alone. -/
def benchAtPoint (used : Bool) : Package :=
  { name := "bench-at-point"
    setup := do
      workJob "bench-words" (Completion.Later.batches #[benchWords])
      defineSource
          { name := "bench-words", category := "bench-words", candidates := fun _ => pure #[]
            later := some { job := "bench-words", reask := .never, readsTexts := true } }
      defineAtPoint
          { name := "bench-words", pause := some 240
            ask := fun spot => do
              let .ok target ← spot.view.target | return none
              let text := target.buffer.text
              let lineStart ← text.motion .lineStart spot.offset
              let line ← text.slice lineStart spot.offset
              let word := String.ofList (line.toList.reverse.takeWhile wordCharacter).reverse
              return some
                  { start := spot.offset - word.utf8ByteSize, stop := spot.offset
                    sources := [.source "bench-words"] } }
      if used then
        useAtPoint "bench-words" }

/-- How far apart the keys of the row typed at typing cadence are sent, in
milliseconds: faster than anyone types, and shorter than a match of
100,000 takes, so keys arrive while a match runs and while its delivery is
handled. -/
def cadence : Nat :=
  20

/-- About 50 KB of generated words, `word<i % 4999>_<i % 4999 % 97>` for `i` from
`first`, space-separated: one open buffer of the auto-popup row of the
prompt benchmark. -/
def wordText (first : Nat) : String :=
  " ".intercalate
    ((List.range 5000).map fun index =>
      let i := first + index
      s!"word{i % 4999}_{i % 4999 % 97}")

/-- Makes 20 buffers of `wordText`, about 5,000 distinct words in all: what
the auto-popup row of the prompt benchmark completes from. -/
def makeWordBuffers : EditorM Unit := do
  for index in [0:20] do
    discard <| createBuffer s!"words-{index}" (wordText (index * 5000))

/-- `bench-prompt`: what a key costs in a prompt with no candidates, over
1,000, 10,000 and 100,000 candidates listed inline (the limit lifted), and
over 100,000 matched off the editor thread, keys joined and back to back;
and what a word key that types costs under the test scheme, on the kit's
editing commands, with no at-point source, and with `benchAtPoint`'s source
popping up by itself over 20 open buffers; and what a key costs in `open-file`'s prompt over a
directory of 10,000 files; `samples` keys a row. -/
def prompt (sysroot oleanDir : String) (samples : Nat) : IO UInt8 := do
  let pool := (← Job.Pool.warm Job.Pool.size Headless.warmPatience).size
  let completions ← Job.Completions.new
  discard <| IO.asTask (prio := .dedicated) (Job.pump completions)
  let timers := Job.realTimers completions
  let (elaborator, _) ← measured sysroot oleanDir
  let ids ← IO.mkRef (1 : UInt64)
  let refused ← IO.mkRef 0
  -- The editor thread reads the clock when it prints that it ran `noop`, and
  -- when it prints that a match job's listing was delivered.
  let ranSlot ← IO.mkRef (none : Option (IO.Promise Nat))
  let listedSlot ← IO.mkRef (none : Option (IO.Promise Nat))
  let emit (line : String) : IO Unit := do
    if line == "run noop: ok" then
      if let some sample← ranSlot.modifyGet fun slot => (slot, none) then
        sample.resolve (← IO.monoNanosNow)
    else if line.endsWith s!" {Loop.matchLabel}: ok" then
      if let some sample← listedSlot.modifyGet fun slot => (slot, none) then
        sample.resolve (← IO.monoNanosNow)
    else if line.startsWith "loop: refused" then
      refused.modify (· + 1)
  let keys := ["s", "r", "c", "/", "f", "1"]
  -- One row: a host of its own asks the prompt over `count` candidates,
  -- with `inline` as its inline limit; then the samples. Returns each key's
  -- latency and, when `listing`, each listing's.
  let row (count inline : Nat) (listing : Bool) (joined : Bool := true) :
    IO (Array Nat × Array Nat) := do
    let requests ← ids.modifyGet fun next => (next, next + 6)
    try
      Headless.withHost (scheme := TestScheme.scheme) (guard := patience)
          { elaborator, source := memorySource [], emit,
            services := { completions, timers, fuzzy := Fuzzy.real }, published := ← Snapshots.new,
            held := ← Job.HeldSnapshots.new, requests, wakeups := requests + 1,
            jobs := requests + 2, environment := requests + 3, posts := requests + 4,
            pauseEvents := requests + 5,
            packages :=
              #[listingsPackage, Test.Shipped.modeLine, Test.Minibuffer.package,
                Compiled.package
                  {
                    commands :=
                      #[askingMany count, { name := "noop", action := .plain (pure ()) }] }]
            inlineMatches := inline } fun host => do
          let ask : IO Unit := do
            host.send (.run "ask-many")
            unless (← host.join patience) == .settled do
              throw (IO.userError "the prompt did not open")
          ask
          let mut keyTimes := #[]
          let mut listingTimes := #[]
          for sample in [0:samples] do
            let index := sample % keys.length
            if index == 0 && sample > 0 then
              host.send (.run Test.Minibuffer.cancelName)
              ask
            let ran ← IO.Promise.new
            let listed ← IO.Promise.new
            ranSlot.set (some ran)
            listedSlot.set (if listing then some listed else none)
            let asked ← IO.monoNanosNow
            host.commit (keys[index]?.getD "x")
            host.send (.run "noop")
            let some handled ← IO.wait ran.result? | throw (IO.userError "a key was lost")
            keyTimes := keyTimes.push (handled - asked)
            if listing then
              let some delivered ←
                IO.wait listed.result? | throw (IO.userError "a listing was lost")
              listingTimes := listingTimes.push (delivered - asked)
            if joined then
              unless (← host.join patience) == .settled do
                throw (IO.userError "a listing was not delivered")
            else
              -- real time under test: the typing cadence the row measures at,
              -- the next key a moment later whatever the match is doing.
              IO.sleep cadence.toUInt32
          return (keyTimes, listingTimes)
    finally
      discard <| Job.Pool.warm pool rewarm
  let lifted := 1000000000
  let idle := Row.of "no candidates" (← row 0 lifted false).1
  let hundred := Row.of "100 inline" (← row 100 lifted false).1
  let quarter := Row.of "250 inline" (← row 250 lifted false).1
  let half := Row.of "500 inline" (← row 500 lifted false).1
  let thousand := Row.of "1,000 inline" (← row 1000 lifted false).1
  let tenThousand := Row.of "10,000 inline" (← row 10000 lifted false).1
  let inline := Row.of "100,000 inline (limit lifted)" (← row 100000 lifted false).1
  let (workerKeys, workerListings) ← row 100000 Loop.inlineMatches true
  let worker := Row.of "100,000 on the worker" workerKeys
  let listed := Row.of "  its listing, key to delivery" workerListings
  let backToBack :=
    Row.of s!"100,000 on the worker, keys {cadence} ms apart"
      (← row 100000 Loop.inlineMatches false false).1
  -- The insert rows: a host of the test scheme, as `withShippedHost`
  -- builds one, on a fake clock of its own, with the real library, queue and
  -- recorder, typing through the kit's editing commands
  -- (`Test.editingPackage`) and completing at point through the kit's
  -- package and `benchAtPoint`; `atPoint` says whether its source is used in
  -- every buffer. Each sample types two word keys, timed; with `atPoint`,
  -- moves the clock past the pause and joins the source's job, untimed;
  -- types four more word keys, timed; and quits the session, if one is open,
  -- and undoes each key, untimed. What a key costs under the Vim scheme
  -- that ships is `mise run milestone-bench`'s `type-insert`, on the
  -- default editor.
  let insertRow (atPoint : Bool) : IO (Array Nat) := do
    let requests ← ids.modifyGet fun next => (next, next + 6)
    let waits ← Job.Completions.new
    let clock ← Job.FakeClock.new waits
    let published ← Snapshots.new
    let services : Job.Services :=
      { completions := waits, timers := clock.timers, fuzzy := Fuzzy.real
        snapshots := Job.realSnapshots published.reader }
    let packages :=
      (withKitAtPoint shippedPackages ++ #[benchAtPoint atPoint, Test.editingPackage]).push
        (Compiled.package
          {
            commands :=
              #[{ name := "noop", action := .plain (pure ()) },
                { name := "make-buffers", action := .plain makeWordBuffers }] })
    let shipped :=
      Headless.shippedOver TestScheme.scheme packages #[`Editor] sysroot
        (ModuleLookup.searchPath oleanDir) "" emit services published (← Job.HeldSnapshots.new)
        (← Config.Elaborate.ModuleFiles.temporary)
    try
      Headless.withHost (guard := patience)
          { shipped with
            source := memorySource [], requests, wakeups := requests + 1
            jobs := requests + 2, environment := requests + 3, posts := requests + 4
            pauseEvents := requests + 5, clock := some clock, log := fun _ => pure () }
          fun host => do
          host.send (.run "make-buffers")
          unless (← host.join patience) == .settled do
            throw (IO.userError "the buffers were not made")
          let timed (key : String) : IO Nat := do
            let ran ← IO.Promise.new
            ranSlot.set (some ran)
            let asked ← IO.monoNanosNow
            for pressed in keysOf key do
              host.press pressed
            host.send (.run "noop")
            let some handled ← IO.wait ran.result? | throw (IO.userError "a key was lost")
            return handled - asked
          let untimed (text : String) : IO Unit := do
            for pressed in keysOf text do
              host.press pressed
            unless (← host.join patience) == .settled do
              throw (IO.userError "the keys were not handled")
          let mut times := #[]
          for _ in [0:(samples + 5) / 6] do
            for key in ["w", "o"] do
              times := times.push (← timed key)
            if atPoint then
              unless ← clock.dueWithin 240 do
                throw (IO.userError "no pause was armed")
              clock.advance 240
              unless (← host.join patience) == .settled do
                throw (IO.userError "the candidates were not delivered")
            for key in ["r", "d", "1", "_"] do
              times := times.push (← timed key)
            if atPoint then
              host.send (.run Test.AtPoint.quitName)
            untimed "C-z C-z C-z C-z C-z C-z"
          return times
    finally
      discard <| Job.Pool.warm pool rewarm
  -- The file row: a host of the test scheme whose jobs reach a fake file
  -- service over one directory of `count` files, `/big`, its working
  -- directory, with the file prompt's commands, source, job and style.
  -- `open-file` asks with `/big/` and lists it, joined, untimed; the timed
  -- keys are typed within the directory, as the worker row times them, each
  -- joined.
  let fileRow (count : Nat) : IO (Array Nat) := do
    let requests ← ids.modifyGet fun next => (next, next + 6)
    let model :=
      (List.range count).foldl
        (fun (model : FileModel) index => model.withFile ("/big" / s!"f{10000 + index}") .empty)
        (({} : FileModel).withDirectory "/big")
    let files ← Job.FakeFiles.new completions model
    try
      Headless.withHost (scheme := TestScheme.scheme) (guard := patience)
          { elaborator, source := memorySource [], emit,
            services := { completions, timers, fuzzy := Fuzzy.real, files := files.files }
            published := ← Snapshots.new, held := ← Job.HeldSnapshots.new, requests,
            wakeups := requests + 1, jobs := requests + 2, environment := requests + 3,
            posts := requests + 4, pauseEvents := requests + 5,
            packages :=
              #[listingsPackage, Test.Shipped.modeLine, FilesApiTest.fake, Test.Minibuffer.package,
                Compiled.package { commands := #[{ name := "noop", action := .plain (pure ()) }] }]
            workingDirectory := "/big" } fun host => do
          let ask : IO Unit := do
            host.send (.run FileJobs.openFileCommand)
            unless (← host.join patience) == .settled do
              throw (IO.userError "the file prompt did not list its directory")
          ask
          let fileKeys := ["f", "1", "2", "3", "4", "5"]
          let mut keyTimes := #[]
          for sample in [0:samples] do
            let index := sample % fileKeys.length
            if index == 0 && sample > 0 then
              host.send (.run Test.Minibuffer.cancelName)
              ask
            let ran ← IO.Promise.new
            ranSlot.set (some ran)
            listedSlot.set none
            let asked ← IO.monoNanosNow
            host.commit (fileKeys[index]?.getD "x")
            host.send (.run "noop")
            let some handled ← IO.wait ran.result? | throw (IO.userError "a key was lost")
            keyTimes := keyTimes.push (handled - asked)
            unless (← host.join patience) == .settled do
              throw (IO.userError "a listing was not delivered")
          return keyTimes
    finally
      discard <| Job.Pool.warm pool rewarm
  let fileTenThousand := Row.of "open-file, 10,000 entries" (← fileRow 10000)
  let plainInsert := Row.of "insert, no at-point" (← insertRow false)
  let autoPopup := Row.of "insert, auto popup, 20 buffers" (← insertRow true)
  let rows :=
    [idle, hundred, quarter, half, thousand, tenThousand, inline, worker, listed, backToBack,
      fileTenThousand, plainInsert, autoPopup]
  let inlineRows := [(100, hundred), (250, quarter), (500, half), (1000, thousand)]
  IO.println
      s!"pool: {pool} threads; {samples} keys a row, each of `src/f1` committed into the prompt; inline limit {Loop.inlineMatches}"
  IO.println
      "latency of a key, from sending it to the editor thread having handled it and published its scene, in µs: median / 99th percentile / maximum"
  for row in rows do
    IO.println row.line
  IO.println
      ("within bound (median within twice the no-candidates median, 99th percentile under 1 ms): " ++
        "; ".intercalate
          ([worker, backToBack, fileTenThousand].map fun row =>
            s!"{row.name}: {if row.keyWithinBound idle then "yes" else "no"}"))
  -- What auto popup adds to a typed key in insert state is judged against
  -- the same key with no at-point source, not against a key of the prompt.
  IO.println
      s!"within bound (median within twice the insert, no at-point median, 99th percentile under 1 ms): {autoPopup.name}: {if autoPopup.keyWithinBound plainInsert then "yes" else "no"}"
  let under := inlineRows.filter (·.2.high < keyBound)
  IO.println
      s!"inline rows with the 99th percentile under 1 ms: {", ".intercalate (under.map (·.2.name))}; the largest such size is {(under.map (·.1)).foldl max 0} (the inline limit is {Loop.inlineMatches})"
  let late := rows.filter (·.maximum > keyBound)
  unless late.isEmpty do
    IO.println ("maximum over 1 ms: " ++ ", ".intercalate (late.map (·.name)))
  if (← refused.get) > 0 then
    IO.println s!"refused steps: {← refused.get}"
  (← IO.getStdout).flush
  return 0

/-- A text of about `size` bytes in lines of 52, as `milestone-bench`
generates its file: `%07d the quick brown fox jumps over the lazy dog`. -/
def journalText (size : Nat) : String :=
  Id.run do
    let mut text := ""
    let mut line := 0
    while text.utf8ByteSize < size do
      let number := toString line
      text :=
        text ++ "".pushn '0' (7 - number.length) ++ number ++
          " the quick brown fox jumps over the lazy dog\n"
      line := line + 1
    return text

/-- The store of lines the journal bench keeps across a restart, written
here in the shape of the shell's history (an array of lines, as a list of
strings), so the bench names no package's store. -/
def journalStore : Store (Array String) :=
  { name := "bench-history", version := 1, initial := #[]
    encode := fun lines => .list (lines.toList.map .str)
    decode := fun
      | .list items =>
        items.toArray.mapM fun
          | .str line => some line
          | _ => none
      | _ => none }

/-- The times of `inserts` one-character inserts into a file buffer of
`size` bytes at `position` (`start`, `middle` or `end`), each timed from
the reconciler (`Restore.journalOrders`) through handing its orders to the
library's file service (`Headless.Journal.real`), in nanoseconds: the
editor thread's share of the journal. The buffer's journal is under
`directory`; the loop's own work around an insert, its scene and its
history, is not timed. The state is phase 2's: two tabs of five windows,
four on the file, one of them with 100 jump entries, and an unscoped
store of 10,000 lines (`journalStore`), whose codec the reconciler is
handed, so what it keeps of the frame and the stores is there to cost. -/
def journalTimes (services : Job.Services) (published : Snapshots) (directory : System.FilePath)
    (size : Nat) (position : String) (inserts : Nat) : IO (Array Nat) := do
  let journal := Headless.Journal.real published.reader services
  IO.FS.createDirAll (Restore.journalsDirectory directory)
  let path := directory / s!"{size}-{position}.txt"
  let made : TextM EditorState := do
    let initial ← EditorState.initial ⟨640, 480⟩
    let text ← createText (journalText size)
    let history := { (← UndoTree.over text) with saved := none }
    let (_, state) := initial.addBuffer path.toString text history
    let (_, state) := state.attachFile ⟨1⟩ path { seconds := 0, nanoseconds := 0, size } .lf
    -- Two tabs, five windows: views 0 to 2 in the first, 3 and 4 in the
    -- second, all but view 0 on the file.
    let mut windows := state.windows
    for view in [1:5] do
      let scroll ← text.mark (.anchor { offset := 0, bias := .before })
      let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩] })
      let mut jumps : Jumps := {}
      if view == 1 then
        let mut entries := #[]
        for entry in [0:100] do
          entries :=
            entries.push
              (Place.held ⟨1⟩ (← text.mark (.anchor { offset := entry, bias := .after })))
        jumps := { list := { entries, index := entries.size } }
      windows := windows.push { id := ⟨view⟩, buffer := ⟨1⟩, scroll, selection, jumps }
    let history : Array String := (Array.range 10000).map fun line => s!":!echo {line}"
    return { state with
        windows, nextView := 5
        frame :=
          { state.frame with
            windows := #[⟨0⟩, ⟨1⟩, ⟨2⟩],
            tabsAfter := #[{ windows := #[⟨3⟩, ⟨4⟩], focused := ⟨3⟩ }] }
        workspaces :=
          state.workspaces.setUnscopedValue journalStore.name (journalStore.encode history)
        stateDirectory := some directory, restore := { run := some 1, restored := true } }
  let (made, texts) ← made.runReal (RealTexts.over published)
  let .ok first := made | throw (IO.userError "bench-journal: the state could not be made")
  let mut state := first
  let mut texts := texts
  let perform (orders : Array Restore.Order) (texts : RealTexts) : IO RealTexts := do
    for order in orders do
      journal.perform order
    let mut texts := texts
    for id in orders.filterMap (·.release) do
      texts := (← ((TextSource.snapshot id).release : TextM Unit).runReal texts).2
    return texts
  -- The first reconcile writes the base and the header.
  let context : Restore.Context :=
    {
      registered :=
        {
          codec? := fun name =>
            if name == journalStore.name then some ("bench", journalStore.codec) else none } }
  let (reconciled, after) ← (Restore.journalOrders state true false context).runReal texts
  let .ok reconciled :=
    reconciled | throw (IO.userError "bench-journal: the first reconcile was refused")
  state := reconciled.state
  texts ← perform reconciled.orders after
  let mut times := #[]
  for _ in [0:inserts] do
    let some buffer := state.buffer? ⟨1⟩ | throw (IO.userError "bench-journal: no buffer")
    let edit : TextM UndoTree := do
      let length ← buffer.text.byteLength
      let offset :=
        match position with
        | "start" => 0
        | "middle" => length / 2
        | _ => length
      buffer.text.insert offset "x"
      return buffer.history.record (← buffer.text.revision)
    let (history, after) ← edit.runReal texts
    let .ok history := history | throw (IO.userError "bench-journal: an insert was refused")
    texts := after
    state := (state.setHistory ⟨1⟩ history).2
    let began ← IO.monoNanosNow
    let (reconciled, after) ← (Restore.journalOrders state true false context).runReal texts
    let .ok reconciled := reconciled | throw (IO.userError "bench-journal: a reconcile was refused")
    texts ← perform reconciled.orders after
    times := times.push ((← IO.monoNanosNow) - began)
    state := reconciled.state
  -- What was handed is written before the next row starts: the journal's
  -- drain, a flush of the file service, bounded only as a hang guard.
  discard <| Job.awaitWithin (.on "the journal's drain" 30000) (← journal.drained)
  return times

/-- `bench-journal`: the session journal's cost on the editor thread, for
10,000 one-character inserts into a buffer of 4 KiB, 1 MiB and 10 MiB at its
start, middle and end (`journalTimes`), each row
`journal_order/<size>/<position>` with its median, 99th percentile and
maximum in µs. It asserts nothing; `mise run journal-bench` runs it, and
the gate never does. -/
def journal : IO UInt8 := do
  IO.println "bench-journal: median / p99 / max, µs per insert"
  -- One table of waits and its pump for the run, as the other benches have:
  -- the journal's drain is a flush of the file service through it.
  let completions ← Job.Completions.new
  discard <| IO.asTask (prio := .dedicated) (Job.pump completions)
  let published ← Snapshots.new
  let held ← Job.HeldSnapshots.new
  let services : Job.Services :=
    { completions, timers := Job.realTimers completions
      files := Job.realFiles completions published.reader held }
  Editor.Test.Linked.withFiles services fun directory => do
      for (size, label) in [(4096, "4KiB"), (1048576, "1MiB"), (10485760, "10MiB")] do
        for position in ["start", "middle", "end"] do
          let times ← journalTimes services published directory size position 10000
          IO.println (Row.of s!"journal_order/{label}/{position}" times).line
  return 0

end Bench

end ConfigTest
