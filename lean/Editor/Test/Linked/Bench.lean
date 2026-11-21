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
base `Editor` by the real elaborator (`benchHost`). The config benchmarks
(`ConfigTest.Bench`) and the workspace finder's
(`ConfigTest.WorkspaceBench`) are written on it. It measures and asserts
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
  return (← Job.Pool.warm Job.Pool.size 200).size

/-- A headless host of the test scheme for a benchmark: over the library's
real services `services` (`Services`), handed `packages`, in the working
directory `workingDirectory`, printing each line to `emit`, with a source
in memory that holds no config, elaborated by the real elaborator over the
toolchain in `sysroot` and the `.olean` directories `oleanDir` names, on
the base `Editor`; the module data of config files in a temporary
directory of the system's. One such host a process: its source ids are the
first ones. -/
def benchHost (sysroot oleanDir : String) (services : Services) (packages : Array Package)
    (workingDirectory : System.FilePath) (emit : String → IO Unit) : IO Headless.Host := do
  let files ← Config.Elaborate.ModuleFiles.temporary
  let elaborator :=
    Config.Elaborate.elaborator
      { sysroot, oleanDirs := (ModuleLookup.searchPath oleanDir).map System.FilePath.mk
        imports := #[`Editor] } files
  Headless.start (scheme := TestScheme.scheme)
      { elaborator, source := memorySource [], emit, services := services.jobs
        published := services.published, held := services.held, requests := 1, wakeups := 2
        jobs := 3, environment := 4, posts := 5, pauseEvents := 6, packages, workingDirectory }

end Editor.Test.Linked
