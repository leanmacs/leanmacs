import Editor.Completion.Filtering
import Editor.Test.Linked.Bench
import Editor.Test.Linked.Host
import Editor.Test.Linked.Listings
import Editor.Test.Linked.Services
import Editor.Test.Minibuffer
import Editor.Test.Shipped
import Editor.Workspace.Compiled
import Editor.Workspace.FindFile
import Editor.Workspace.Lister
import FilesApiTest.Fake

/-!
# Config tests: the workspace finder benchmark

The workspace finder's benchmark, `ConfigTest.WorkspaceBench.workspaceFiles`:
`config-test bench-workspace-files`, which the root module `ConfigTest`
runs from `main` (`mise run find-file-bench`), and the gate builds and never
runs. It measures and asserts nothing of its own; it is the workspace
feature's (`Editor/Workspace/FindFile.lean`), split from the config
benchmarks (`ConfigTest.Bench`), and written on the linked test kit
(`Editor.Test.Linked`: `benchHost`, `warmPool`, `Row`), so it imports no
internal module and no other feature.

`bench-workspace-files` measures what a key costs in
`find-file-in-workspace`'s prompt over a real repository
(`Editor/Workspace/FindFile.lean`), and the time from a key to the list it
updates: the source's job runs the workspace's lister, `git ls-files`, and
fzf, both real, on the pool, after the source's 50 ms pause. One headless
host of the test scheme, over the library's real services and its queue
(`Editor.Test.Linked.benchHost`), whose working directory is the
repository, with the workspace package and `files-api`'s fake, which opens
the first file.
-/

namespace ConfigTest.WorkspaceBench

open Editor
open Editor.Test.Linked

/-- How far apart the keys of the cadence row of the workspace finder
benchmark are sent, in milliseconds: more than the source's 50 ms pause, so
each key arrives while the job of the text before it runs its lister or its
filter. -/
def finderCadence : Nat :=
  120

/-- How long the benchmark waits, in milliseconds, for its host to settle. -/
def patience : Nat :=
  120000

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
    benchHost sysroot oleanDir services
        #[listingsPackage, Test.Shipped.modeLine, FilesApiTest.fake, Test.Minibuffer.package,
          Workspace.package,
          Compiled.package
            {
              commands :=
                #[{ name := "noop", action := .plain (pure ()) },
                  { name := "ask-plain"
                    action :=
                      .plain (discard <| Editor.prompt "Plain: " { command := "noop" } "") }] }]
        repository emit
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
          host.send (.run Test.Minibuffer.cancelName)
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
      host.send (.run Test.Minibuffer.cancelName)
      joined "the cancel"
      return (keyTimes, listingTimes)
    -- The finder's first listing, untimed, and its prompt's status line.
    host.send (.run Workspace.FindFile.name)
    joined "the first listing"
    host.send .scene
    joined "the scene"
    host.send (.run Test.Minibuffer.cancelName)
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

end ConfigTest.WorkspaceBench
