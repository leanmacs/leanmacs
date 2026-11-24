import Editor.Config.Elaborate
import Editor.Headless
import Editor.InputScheme.Test
import Editor.Job.Pool
import Editor.ModuleLookup
import Editor.Package
import Editor.Test.Linked.Host
import Editor.Test.Linked.Services

/-!
# The linked test kit: Bench

What a benchmark of a feature's command over the library's real services
needs and may not import itself: the rows its latencies are reported in
(`Row`: the median, the 99th percentile and the maximum of a row's
samples, printed by `Row.line`, with the bounds the job system and the
prompts were accepted against, `Row.withinBound` and `Row.keyWithinBound`),
the job pool warmed as the editor warms it (`warmPool`), and a headless host
of the test scheme over the real services, its config elaborated on the
base `Editor` by the real elaborator, in its bracket (`withBenchHost`),
and the waits a benchmark's host is waited on with, on the lines the
benched work prints (`Printed`: its jobs' ends after a fence, never the
host's idle). The config benchmarks
(`ConfigTest.Bench`) and the workspace finder's
(`WorkspaceTest.Linked.WorkspaceBench`,
`packages/workspace/WorkspaceTest/Linked/Workspace/Bench.lean`) are written on it. It measures and asserts
nothing of its own.

Published for a package's linked test: it is a module of the core's linked
test kit, in the namespace `Editor.Test.Linked`, which the root of a
package's linked test and the modules under it may import, and no other
module of a package may (`docs/design/packages.md`, "What a package may
import"). It names the host, the pool and the elaborator so that a
benchmark need not.
-/

namespace Editor.Test.Linked

open Editor

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

/-- What the 99th percentile of a key's latency must stay under, in
nanoseconds: 1 ms. -/
def keyBound : Nat :=
  1000000

/-- Whether a row of keys is within the bound the plan set for matching off
the editor thread: its median at most twice the idle row's, and its 99th
percentile under 1 ms. The auto-popup row is judged with the plain insert
row as its idle row: the same key with no at-point source. -/
def Row.keyWithinBound (row idle : Row) : Bool :=
  row.median ≤ 2 * idle.median && row.high < keyBound

/-- Warms the job pool as the editor does at start, and gives how many
threads it holds. -/
def warmPool : IO Nat := do
  return (← Job.Pool.warm Job.Pool.size Headless.warmPatience).size

/-- Runs `body` against a headless host of the test scheme for a benchmark,
in its bracket (`Headless.withHost`), so this returns only once the host's
loop has ended: over the library's real services `services` (`Services`),
handed `packages`, in the working directory `workingDirectory`, printing
each line to `emit`, with a source in memory that holds no config,
elaborated by the real elaborator over the toolchain in `sysroot` and the
`.olean` directories `oleanDir` names, on the base `Editor`; the module
data of config files in a temporary directory of the system's. One such
host a process: its source ids are the first ones. `guard` is the bracket's
guard against a hang of the loop's end. -/
def withBenchHost {α : Type} (sysroot oleanDir : String) (services : Services)
    (packages : Array Package) (workingDirectory : System.FilePath) (emit : String → IO Unit)
    (guard : HangGuard) (body : Headless.Host → IO α) : IO α := do
  let files ← Config.Elaborate.ModuleFiles.temporary
  let elaborator :=
    Config.Elaborate.elaborator
      { sysroot, oleanDirs := (ModuleLookup.searchPath oleanDir).map System.FilePath.mk
        imports := #[`Editor] } files
  -- Only a hang reaches `guard`, the loop's end once the body has
  -- returned, which is then said once and still waited on.
  Headless.withHost (scheme := TestScheme.scheme) (guard := guard)
      { elaborator, source := memorySource [], emit, services := services.jobs
        published := services.published, held := services.held, requests := 1, wakeups := 2
        jobs := 3, environment := 4, posts := 5, pauseEvents := 6, packages, workingDirectory } body

/-! ## Waiting on a benchmark host's own lines

A benchmark's host runs on its own thread over the library's real
services, so a benchmark waits for the work it sent on the lines that work
prints, never on the host's idle (`docs/dev-practices/inferred-waits.md`):
its `emit` hands every line to `Printed.note`, after its own reads of the
clock, and each wait ends on the line that makes it hold
(`Printed.reaches`).

What a piece of work sent comes to is its jobs' ends. Every job a step
starts says so before the editor thread takes its next event
(`job <id> <name>: started`, `Headless.Running.launch`), so once the
editor thread has run a command sent after the work, the fence (`run noop:
ok`), every job the work started has said it started. Each of those has
ended once the line of its end is printed: the line after its posts' lines
(`job <id> <name>: ok` for each post, then for the end; `jobEnded`). Of
the jobs of one name, the latest is waited for: a later start of a name
cancels the job before it, a key's new match or a source asked again,
which ends with no line. A job one of them starts when it ends is not
waited for: a benchmark that needs one waits for it by name. Nor is a job a
later command cancels, such as a prompt's close, which ends with no line
either: a benchmark waits for that command's own line (`Printed.run`) and
starts its next wait after it. -/

/-- What a benchmark's host has printed, oldest first, and the waits armed
on it, each a test of the lines and the promise `note` resolves once the
test holds, after the line that makes it is among the lines. -/
structure Printed where
  /-- Every line the host has printed, oldest first. -/
  lines : IO.Ref (Array String)
  /-- The waits armed and not yet reached. -/
  waits : IO.Ref (Array ((Array String → Bool) × IO.Promise Unit))

/-- Nothing printed and no wait armed. -/
def Printed.new : BaseIO Printed :=
  return { lines := ← IO.mkRef #[], waits := ← IO.mkRef #[] }

/-- How many lines have been printed. -/
def Printed.size (printed : Printed) : BaseIO Nat :=
  return (← printed.lines.get).size

/-- Takes in the line `line`, printed next, and resolves every armed wait
whose test now holds. A benchmark's `emit` calls it for every line, after
its own reads of the clock. -/
def Printed.note (printed : Printed) (line : String) : BaseIO Unit := do
  printed.lines.modify (·.push line)
  if (← printed.waits.get).isEmpty then
    return
  let lines ← printed.lines.get
  let reached ← printed.waits.modifyGet fun waits => waits.partition (·.1 lines)
  for (_, promise) in reached do
    promise.resolve ()

/-- Arms a wait for `done` to hold of the lines, and gives its promise:
resolved at once when it holds already, and otherwise by the `note` of the
line that makes it hold. It is armed before the lines are read, so a line
noted in between is not missed. -/
def Printed.arm (printed : Printed) (done : Array String → Bool) : BaseIO (IO.Promise Unit) := do
  let reached ← IO.Promise.new
  printed.waits.modify (·.push (done, reached))
  if done (← printed.lines.get) then
    reached.resolve ()
  return reached

/-- Waits until `done` holds of the lines (`arm`), on the line that makes
it hold, never by a poll: whether it held before `guard`, which only a
hang reaches. -/
def Printed.reaches (printed : Printed) (guard : HangGuard) (done : Array String → Bool) :
    IO Bool := do
  let reached ← printed.arm done
  return (← Job.awaitWithin guard reached.result?).isSome

/-- The jobs `lines` say started, oldest first: each its label, `job <id>
<name>`, and its name. -/
def startedJobs (lines : Array String) : Array (String × String) :=
  lines.filterMap fun line =>
    if line.startsWith "job " && line.endsWith ": started" then
      let label := String.ofList (line.toList.take (line.length - ": started".length))
      match label.splitOn " " with
      | _ :: _ :: name => some (label, " ".intercalate name)
      | _ => none
    else none

/-- Whether `lines` hold the end of the job labelled `label` (`job <id>
<name>`), which posts `posts` times before it ends: a line of it that is
not `ok`, a failure or a cancel, which only an end says, or the line after
its posts' lines. -/
def jobEnded (lines : Array String) (label : String) (posts : Nat) : Bool :=
  let said := lines.filter fun line => line.startsWith s!"{label}: " && !line.endsWith ": started"
  said.size > posts || said.any (!·.endsWith ": ok")

/-- Whether the work whose lines begin at `start` has run through
(`Printed`, in the module docs): the fence line `fence` is among the lines
from `fenceFrom` on, and every job started from `start` up to it, the
latest of each name, has ended (`jobEnded`), each name posting `posts` of
it times. -/
def ranThrough (lines : Array String) (start fenceFrom : Nat) (fence : String := "run noop: ok")
    (posts : String → Nat := fun _ => 0) : Bool :=
  match ((lines.extract fenceFrom lines.size).findIdx? (· == fence)) with
  | none => false
  | some found =>
    let started := startedJobs (lines.extract start (fenceFrom + found))
    let latest :=
      (List.range started.size).filterMap fun index =>
        let (label, name) := started[index]!
        if (started.extract (index + 1) started.size).any (·.2 == name) then none
        else some (label, name)
    latest.all fun (label, name) => jobEnded (lines.extract start lines.size) label (posts name)

/-- Waits until the work whose lines begin at `start` has run through
(`ranThrough`), the fence the first `run noop: ok` from `fenceFrom` on:
whether it did before `guard`, which only a hang reaches. -/
def Printed.ranSince (printed : Printed) (guard : HangGuard) (start fenceFrom : Nat)
    (posts : String → Nat := fun _ => 0) : IO Bool :=
  printed.reaches guard (ranThrough · start fenceFrom (posts := posts))

/-- Sends `host` the fence, a run of `noop`, which the host's packages
register, and waits until the work whose lines begin at `start` has run
through it (`ranSince`). -/
def Printed.fenced (printed : Printed) (host : Headless.Host) (guard : HangGuard) (start : Nat)
    (posts : String → Nat := fun _ => 0) : IO Bool := do
  let fenceFrom ← printed.size
  host.send (.run "noop")
  printed.ranSince guard start fenceFrom posts

/-- Sends what `send` sends, then the fence, and waits until it has run
through (`fenced`): every job it started has ended. -/
def Printed.ran (printed : Printed) (host : Headless.Host) (guard : HangGuard) (send : IO Unit)
    (posts : String → Nat := fun _ => 0) : IO Bool := do
  let start ← printed.size
  send
  printed.fenced host guard start posts

/-- Sends `host` a run of the command `name`, and waits for the line of its
own outcome, `run <name>: ` and how it went, printed after what was
printed before it: whether it came before `guard`, which only a hang
reaches. It waits for no job: for a command whose step cancels work, such
as a prompt's close, after which a wait from its line on starts clear of
the jobs it cancelled, which end with no line. -/
def Printed.run (printed : Printed) (host : Headless.Host) (guard : HangGuard) (name : String) :
    IO Bool := do
  let start ← printed.size
  host.send (.run name)
  printed.reaches guard fun lines =>
      (lines.extract start lines.size).any (·.startsWith s!"run {name}: ")

/-- Whether the job named `name` that `lines` say started from `start` on,
the latest of that name, has ended, after `posts` posts (`jobEnded`): for
work the editor thread takes from an event no fence follows, such as a
pause that fires once the clock is moved. -/
def jobRan (lines : Array String) (start : Nat) (name : String) (posts : Nat := 0) : Bool :=
  let since := lines.extract start lines.size
  match ((startedJobs since).filter (·.2 == name)).back? with
  | some (label, _) => jobEnded since label posts
  | none => false

end Editor.Test.Linked
