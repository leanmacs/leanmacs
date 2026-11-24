import Editor.Completion.Filtering
import Editor.RealHost
import Editor.Test.Linked.Bench
import Editor.Test.Linked.Host
import Editor.Test.Linked.Listings
import Editor.Test.Linked.Services
import Editor.Test.Minibuffer
import Editor.Test.Shipped
import FilesApiTest.Fake
import Workspace.Compiled
import Workspace.FindFile
import Workspace.Lister

/-!
# Linked tests: the workspace finder benchmark

The workspace finder's benchmark, `WorkspaceTest.Linked.WorkspaceBench.workspaceFiles`:
the linked test's opt-in argument `bench-workspace-files`, which its root,
`WorkspaceTest/Linked.lean`, runs from `main` (`mise run find-file-bench`),
and the gate builds and never runs. It measures and asserts nothing of its
own; it is the workspace feature's (`Workspace/FindFile.lean`). It was the
config test's (`ConfigTest.WorkspaceBench`, split from the config
benchmarks, `ConfigTest.Bench`) while the workspaces were modules of the
core, and is written on the linked test kit (`Editor.Test.Linked`:
`withBenchHost`, `warmPool`, `Row`), so it imports no internal module and no
other feature.

`bench-workspace-files` measures what a key costs in
`find-file-in-workspace`'s prompt over a real repository
(`Workspace/FindFile.lean`), and the time from a key to the list it
updates: the source's job runs the workspace's lister, `git ls-files`, and
fzf, both real, on the pool, after the source's 50 ms pause. One headless
host of the test scheme, over the library's real services and its queue
(`Editor.Test.Linked.withBenchHost`), whose working directory is the
repository, with the workspace package and `files-api`'s fake, which opens
the first file.
-/

-- A bench measures real time: its clock reads, and the sleeps of its
-- cadence, are the measurement and never a wait, and it is never part of
-- `ci` (`linter.rawClock`, `lean/Lint/Wait.lean`).
set_option linter.rawClock false

namespace WorkspaceTest.Linked.WorkspaceBench

open Editor
open Editor.Test.Linked

/-- How far apart the keys of the cadence row of the workspace finder
benchmark are sent, in milliseconds: more than the source's 50 ms pause, so
each key arrives while the job of the text before it runs its lister or its
filter. -/
def finderCadence : Nat :=
  120

/-- The guard of a measurement's wait on its own lines, or its host's end;
only a hang reaches it, and the measurement then fails as a hang. -/
def patience : HangGuard :=
  .on "a measurement's wait on its own lines, or its host's end" 120000

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

/-- The mark of `workspaceFiles`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def workspaceFiles.realHost : Editor.RealHost :=
  .loop

/-- `bench-workspace-files`: what a key costs in `find-file-in-workspace`'s
prompt over the repository at `repository`, a key in a prompt with no
candidates as the floor, the keys `m`, `1`, `2`, `f`, `3` and `4` each
joined, with the time from each to its updated list, and the same keys
`finderCadence` ms apart with nothing joined; `samples` keys a row. Then
the lister and the filter alone, each run 20 times. -/
def workspaceFiles (sysroot oleanDir : String) (repository : System.FilePath) (samples : Nat) :
    IO UInt8 := do
  let repository ← IO.FS.realPath repository
  let pool ← warmPool
  let services ← Services.start
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
  -- What the host printed, which its waits end on (`Printed`), after the
  -- clock's reads below. The source's job posts its one batch before it
  -- ends (`Workspace.FindFile.answer`).
  let printed ← Printed.new
  let posts (name : String) : Nat := if name == source then 1 else 0
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
    printed.note line
  withBenchHost sysroot oleanDir services
      #[listingsPackage, Test.Shipped.modeLine, FilesApiTest.fake, Test.Minibuffer.package,
        Workspace.package,
        Compiled.package
          {
            commands :=
              #[{ name := "noop", action := .plain (pure ()) },
                { name := "ask-plain"
                  action :=
                    .plain (discard <| Editor.prompt "Plain: " { command := "noop" } "") }] }]
      repository emit patience fun host => do
      -- Each wait is on the lines of the work it waits for: the jobs
      -- started from `start` on, the latest of each name, ended
      -- (`Printed.ranSince`), the fence the first `run noop` from
      -- `fenceFrom` on.
      let failed : IO Unit := do
        unless (← failures.get).isEmpty do
          throw (IO.userError s!"the source failed: {(← failures.get)[0]!}")
      let ranSince (what : String) (start fenceFrom : Nat) : IO Unit := do
        unless ← printed.ranSince patience start fenceFrom posts do
          throw (IO.userError s!"{what} did not settle")
        failed
      -- Sends the fence after the work from `start`, and waits for it.
      let fenced (what : String) (start : Nat) : IO Unit := do
        unless ← printed.fenced host patience start posts do
          throw (IO.userError s!"{what} did not settle")
        failed
      -- Sends what `send` sends, and waits for its jobs.
      let ran (what : String) (send : IO Unit) : IO Unit := do
        unless ← printed.ran host patience send posts do
          throw (IO.userError s!"{what} did not settle")
        failed
      -- Runs `name`, and waits for its own line: a cancel, whose jobs end
      -- with no line, so the next wait starts after it.
      let cancelled (what : String) : IO Unit := do
        unless ← printed.run host patience Test.Minibuffer.cancelName do
          throw (IO.userError s!"{what} did not run")
      -- The file opens, and the finder runs git for its directory: the
      -- load's job, then the find job its delivery starts
      -- (`Workspace.findJob`), waited for by name.
      let opened ← printed.size
      ran "the open" (host.send (.open (repository / "src" / "m0" / "f0.rs").toString))
      unless ← printed.reaches patience (jobRan · opened Workspace.findJob) do
        throw (IO.userError "the open's workspace was not found")
      let keys := ["m", "1", "2", "f", "3", "4"]
      -- One row: `ask` opens the prompt, joined and untimed; each key is
      -- committed and followed by `noop`, and timed to the editor thread's
      -- line for `noop`, and, when `listing`, to the post of the batch for
      -- its text. After the sixth key the prompt is cancelled and asked again,
      -- untimed. With `joinEach` each key's own jobs are waited for after it;
      -- otherwise the next key comes `finderCadence` ms later, and the keys'
      -- jobs are waited for before the cancel.
      let row (ask : String) (listing joinEach : Bool) : IO (Array Nat × Array Nat) := do
        let opens : IO Nat := do
          ran s!"{ask}'s prompt" (host.send (.run ask))
          printed.size
        let mut since ← opens
        let mut keyTimes := #[]
        let mut listingTimes := #[]
        for sample in [0:samples] do
          let index := sample % keys.length
          if index == 0 && sample > 0 then
            fenced "the keys" since
            cancelled "the cancel"
            since ← opens
          let ran ← IO.Promise.new
          let listed ← IO.Promise.new
          ranSlot.set (some ran)
          listedSlot.set (if listing then some listed else none)
          let start ← printed.size
          let asked ← IO.monoNanosNow
          host.commit (keys[index]?.getD "x")
          host.send (.run "noop")
          let some handled ← IO.wait ran.result? | throw (IO.userError "a key was lost")
          keyTimes := keyTimes.push (handled - asked)
          if listing then
            let some delivered ← IO.wait listed.result? | throw (IO.userError "a listing was lost")
            listingTimes := listingTimes.push (delivered - asked)
          if joinEach then
            -- The key's own jobs, after the sample's `noop`, the fence.
            ranSince "a key's listing" start start
            since ← printed.size
          else
            -- real time under test: the finder row's typing cadence.
            IO.sleep finderCadence.toUInt32
        fenced "the row" since
        cancelled "the cancel"
        return (keyTimes, listingTimes)
      -- The finder's first listing, untimed, and its prompt's status line.
      ran "the first listing" (host.send (.run Workspace.FindFile.name))
      ran "the scene" (host.send .scene)
      cancelled "the cancel"
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

end WorkspaceTest.Linked.WorkspaceBench
