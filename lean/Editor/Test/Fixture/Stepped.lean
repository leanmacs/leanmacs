import Editor.Config.Elaborate
import Editor.Headless
import Editor.Headless.Journal.Fake
import Editor.Headless.Stepped
import Editor.Job.Fake
import Editor.Job.Real
import Editor.SyntaxTree.Fake
import Editor.Test.Fixture.Discover
import Editor.Test.Fixture.RealThread
import Editor.Test.Fixture.Setup
import Editor.Test.Linked.Services
import Editor.Test.Linked.Stepping

/-!
# The headless fixture harness: a fixture run stepped

Runs a headless fixture on the stepped host with the fakes
(`docs/dev-practices/headless-mode.md`, "How the gate runs a fixture"):
the script runner over a host stepped on the harness's thread
(`Headless.Stepped.runFrom`), whose waits step the fakes
(`Editor/Headless/Stepped.lean`, "A wait over the fakes"), and compares
what it printed with the fixture's expected file.

A run's collaborators are the CLI's (`Headless.shippedOver`, over the set's
packages, input scheme and config base, the real elaborator and the
fixture's config directory), with every background collaborator a fake
the run steps: the fake scheduler and pump, the file fake over the setup's
model and the process fake over its runs (`SteppedServices`), a fresh fake
clock and watches, the recording journal with no state directory, and the
syntax service's fake posting its deliveries to the run's memory queue.
The matcher and the snapshot reads are the real ones. The display is the
recorder, with no render loop. The working directory is the setup's, a
directory of the file model, so the real one is never read; a restart is
never asked for, so the exec is a port that refuses; nothing is generated;
and there is nothing to dispose of, the config files' module data being the
process's. Each fixture gets fresh collaborators, fakes, clock and queue;
only the elaborator's base is shared (`sharing`).

After a run: the fakes must be quiescent (`SteppedFakes.unquiet`), the
library's editor queue as it was (`leavingLibraryQueue`), the output,
scrubbed (`Setup.scrub`), the expected file line for line, and the setup's
after-checks must hold. A failure says the first differing line, with its
number and both texts, or which check failed. A run that throws, a hang
given up at its guard among them, fails under the fixture's name with the
error, and the harness goes on to the next fixture (`caught`).

`runRoots` runs every fixture of the discovery roots it is handed, but
those the real-thread set leaves to the CLI (`RealThread.entries`), and
fails a run whose root held no fixture or whose set names a script under
the root that discovery did not find. `compare` runs a runner entry stepped
and compares it with the CLI's output, both ways, and with its expected
file. Its checks are `ConfigTest.fixtureRunChecks`
(`ConfigTest/Editor/Test/Fixture/Stepped.lean`).
-/

namespace Editor.Test.Fixture

open Editor
open Editor.Test.Linked

/-- What every stepped run of one harness shares: the set's packages, its
input scheme and config base, the toolchain and `.olean` directories, the
repository's root, the elaborator's shared base, the config files' module
data, the setups and the real-thread set, and where its report goes. -/
structure Harness (scheme : InputScheme) where
  /-- The packages the set's editor registers. -/
  packages : Array Package
  /-- The modules config is elaborated on. -/
  base : Array Lean.Name
  /-- The Lean toolchain's directory. -/
  sysroot : String
  /-- The `.olean` directories, searched in order. -/
  oleans : List String
  /-- The repository's root, absolute: fixtures are named from it. -/
  repository : String
  /-- The base every run's elaborator shares (`sharing`). -/
  latest : IO.Ref (Option Config.Elaborate.Base)
  /-- Where the config files' module data goes. -/
  files : Config.Elaborate.ModuleFiles
  /-- The elaborator every run is handed, when the harness's caller has one
already: none for the set's harness, whose runs share `latest` over the
real elaborator of the toolchain and the `.olean` directories. -/
  elaborator : Option (Config.Elaborator Config.Elaborate.Base Config.Elaborate.Handle) := none
  /-- The setups of the fixtures that declare one. -/
  setups : Array (String × Setup) := Setup.core
  /-- The real-thread set. -/
  entries : Array RealThread.Entry := RealThread.entries
  /-- Where the report's lines go. -/
  say : String → IO Unit := IO.println

/-- The repository's files as discovery reads them (`Tree`), the real ones
under `repository`. -/
def realTree (repository : String) : Tree IO where
  entries path := do
    try
      return (← System.FilePath.readDir (joinPath repository path)).map (·.fileName)
    catch _ =>
      return #[]
  isFile path := do
    try
      return !(← System.FilePath.isDir (joinPath repository path)) &&
          (← System.FilePath.pathExists (joinPath repository path))
    catch _ =>
      return false
  isDirectory path := do
    try
      System.FilePath.isDir (joinPath repository path)
    catch _ =>
      return false

/-- The files of the checked-in tree `source`, under `repository`, each at
the same place under the model directory `target`, with its bytes; and the
directories under it. -/
partial def treeFiles (repository source target : String) :
    IO (Array (String × ByteArray) × Array String) := do
  let mut files := #[]
  let mut directories := #[target]
  for entry in ← System.FilePath.readDir (joinPath repository source) do
    let name := entry.fileName
    if ← entry.path.isDir then
      let (more, under) ← treeFiles repository (joinPath source name) s!"{target}/{name}"
      files := files ++ more
      directories := directories ++ under
    else
      files := files.push (s!"{target}/{name}", ← IO.FS.readBinFile entry.path)
  return (files, directories)

/-- The file model of a run with `setup`: its seeds read from the
repository (`Setup.model`). -/
def seededModel (repository : String) (setup : Setup) : IO FileModel := do
  let mut files := #[]
  let mut directories := #[]
  for seed in setup.seeds do
    match seed with
    | .file source target =>
      files := files.push (target, ← IO.FS.readBinFile (joinPath repository source))
    | .tree source target =>
      let (more, under) ← treeFiles repository source target
      files := files ++ more
      directories := directories ++ under
  return setup.model files directories

/-- What a stepped run of a fixture came to: its output, scrubbed, the file
fake's model at its end, and what is wrong, if anything is. -/
structure Ran where
  /-- What the run printed, scrubbed (`Setup.scrub`). -/
  output : Array String
  /-- The file fake's model once the run had ended. -/
  model : FileModel
  /-- What failed: the script runner's failure, fakes left holding work. -/
  problems : Array String

/-- The exec of a restart in a stepped run, which never restarts: it
refuses. -/
def refusingReplace (_ : Restart.Invocation) : IO String :=
  return "a stepped run never restarts its process"

/-- Runs `script`, the text of `fixture`'s script with its placeholders
replaced, on the stepped host with the fakes (the module docs), with the
setup `setup`. -/
def runStepped {scheme : InputScheme} (harness : Harness scheme) (fixture : Parts) (setup : Setup)
    (script : String) : IO Ran := do
  let lines ← IO.mkRef (#[] : Array String)
  let directives ←
    match Headless.script script with
    | .ok directives =>
      pure directives
    | .error reason =>
      return { output := #[], model := {}, problems := #[s!"its script cannot be read: {reason}"] }
  let model ← seededModel harness.repository setup
  let completions ← Job.Completions.new
  let clock ← Job.FakeClock.new completions
  let watches ← Job.FakeFileWatches.new completions {}
  let published ← Snapshots.new
  let held ← Job.HeldSnapshots.new
  let snapshots := Job.realSnapshots published.reader
  let services ← SteppedServices.new completions clock watches snapshots held model setup.processes
  let memory ← Headless.Queue.Memory.new
  let journal ← Headless.RecordingJournal.new (snapshots := some snapshots)
  let parsed : Ffi.Event :=
    { source := { kind := .library, id := 0 }, kind := .parsed, code := 0, text := "", stamp := 0 }
  let syntaxFake ←
    FakeSyntaxService.new (post := discard <| memory.push parsed) (learn := snapshots)
  let fakes : SteppedFakes :=
    { services, memory, journal := ← IO.mkRef (some journal)
      syntaxService := ← IO.mkRef (some syntaxFake) }
  let environments ← IO.mkRef ({ host := .headless } : Process.Environments)
  let configDir := joinPath harness.repository fixture.config
  let shipped :=
    Headless.shippedOver scheme harness.packages harness.base harness.sysroot harness.oleans
      configDir (fun line => lines.modify (·.push line))
      { services.jobs with
        environments :=
          Headless.reportedEnvironments environments 4 (memory.queue Headless.Posted.toFfi) }
      published held harness.files
  let collaborators :=
    { shipped with
      elaborator := harness.elaborator.getD (sharing harness.latest shipped.elaborator)
      package := ← Headless.packageFilesAt configDir none
      journal := journal.journal
      syntaxTree := fun _ => pure syntaxFake.handle
      display := fun snapshots => Headless.Host.Display.recorder Headless.cells snapshots
      render := none, clock := some clock, workingDirectory := setup.workingDirectory
      replace := refusingReplace, generator := none, dispose := pure ()
      endCancelled := fakes.endCancelled }
  let (failure, _) ←
    leavingLibraryQueue <|
        Headless.Stepped.runFrom collaborators memory (some fakes.work) directives
          Headless.settlePatience (grace := some Headless.hangGrace)
  let mut problems := #[]
  if let some failure := failure then
    problems := problems.push (failure.describe Headless.settlePatience.ms)
  let unquiet ← fakes.unquiet
  unless unquiet.isEmpty do
    problems :=
      problems.push s!"the run left its fakes holding work: {"; ".intercalate unquiet.toList}"
  let printed := textLines ("\n".intercalate (← lines.get).toList)
  return { output := setup.scrub printed, model := ← services.files.model, problems }

/-- The bytes of a checked-in file, by its path from the repository's
root, if it can be read. -/
def checkedIn (repository path : String) : IO (Option ByteArray) := do
  try
    return some (← IO.FS.readBinFile (joinPath repository path))
  catch _ =>
    return none

/-- What is wrong with a stepped run of `fixture`, its setup `setup` and its
expected file's text `expected`, against both: the run's problems, the
first line that differs from the expected file, and each after-check that
failed. Empty when it held. -/
def judged (repository : String) (setup : Setup) (expected : Option String) (ran : Ran) :
    IO (Array String) := do
  let mut problems := ran.problems
  if let some expected := expected then
    if let some difference := firstDifference? (textLines expected) ran.output then
      problems := problems.push s!"its output is not its expected file: {difference}"
  let checked ←
    setup.after.mapM fun after => do
        match after with
        | .fileEquals _ source =>
          return (source, ← checkedIn repository source)
        | .noLineStartsWith _ =>
          return ("", none)
  for after in setup.after do
    let read (path : String) : Option ByteArray := (checked.find? (·.1 == path)).bind (·.2)
    if let some failure := after.failure? ran.model ran.output read then
      problems := problems.push failure
  return problems

/-- Runs `fixture` stepped, with its setup, refused as `refusal?` says,
and judged (`judged`): what is wrong, empty when it ran as expected. -/
def runFixture {scheme : InputScheme} (harness : Harness scheme) (fixture : Parts) :
    IO (Array String) := do
  let script ← IO.FS.readFile (joinPath harness.repository fixture.script)
  let declared := Setup.declared fixture.script harness.setups
  let setup := Setup.of fixture.script harness.setups
  let inSet := harness.entries.any (·.script == fixture.script)
  if let some refused := refusal? fixture script (if declared then some setup else none) inSet then
    return #[s!"refused: {refused}"]
  let expected ←
    match fixture.expected with
    | some path =>
      some <$> IO.FS.readFile (joinPath harness.repository path)
    | none =>
      pure none
  let ran ← runStepped harness fixture setup (setup.substitute script)
  judged harness.repository setup expected ran

/-- What `run`, a fixture's run, says is wrong, or, when it throws, its
error as its one problem: so a fixture whose run throws, a hang given up at
its guard among them, fails under its own name, and the run goes on. -/
def caught (run : IO (Array String)) : IO (Array String) := do
  try
    run
  catch error =>
    return #[s!"its run threw: {error}"]

/-- Runs every fixture of each discovery root in `roots` (the module docs):
each stepped, its line `fixture-test: <script>: stepped, as expected`, or
skipped, left to the CLI by its entry, its line saying its site and what it
covers; then the root's count line. A failure says what is wrong, and the
run goes on to the next fixture, as it does when a fixture's run throws
(`caught`). Exit 0 when every fixture held, and 1 otherwise, as for a root
that held no fixture or a stale entry. -/
def runRoots {scheme : InputScheme} (harness : Harness scheme) (tree : Tree IO)
    (roots : Array String) : IO UInt32 := do
  let mut failed := false
  for given in roots do
    let root := underRepository harness.repository given
    let fixtures ←
      match ← discover tree root with
      | .ok fixtures =>
        pure fixtures
      | .error reason =>
        harness.say s!"fixture-test: {reason}"
        failed := true
        continue
    if fixtures.isEmpty then
      harness.say s!"fixture-test: {root} holds no headless fixture, so nothing ran stepped there"
      failed := true
      continue
    for entry in harness.entries do
      if isUnder root entry.script && !fixtures.any (·.script == entry.script) then
        harness.say
            s!"fixture-test: the real-thread set names {entry.script}, which is no fixture under {root}: a stale entry"
        failed := true
    let mut stepped := 0
    let mut left := 0
    for fixture in fixtures do
      let entry := harness.entries.find? (·.script == fixture.script)
      if let some entry := entry then
        unless entry.stepped do
          harness.say
              s!"fixture-test: {fixture.script}: left to the CLI ({entry.site}): {entry.covers}"
          left := left + 1
          continue
      let problems ← caught (runFixture harness fixture)
      if problems.isEmpty then
        harness.say s!"fixture-test: {fixture.script}: stepped, as expected"
        stepped := stepped + 1
      else
        for problem in problems do
          harness.say s!"fixture-test: {fixture.script}: {problem}"
        failed := true
    harness.say
        s!"fixture-test: ran {stepped} fixtures stepped under {root}, {left} left to the CLI"
  return if failed then 1 else 0

/-- The fixture whose script is `script`, found by discovering its
directory, or the one above it, as a root. -/
def locate (tree : Tree IO) (script : String) : IO (Except String Parts) := do
  let directory := ((script.splitOn "/").dropLast).toArray
  let roots :=
    #["/".intercalate directory.toList, "/".intercalate (directory.pop).toList].filter (!·.isEmpty)
  for root in roots do
    if let .ok fixtures← discover tree root then
      if let some fixture := fixtures.find? (·.script == script) then
        return .ok fixture
  return .error s!"{script} is no fixture discovery finds"

/-- The runner entries of the set (`RealThread.compared`), each as
`<script>\t<config>\t<expected>`, for `case_compare` in
`tools/wiring-runs.sh`. Exit 1 when one is no fixture with an expected
file. -/
def printCompared {scheme : InputScheme} (harness : Harness scheme) (tree : Tree IO) : IO UInt32 :=
  do
  let mut failed := false
  for entry in harness.entries.filter (·.subject == .runner) do
    match ← locate tree entry.script with
    | .ok { script, config, expected := some expected } =>
      harness.say s!"{script}\t{config}\t{expected}"
    | .ok _ =>
      harness.say s!"fixture-test: {entry.script}, a runner entry, has no expected file"
      failed := true
    | .error reason =>
      harness.say s!"fixture-test: {reason}"
      failed := true
  return if failed then 1 else 0

/-- Runs the runner entry `script` stepped and compares it with the CLI's
output read from `file` (`compared`): its line
`fixture-test: <script>: the CLI over a real loop thread and the stepped run printed the same, and it is expected`,
or what is wrong, the error among it when the run throws (`caught`). -/
def compare {scheme : InputScheme} (harness : Harness scheme) (tree : Tree IO)
    (script file : String) : IO UInt32 := do
  let script := underRepository harness.repository script
  let some entry := harness.entries.find? (·.script == script)
    |
    harness.say s!"fixture-test: {script} has no entry in the real-thread set"
    return 1
  unless entry.subject == .runner do
    harness.say s!"fixture-test: {script} is no runner entry, so it is not compared both ways"
    return 1
  let fixture ←
    match ← locate tree script with
    | .ok fixture =>
      pure fixture
    | .error reason =>
      harness.say s!"fixture-test: {reason}"
      return 1
  let some expectedPath := fixture.expected
    |
    harness.say s!"fixture-test: {script} has no expected file"
    return 1
  let setup := Setup.of script harness.setups
  let problems ←
    caught do
        let text ← IO.FS.readFile (joinPath harness.repository script)
        let ran ← runStepped harness fixture setup (setup.substitute text)
        let cli := textLines (← IO.FS.readFile file)
        let expected := textLines (← IO.FS.readFile (joinPath harness.repository expectedPath))
        return ran.problems ++ compared cli ran.output expected
  if problems.isEmpty then
    harness.say
        s!"fixture-test: {script}: the CLI over a real loop thread and the stepped run printed the same, and it is expected"
    return 0
  for problem in problems do
    harness.say s!"fixture-test: {script}: {problem}"
  return 1

end Editor.Test.Fixture
