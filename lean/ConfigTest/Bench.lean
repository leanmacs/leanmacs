import ConfigTest.Support.Candidates
import ConfigTest.Support.Keys
import Editor.Api
import Editor.Clipboard
import Editor.Clipboard.InProcess
import Editor.Command
import Editor.Compile.Contribution
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Displays
import Editor.Completion.Styles
import Editor.Config.Elaborate
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Session
import Editor.Event
import Editor.Ex.Line
import Editor.Face
import Editor.File.Model
import Editor.Files
import Editor.Files.Compiled
import Editor.Fuzzy
import Editor.Fuzzy.Real
import Editor.Headless
import Editor.InputScheme.Test
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Job
import Editor.Job.Fake
import Editor.Job.Pool
import Editor.Job.Real
import Editor.Job.Runner
import Editor.Language
import Editor.Loop
import Editor.Menu
import Editor.Minibuffer
import Editor.Minibuffer.Compiled
import Editor.Mode
import Editor.ModeLine
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.SyntaxTree
import Editor.SyntaxTree.Real
import Editor.Text
import Editor.Text.Model
import Editor.Text.Real
import Editor.Watch
import Editor.Workspace.Compiled
import Editor.Workspace.FindFile

/-!
# Config tests: the benchmark

The benchmark of the config session, `ConfigTest.Bench`: the `bench-*` commands
of `config-test`, which the root module `ConfigTest` runs from `main`. It
measures and asserts nothing of its own, so it mirrors no module; its sections
say what each command measures.
-/

namespace ConfigTest

open Editor

/-! ## The benchmark

Three subcommands measure the config session (`mise run config-bench`, which
runs each in a fresh process under `/usr/bin/time -l`). They are a measuring
tool: they assert nothing but that every reload installed, the gate builds
them and never runs them, and no number they print is an expected value.

Each loads config through the headless host, as the editor does, from a
source held in memory, so they touch no files. A time is from the request
for a reload to its report, on Lean's monotonic clock. -/

namespace Bench

/-- How long a measurement waits, in milliseconds, for one reload. -/
def patience : Nat :=
  120000

/-- A host to measure: its source is `chunks`, and it notes when each
reload's report is printed. -/
structure Rig where
  /-- The host. -/
  host : Headless.Host
  /-- The config the host's source holds. -/
  chunks : IO.Ref (Array Config.SourceChunk)
  /-- The last reload's report line, and the monotonic time, in nanoseconds,
  at which it was printed. -/
  reported : IO.Ref (Option (String × Nat))
  /-- Every other line the host printed since the last request: the
  diagnostics of a reload that went wrong. -/
  others : IO.Ref (Array String)

namespace Rig

/-- Starts a host over `elaborator` and a source in memory. -/
def start (elaborator : Config.Elaborator Config.Elaborate.State) : IO Rig := do
  let chunks ← IO.mkRef #[]
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
  let host ←
    Headless.start (scheme := TestScheme.scheme)
        { elaborator, source := { chunks := chunks.get }, emit,
          services := { completions, timers := clock.timers }, published := ← Snapshots.new,
          held := ← Job.HeldSnapshots.new, requests := 1, wakeups := 2, jobs := 3, environment := 4,
          posts := 5, pauseEvents := 6 }
  return { host, chunks, reported, others }

/-- Makes `config` the source's chunks, asks for a reload, and returns the
nanoseconds from the request to the report. Throws unless the reload was
installed. -/
def reload (rig : Rig) (config : Array Config.SourceChunk) : IO Nat := do
  rig.chunks.set config
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

/-- A config of one chunk of one line, which differs with `round`. -/
def oneLine (round : Nat) : Array Config.SourceChunk :=
  #[{ name := "one.lean",
      text := "def setup : SetupM Unit := command \"round" ++ toString round ++ "\" (pure ())\n" }]

/-- A config of one chunk of twenty lines, which differs with `round`. -/
def twentyLines (round : Nat) : Array Config.SourceChunk :=
  #[{ name := "twenty.lean",
      text :=
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
          ")\n" }]

/-- A config of one chunk of fifty definitions, a theorem proved by `simp`
and a `setup`, which differs with `round`. -/
def fiftyDefinitions (round : Nat) : Array Config.SourceChunk :=
  let definitions :=
    (List.range 50).map fun index => s!"def f{index} (n : Nat) : Nat := n * {index} + {index}\n"
  #[{ name := "fifty.lean",
      text :=
        String.join definitions ++ "theorem f1_spec (n : Nat) : f1 n = n + 1 := by simp [f1]\n" ++
          s!"def round : Nat := {round}\n" ++
          "def setup : SetupM Unit := command \"round\" (pure ())\n" }]

/-- Nanoseconds as milliseconds with one decimal. -/
def milliseconds (nanoseconds : Nat) : String :=
  let tenths := (nanoseconds + 50000) / 100000
  s!"{tenths / 10}.{tenths % 10}"

/-- The median and the maximum of `times`, as milliseconds. -/
def medianAndMaximum (times : Array Nat) : String :=
  let sorted := times.qsort (· < ·)
  let median := (sorted.getD ((sorted.size - 1) / 2) 0 + sorted.getD (sorted.size / 2) 0) / 2
  s!"median {milliseconds median} ms, maximum {milliseconds (sorted.back?.getD 0)} ms"

/-- `bench-start`: imports the base with `modules`, then loads the twenty-line
config through a host, and prints how long each took. -/
def start (sysroot oleanDir : String) (modules : List String) : IO UInt8 := do
  let real :=
    Config.Elaborate.elaborator
      { sysroot, oleanDir, imports := (modules.map String.toName).toArray }
  let before ← IO.monoNanosNow
  let base ← real.base
  let imported := (← IO.monoNanosNow) - before
  let rig ← Rig.start { real with base := pure base }
  let first ← rig.reload (twentyLines 0)
  IO.println
      s!"bench-start {modules}: import {milliseconds imported} ms, first load {milliseconds first} ms"
  return 0

/-- `bench-reload`: twenty reloads of each of the three configs, each reload
with the text changed, and prints the median and the maximum of each. -/
def reload (sysroot oleanDir : String) : IO UInt8 := do
  let rig ← Rig.start (Config.Elaborate.elaborator { sysroot, oleanDir })
  -- The first load imports the base; it is not one of the twenty.
  discard <| rig.reload (oneLine 0)
  let configs :=
    [("one-line chunk", oneLine), ("20-line config", twentyLines),
      ("50 definitions and a simp proof", fiftyDefinitions)]
  for (name, config) in configs do
    let mut times := #[]
    for round in [1:21] do
      times := times.push (← rig.reload (config round))
    IO.println s!"bench-reload: {name}: {medianAndMaximum times}"
  return 0

/-- `bench-modules`: imports the base with `modules` and prints the name of
every module the import read, one a line and unescaped, so that
`tools/stage-bundle.sh --closure` can map each to its files. -/
def modules (sysroot oleanDir : String) (modules : List String) : IO UInt8 := do
  let environment ←
    Config.Elaborate.importBase
        { sysroot, oleanDir, imports := (modules.map String.toName).toArray }
  for name in environment.allImportedModuleNames do
    IO.println (name.toString (escape := false))
  return 0

/-- `bench-soak`: `count` reloads of the fifty-definition config, each with
the text changed, and prints the mean time of one. -/
def soak (sysroot oleanDir : String) (count : Nat) : IO UInt8 := do
  let rig ← Rig.start (Config.Elaborate.elaborator { sysroot, oleanDir })
  discard <| rig.reload (fiftyDefinitions 0)
  let mut total := 0
  for round in [1:count + 1] do
    total := total + (← rig.reload (fiftyDefinitions round))
  IO.println s!"bench-soak: {count} reloads, mean {milliseconds (total / count)} ms per reload"
  return 0

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
def jobsConfig : Array Config.SourceChunk :=
  #[{ name := "jobs.lean",
      text :=
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
" }]

/-- What the samples of one row came to, in nanoseconds. -/
structure Row where
  /-- What ran while the row was measured. -/
  name : String
  /-- The median latency. -/
  median : Nat
  /-- The 99th percentile. -/
  high : Nat
  /-- The largest sample. -/
  maximum : Nat
  /-- What to say after the numbers, if anything. -/
  note : String := ""

/-- The row of `times`, which need not be sorted. -/
def Row.of (name : String) (times : Array Nat) (note : String := "") : Row :=
  let sorted := times.qsort (· < ·)
  { name, median := (sorted.getD ((sorted.size - 1) / 2) 0 + sorted.getD (sorted.size / 2) 0) / 2,
    high := sorted.getD (min (sorted.size * 99 / 100) (sorted.size - 1)) 0,
    maximum := sorted.back?.getD 0, note }

/-- Nanoseconds as microseconds with one decimal. -/
def microseconds (nanoseconds : Nat) : String :=
  let tenths := (nanoseconds + 50) / 100
  s!"{tenths / 10}.{tenths % 10}"

/-- A row as a line of the report: its name, padded, then the median, the
99th percentile and the maximum. -/
def Row.line (row : Row) : String :=
  let label := row.name ++ ":"
  s!"  {label.pushn ' ' (36 - label.length)}{microseconds row.median} / {microseconds row.high} / {microseconds row.maximum}{row.note}"

/-- What the 99th percentile of a loaded row must stay under, in nanoseconds:
100 µs. -/
def highBound : Nat :=
  100000

/-- Whether a loaded row is within the bound the job system was accepted
against, as an observation about one run: its median is at most twice the
larger of the two idle medians, and its 99th percentile is under 100 µs. The
maximum is not judged: one scheduling delay sets it. -/
def Row.withinBound (row before after : Row) : Bool :=
  row.median ≤ 2 * max before.median after.median && row.high < highBound

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
  let pool := (← Job.Pool.warm Job.Pool.size 200).size
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
  let adapter := Config.Elaborate.elaborator { sysroot, oleanDir }
  let base ← adapter.base
  let elaborator := { adapter with base := pure base }
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
    let host ←
      Headless.start (scheme := TestScheme.scheme)
          { elaborator, source := { chunks := pure jobsConfig }, emit,
            services := { completions, timers := counted }, published := ← Snapshots.new,
            held := ← Job.HeldSnapshots.new, requests, wakeups := requests + 1,
            jobs := requests + 2, environment := requests + 3, posts := requests + 4
            pauseEvents := requests + 5 }
    try
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
      discard <| host.halt patience
      discard <| Job.Pool.warm pool 5000
  -- Waits until the clock has been read `count` more times: so many jobs
  -- have reached a request, so the pool is computing.
  let computing (count : Nat) : IO Unit := do
    let before ← reads.get
    unless ← Headless.within patience (return (← reads.get) >= before + count) do
      throw (IO.userError "the computing jobs did not get going")
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
judged on it and on the joined worker row. -/

/-- The command of a host of the prompt benchmark: asks `Pick: ` with a
source given as a value over `manyPaths count`. -/
def askingMany (count : Nat) : Config.Registration :=
  { name := "ask-many"
    action :=
      .plain
        (discard <|
          prompt "Pick: " { command := "picked" } ""
            [.given (.ofTexts "many" "pick" (manyPaths count))]) }

/-- What the 99th percentile of a key's latency must stay under, in
nanoseconds: 1 ms. -/
def keyBound : Nat :=
  1000000

/-- How far apart the keys of the row typed at typing cadence are sent, in
milliseconds: faster than anyone types, and shorter than a match of
100,000 takes, so keys arrive while a match runs and while its delivery is
handled. -/
def cadence : Nat :=
  20

/-- Whether a row of keys is within the bound the plan set for matching off
the editor thread: its median at most twice the idle row's, and its 99th
percentile under 1 ms. The auto-popup row is judged with the plain insert
row as its idle row: the same key with no at-point source. -/
def Row.keyWithinBound (row idle : Row) : Bool :=
  row.median ≤ 2 * idle.median && row.high < keyBound

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
and what a word key costs in insert state under the Vim scheme that ships,
with no at-point source, and with the shipped `words` popping up by itself
over 20 open buffers; and what a key costs in `open-file`'s prompt over a
directory of 10,000 files; `samples` keys a row. -/
def prompt (sysroot oleanDir : String) (samples : Nat) : IO UInt8 := do
  let pool := (← Job.Pool.warm Job.Pool.size 200).size
  let completions ← Job.Completions.new
  discard <| IO.asTask (prio := .dedicated) (Job.pump completions)
  let timers := Job.realTimers completions
  let elaborator := Config.Elaborate.elaborator { sysroot, oleanDir }
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
    let host ←
      Headless.start (scheme := TestScheme.scheme)
          { elaborator, source := { chunks := pure #[] }, emit,
            services := { completions, timers, fuzzy := Fuzzy.real }, published := ← Snapshots.new,
            held := ← Job.HeldSnapshots.new, requests, wakeups := requests + 1,
            jobs := requests + 2, environment := requests + 3, posts := requests + 4,
            pauseEvents := requests + 5,
            commands :=
              (Minibuffer.package.registered.commands.push (askingMany count)).push
                { name := "noop", action := .plain (pure ()) }
            modes := Minibuffer.package.registered.modes, inlineMatches := inline }
    try
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
          host.send (.run Minibuffer.cancelName)
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
          let some delivered ← IO.wait listed.result? | throw (IO.userError "a listing was lost")
          listingTimes := listingTimes.push (delivered - asked)
        if joined then
          unless (← host.join patience) == .settled do
            throw (IO.userError "a listing was not delivered")
        else
          -- Typing cadence: the next key comes a moment later, whatever
          -- the match is doing.
          IO.sleep cadence.toUInt32
      return (keyTimes, listingTimes)
    finally
      discard <| host.halt patience
      discard <| Job.Pool.warm pool 5000
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
  -- The insert rows: a host of the Vim scheme that ships, as `withVimHost`
  -- builds one, on a fake clock of its own, with the real library, queue and
  -- recorder; `atPoint` says whether the shipped `words` is used in every
  -- buffer. Each sample types two word keys, timed; with `atPoint`, moves the
  -- clock past the pause and joins the `words` job, untimed; types four more
  -- word keys, timed; and leaves insert state and undoes, untimed.
  let insertRow (atPoint : Bool) : IO (Array Nat) := do
    let requests ← ids.modifyGet fun next => (next, next + 6)
    let waits ← Job.Completions.new
    let clock ← Job.FakeClock.new waits
    let published ← Snapshots.new
    let services : Job.Services :=
      { completions := waits, timers := clock.timers, fuzzy := Fuzzy.real
        snapshots := Job.realSnapshots published.reader }
    let shipped :=
      Headless.shippedOver sysroot oleanDir "" emit services published (← Job.HeldSnapshots.new)
    let host ←
      Headless.start
          { shipped with
            source := { chunks := pure #[] }, requests, wakeups := requests + 1
            jobs := requests + 2, environment := requests + 3, posts := requests + 4
            pauseEvents := requests + 5, clock := some clock, log := fun _ => pure ()
            atPointUses := if atPoint then shipped.atPointUses else #[]
            commands :=
              shipped.commands ++
                #[{ name := "noop", action := .plain (pure ()) },
                  { name := "make-buffers", action := .plain makeWordBuffers }] }
    try
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
        untimed "i"
        for key in ["w", "o"] do
          times := times.push (← timed key)
        if atPoint then
          unless ← clock.dueWithin 240 do
            throw (IO.userError "no pause was armed")
          clock.advance 240
          unless (← host.join patience) == .settled do
            throw (IO.userError "the words were not gathered")
        for key in ["r", "d", "1", "_"] do
          times := times.push (← timed key)
        untimed "<Escape> u"
      return times
    finally
      discard <| host.halt patience
      discard <| Job.Pool.warm pool 5000
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
    let host ←
      Headless.start (scheme := TestScheme.scheme)
          { elaborator, source := { chunks := pure #[] }, emit,
            services := { completions, timers, fuzzy := Fuzzy.real, files := files.files }
            published := ← Snapshots.new, held := ← Job.HeldSnapshots.new, requests,
            wakeups := requests + 1, jobs := requests + 2, environment := requests + 3,
            posts := requests + 4, pauseEvents := requests + 5,
            commands :=
              (Files.package.registered.commands ++ Minibuffer.package.registered.commands).push
                { name := "noop", action := .plain (pure ()) }
            compiledJobs := Files.package.registered.jobs,
            sources := Files.package.registered.sources
            styleDefaults := Files.package.registered.styleDefaults,
            modes := Minibuffer.package.registered.modes
            workingDirectory := "/big" }
    try
      let ask : IO Unit := do
        host.send (.run Files.openName)
        unless (← host.join patience) == .settled do
          throw (IO.userError "the file prompt did not list its directory")
      ask
      let fileKeys := ["f", "1", "2", "3", "4", "5"]
      let mut keyTimes := #[]
      for sample in [0:samples] do
        let index := sample % fileKeys.length
        if index == 0 && sample > 0 then
          host.send (.run Minibuffer.cancelName)
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
      discard <| host.halt patience
      discard <| Job.Pool.warm pool 5000
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

/-! ## The workspace finder benchmark

`bench-workspace-files` measures what a key costs in
`find-file-in-workspace`'s prompt over a real repository
(`Editor/Workspace/FindFile.lean`), and the time from a key to the list it
updates: the source's job runs the workspace's lister, `git ls-files`, and
fzf, both real, on the pool, after the source's 50 ms pause. One headless
host of the test scheme, over the library's real process and file
services and its queue, whose working directory is the repository. -/

/-- How far apart the keys of the cadence row of the workspace finder
benchmark are sent, in milliseconds: more than the source's 50 ms pause, so
each key arrives while the job of the text before it runs its lister or its
filter. -/
def finderCadence : Nat :=
  120

/-- The median of `times`, which need not be sorted. -/
def median (times : Array Nat) : Nat :=
  (Row.of "" times).median

/-- How long one run of `command` with `arguments` in `directory` takes, fed
`input` when it is given, in nanoseconds, with what it wrote
(`IO.Process.output`); a throw when it does not exit 0. -/
def timedRun (command : String) (arguments : Array String) (directory : System.FilePath)
    (input : Option String := none) : IO (Nat × String) := do
  let started ← IO.monoNanosNow
  let output ← IO.Process.output { cmd := command, args := arguments, cwd := directory } input
  let ended ← IO.monoNanosNow
  unless output.exitCode == 0 do
    throw (IO.userError s!"{command} exited with status {output.exitCode}: {output.stderr}")
  return (ended - started, output.stdout)

/-- `bench-workspace-files`: what a key costs in `find-file-in-workspace`'s
prompt over the repository at `repository`, a key in a prompt with no
candidates as the floor, the keys `m`, `1`, `2`, `f`, `3` and `4` each
joined, with the time from each to its updated list, and the same keys
`finderCadence` ms apart with nothing joined; `samples` keys a row. Then
the lister and the filter alone, each run 20 times. -/
def workspaceFiles (sysroot oleanDir : String) (repository : System.FilePath) (samples : Nat) :
    IO UInt8 := do
  let repository ← IO.FS.realPath repository
  let pool := (← Job.Pool.warm Job.Pool.size 200).size
  let completions ← Job.Completions.new
  discard <| IO.asTask (prio := .dedicated) (Job.pump completions)
  let timers := Job.realTimers completions
  let published ← Snapshots.new
  let held ← Job.HeldSnapshots.new
  let services : Job.Services :=
    { completions, timers, fuzzy := Fuzzy.real
      files := Job.realFiles completions published.reader held
      processes :=
        Job.realProcesses completions (← Job.RefusedRuns.new) timers (← Job.TimedRuns.new)
      snapshots := Job.realSnapshots published.reader }
  -- The editor thread reads the clock when it prints that it ran `noop`,
  -- and when it prints that the source's job's post, its batch, ran.
  let ranSlot ← IO.mkRef (none : Option (IO.Promise Nat))
  let listedSlot ← IO.mkRef (none : Option (IO.Promise Nat))
  let failures ← IO.mkRef (#[] : Array String)
  let refused ← IO.mkRef 0
  let source := Workspace.FindFile.job
  -- The status line of the finder's prompt, as `scene` prints it: it names
  -- the workspace, so the report says git found it.
  let labelLine ← IO.mkRef (none : Option String)
  let emit (line : String) : IO Unit := do
    if line.startsWith "status " && (line.splitOn "Find file in ").length > 1 then
      labelLine.modify (·.orElse fun _ => some line)
    if line == "run noop: ok" then
      if let some sample← ranSlot.modifyGet fun slot => (slot, none) then
        sample.resolve (← IO.monoNanosNow)
    else if line.startsWith "job " && line.endsWith s!" {source}: ok" then
      if let some sample← listedSlot.modifyGet fun slot => (slot, none) then
        sample.resolve (← IO.monoNanosNow)
    else if line.startsWith "job " && (line.splitOn s!" {source}: failed").length > 1 then
      failures.modify (·.push line)
    else if line.startsWith "loop: refused" then
      refused.modify (· + 1)
  let host ←
    Headless.start (scheme := TestScheme.scheme)
        { elaborator := Config.Elaborate.elaborator { sysroot, oleanDir }
          source := { chunks := pure #[] }, emit, services, published, held, requests := 1
          wakeups := 2, jobs := 3, environment := 4, posts := 5, pauseEvents := 6
          commands :=
            Files.package.registered.commands ++ Minibuffer.package.registered.commands ++
              Workspace.package.registered.commands ++
              #[{ name := "noop", action := .plain (pure ()) },
                { name := "ask-plain"
                  action := .plain (discard <| Editor.prompt "Plain: " { command := "noop" } "") }]
          compiledJobs := Files.package.registered.jobs ++ Workspace.package.registered.jobs
          sources := Files.package.registered.sources ++ Workspace.package.registered.sources,
          styleDefaults := Files.package.registered.styleDefaults
          modes := Minibuffer.package.registered.modes, workingDirectory := repository }
  try
    let joined (what : String) : IO Unit := do
      unless (← host.join patience) == .settled do
        throw (IO.userError s!"{what} did not settle")
      unless (← failures.get).isEmpty do
        throw (IO.userError s!"the source failed: {(← failures.get)[0]!}")
    -- The file opens, and the finder runs git for its directory.
    host.send (.open (repository / "src" / "m0" / "f0.rs").toString)
    joined "the open"
    let keys := ["m", "1", "2", "f", "3", "4"]
    -- One row: `ask` opens the prompt, joined and untimed; each key is
    -- committed and followed by `noop`, and timed to the editor thread's
    -- line for `noop`, and, when `listing`, to the post of the batch for
    -- its text. After the sixth key the prompt is cancelled and asked again,
    -- untimed. `joined` joins after each key; otherwise the next key comes
    -- `finderCadence` ms later.
    let row (ask : String) (listing joinEach : Bool) : IO (Array Nat × Array Nat) := do
      let opens : IO Unit := do
        host.send (.run ask)
        joined s!"{ask}'s prompt"
      opens
      let mut keyTimes := #[]
      let mut listingTimes := #[]
      for sample in [0:samples] do
        let index := sample % keys.length
        if index == 0 && sample > 0 then
          joined "the keys"
          host.send (.run Minibuffer.cancelName)
          joined "the cancel"
          opens
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
          let some delivered ← IO.wait listed.result? | throw (IO.userError "a listing was lost")
          listingTimes := listingTimes.push (delivered - asked)
        if joinEach then
          joined "a key's listing"
        else
          IO.sleep finderCadence.toUInt32
      joined "the row"
      host.send (.run Minibuffer.cancelName)
      joined "the cancel"
      return (keyTimes, listingTimes)
    -- The finder's first listing, untimed, and its prompt's status line.
    host.send (.run Workspace.FindFile.name)
    joined "the first listing"
    host.send .scene
    joined "the scene"
    host.send (.run Minibuffer.cancelName)
    joined "the cancel"
    let idle := Row.of "no candidates" (← row "ask-plain" false true).1
    let (finderKeys, finderListings) ← row Workspace.FindFile.name true true
    let finder := Row.of "workspace finder, each key joined" finderKeys
    let listed := Row.of "  key to the updated list" finderListings
    let cadence :=
      Row.of s!"workspace finder, keys {finderCadence} ms apart"
        (← row Workspace.FindFile.name false false).1
    -- The lister and the filter alone, outside the editor.
    let lister := Workspace.Lister.git "git"
    let mut listerTimes := #[]
    let mut filterTimes := #[]
    let mut listedCount := 0
    for _ in [0:20] do
      let (time, output) ← timedRun lister.program lister.arguments repository
      listerTimes := listerTimes.push time
      listedCount := (Completion.Filtering.records .nul output.toUTF8 false).size
      let (time, _) ←
        timedRun "fzf" #["--read0", "--print0", "--filter", "m12"] repository (some output)
      filterTimes := filterTimes.push time
    IO.println
        s!"pool: {pool} threads; {samples} keys a row, of m, 1, 2, f, 3 and 4 committed into the prompt; {repository}: git lists {listedCount} files; the prompt's {(← labelLine.get).getD "status line was not printed"}"
    IO.println
        "latency of a key, from sending it to the editor thread having handled it and published its scene, and of the list, from sending a key to the post of its batch, in µs: median / 99th percentile / maximum"
    for row in [idle, finder, listed, cadence] do
      IO.println row.line
    IO.println
        s!"alone, median of 20 runs, in µs: git ls-files -z --cached --others --exclude-standard {microseconds (median listerTimes)}; fzf --read0 --print0 --filter m12 fed its output {microseconds (median filterTimes)}"
    IO.println
        ("within bound (median within twice the no-candidates median, 99th percentile under 1 ms): " ++
          "; ".intercalate
            ([finder, cadence].map fun row =>
              s!"{row.name}: {if row.keyWithinBound idle then "yes" else "no"}"))
    if (← refused.get) > 0 then
      IO.println s!"refused steps: {← refused.get}"
    (← IO.getStdout).flush
    return 0
  finally
    discard <| host.halt patience

end Bench

end ConfigTest
