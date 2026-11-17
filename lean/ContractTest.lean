import Editor.Api.Cases
import Editor.Clipboard.Contract
import Editor.Clipboard.InProcess
import Editor.Clipboard.Real
import Editor.Command.Model
import Editor.Command.Real
import Editor.Compile.Compiled
import Editor.Compile.Shipped
import Editor.Display.Contract
import Editor.Display.Real
import Editor.Display.Recorder
import Editor.Event.Queue
import Editor.Evil.TreeObjects
import Editor.Ex.Compiled
import Editor.File.Cases
import Editor.Files.Compiled
import Editor.Completion.StyleContract
import Editor.Completion.Styles
import Editor.Fuzzy.Contract
import Editor.Fuzzy.Real
import Editor.Indent
import Editor.InputScheme.Test
import Editor.Job.Contract
import Editor.Job.Fake
import Editor.Job.Pool
import Editor.Job.Real
import Editor.Key.Notation
import Editor.Loop
import Editor.Shell.Compiled
import Editor.SyntaxTree.Contract
import Editor.SyntaxTree.Real
import Editor.Text.Contract
import Editor.Text.Model
import Editor.Text.Real
import Editor.UndoTree.Cases
import Editor.Watch.Contract
import Editor.Watch.Real
import Editor.Workspace.Compiled
import Editor.Workspace.Contract

/-!
# The contract checks against the real bindings

The `contract-test` executable runs each port's contract against the port's
real binding, so against the Rust library: it is linked like `editor`, with
the glue object and the Rust archive. `model-test` runs the same lists
against the pure models. A property that holds of one and not of the other
fails one of the two, which is what keeps a model from drifting from the
library.

- The text port's contract (`Editor/Text/Contract.lean`) against its real
  binding (`Editor/Text/Real.lean`), and the properties of taking a job's
  snapshot into the store, each in a run handed snapshots the library made
  (`runHanded`). Beside them, what only the real binding can show, since it
  is about the library's objects and the binding's own table: that the
  binding's table is the only holder of its documents and of its snapshots,
  that releasing one frees it at once, and that the read half of its
  published table of snapshots finds what a command took and nothing a
  command released (`failures`, `releaseFrees`, `readerFinds`).
- The binding's bracket walk against the text model's, at every position of
  texts with quotes and for every question the walk can be asked
  (`pairChecks`): the quote rule is ported to both, and the contract's tables
  pin it only at the cases they name.
- The cases of the undo tree (`Editor/UndoTree/Cases.lean`), which is plain
  Lean over the text port, through the same binding and in the same run, so
  the count of live documents covers the texts they make. `model-test` runs
  them against the text model.
- The job port's contract (`Editor/Job/Contract.lean`) against the runner
  over the library's timer service, with the completion pump
  (`Editor/Job/Real.lean`). `model-test` runs it against the model and
  against the runner over the fake clock. So it runs the post properties
  (`JobContract.postProperties`, `postFailures`), each job spawned with a
  host that records the posts it is handed.
- The job port's file properties (`JobContract.fileProperties`) against the
  runner over the library's file service, on real files
  (`runFilesOnService`, `fileFailures`). Each property has a temporary
  directory of its own, made here, handed to its job as a path, read back
  when the job has ended and removed whatever happened; no file is touched
  anywhere else. `model-test` runs the same list against the model of files
  and against the runner over the fake of the file service.

- The job port's watch properties (`JobContract.fileWatchProperties`)
  against the runner over the library's watch and process services, on real
  files (`runWatchesOnService`, `fileWatchFailures`), each in a temporary
  directory of its own; the library's count of pending watches must be back
  where it was afterwards, so every watch ended with its job.
  `fileWatchChecks` then shows that a job's watch does not outlive it, and
  that a change whose path is not UTF-8 is delivered as missed of the
  watch's own path, on a volume that allows such a name.
- The job port's process properties (`JobContract.processProperties`)
  against the runner over the library's process service, on real processes
  (`runProcessesOnService`, `processFailures`), each in a temporary
  directory of its own, made here and removed whatever happened; the
  library's count of pending runs must be back where it was afterwards, so
  every child was reaped. `processChecks` then shows that cancelling a job
  whose child is running ends the job and has the child reaped, and that a
  run the library does not take, its id being in use there, is refused at
  once as `failed`, the job going on, with the refusal kept until it is
  taken and erased when its wait is withdrawn. It also shows that a run with
  a time limit, taken within the limit, cancelled before it or timed out,
  leaves no run in the adapter's table of armed limits and no alarm in the
  table of waits, and its child reaped.
  `model-test` runs the same list against the model of processes and
  against the runner over the fake of the process service.

`jobChecks` then pins what only the real service can show: that a job in a
real wait holds no thread, that cancelling a job takes its timer out of the
library's schedule, that a deadline no machine word holds is not cut down,
and that the pump is not one of the pool's tasks.

The cases that cross the text port and the job port
(`Editor/File/Cases.lean`) are played on the real binding and the library's
file service, on real files (`playOnLibrary`, `caseFailures`): a command, a
job on the runner, the job's command run by `Job.finishWith`, as the loop
runs it, and a last command. `model-test` plays them on the two models.

`fileChecks` pins what only the file service and the real text binding
together can show: that a load writes nothing to the editor's table of
snapshots until the job's command adopts it, that what a job loaded is
freed when the job is settled, that cancelling a job leaves the file
service with nothing of it, and that a job saves a snapshot a command took
through the published table and is refused one the command has released.

The display interface's contract (`Editor/Display/Contract.lean`) is run
against its real binding (`Editor/Display/Real.lean`) over the library's
fake shaper, at the cell sizes `model-test` runs it against the model at
(`displayFailures`): each property's texts are made documents and
snapshots in the library, entered in a table of the text binding, and the
property runs against a new display over that table.

The same contract is run against the recorder a host with no window answers
it with (`Editor/Display/Recorder.lean`), over snapshots the library made,
at the same two cell sizes (`recorderFailures`). `recorderChecks` pins what
only the recorder shows: that it keeps and counts what is published, and
that it reads the table of snapshots as it is when asked.

The clipboard interface's contract (`Editor/Clipboard/Contract.lean`) is run
against the clipboard a host with no window keeps
(`Editor/Clipboard/InProcess.lean`), one clipboard for the whole list, so
each property finds what the one before it left (`clipboardFailures`), and
against the real binding (`Editor/Clipboard/Real.lean`) over the library's
memory clipboard, so that no run reads or writes the desktop's
(`realClipboardFailures`). `model-test` runs the same list against the
model. `clipboardChecks` pins
what the contract cannot: that a new one holds no text, and, with a command
run against the library, that the command's clipboard requests go to the
handler it was handed, and are each answered `unavailable` when it was
handed none; and, over the library's failing clipboard, a fake of one that
cannot be reached, that a failed read and a failed write cross the glue
with the library's reason whole and that the real binding answers each
`unavailable`.

The fuzzy matching interface's contract (`Editor/Fuzzy/Contract.lean`) is
run against its real binding (`Editor/Fuzzy/Real.lean`), so against the
library's matcher (`fuzzyFailures`): which candidates a pattern matches,
and that a candidate that is the pattern is first. `model-test` runs the
same list against the model. Nothing more is asked of the two: after the
candidates that are the pattern, the binding's order is the library's
scores and the model's is the candidates' own. `fuzzyChecks` pins where a
command's fuzzy requests go when it is run against the library: to that
binding, with nothing handed in.

The completion styles' contract (`Editor/Completion/StyleContract.lean`) is
run against the fuzzy style over that binding (`styleFailures`), and
`model-test` runs it against the fuzzy style over the model, the orderless
style and the style model: which indices a style answers, its ranges, and
that the empty text lists every candidate.

The watch port's contract (`Editor/Watch/Contract.lean`) is run against its
real binding (`Editor/Watch/Real.lean`), over the library's interrupt flag
and the library's timer service (`watchFailures`): the interrupt keys a
property needs arrive through the library's window input, as a window's
would. `model-test` runs the same list against the watch model.
`watchChecks` pins what only the real binding shows: that its clock is the
job port's, read from a fake clock here, and, with the command loop over
the real text binding, an interrupt key that arrives while a command runs.
That check is single-threaded, so where the key arrives is exact: the
display handler posts it during one of the command's own publishes.

The syntax tree interface's contract (`Editor/SyntaxTree/Contract.lean`) is
run against its real binding (`Editor/SyntaxTree/Real.lean`), so against the
library's syntax service, tree-sitter's JSON grammar over its worker thread
(`syntaxTreeFailures`): each property's texts are made documents and
snapshots in the library, entered in a table of the text binding, and the
property runs against a new binding over that table. The library parses off
the editor thread, so the runner's handler waits, with a bound, for the
snapshot's tree to be delivered before it forwards each question of
captures (`Ffi.syntaxSettle`): the one difference from `model-test`'s run of
the same list against the model. `syntaxTreeChecks` pins what only the real
binding shows: that the library has a Rust grammar, a Rust function's name
captured, a query of one grammar asked of a text parsed with another, and a
text edited through its document reparsed, its new function's name captured
once the tree of the edit is delivered. That the text of a file the file
service loaded is of no document is `ffi-test`'s (`FfiTest.syntaxChecks`).

`shellChecks` runs `:!` and a filter (`Editor/Shell.lean`) over the real
process service, with the command loop over the real text binding: the ex
line's commands and the shell's are registered, the editor's working
directory is the fixtures' (`tests/shell`), and each line is run as a host
runs it, its invocations as steps of their own, each job it starts spawned
on the runner over the library's services and its command delivered once
the job has ended (`settle`). `:!` of the fixture `hello` leaves `hello` in
the echo area, and `%!/usr/bin/sort` over `b`, `c`, `a` leaves `a`, `b`,
`c`; every child is reaped.

`compileChecks` runs `compile` (`Editor/Compile.lean`) over the real process
service, with the command loop over the real text binding, in a temporary
directory of its own as the editor's working directory: its job is spawned
on the runner over the library's services with a host that records its
posts, and each post is delivered as it arrives. The fixture
`tests/compile/three-lines` waits for a file before each of its last two
lines, which the check makes only once it has seen the line before in the
compilation buffer: so each line is shown before the child ends, the last
line says its exit status, 2, and the child is reaped.

The cases of the editor API (`Editor/Api/Cases.lean`) are played on the
real text binding, with a recorder as the display and nothing watched
(`apiFailures`): each from a table of its own, dropped with the case.
`model-test` plays the same list on the editor's models, so every request
an operation of the API makes of the library is answered the same by both.

`main` starts the pump once, on a dedicated task. When the checks are done
it quits the queues, requires the pump to have ended, and exits explicitly:
that is the shutdown sequence, and returning from `main` while a dedicated
task is blocked in the library would hang.

A check waits for what the library does with a bound, so a broken service
fails a check within seconds. Deadlines are an hour away where a wait must
not complete, and 0 to 3 ms where it must: no check sleeps to let something
happen.

No check knows how many threads Lean's pool has. That number is Lean's, and
`LEAN_NUM_THREADS` in the environment changes it, so `main` learns the
pool's threads by warming it before the pump starts, and the check of the
pump is stated relative to them.

`mise run ffi-test` runs it, in the gate. It names what did not hold and
exits non-zero if anything did not.
-/

namespace ContractTest

open Editor

/-- What must hold of the binding's tables once the contract has run. It is
not a property of the port, which has no way to say it: it is about the
library's objects, which only the real binding has. -/
def tableName : String :=
  "the real binding's table is the only holder of its documents and of its snapshots: they are all freed when it is dropped"

/-- What must hold of a release in the real binding. Like `tableName`, it is
about the library's objects, so the port cannot say it. -/
def releaseName : String :=
  "releasing a text or a snapshot frees the library's object at once, while the table is still held"

/-- Whether a release frees the library's object at once. A command makes two
texts and two snapshots and releases one of each; then, with the table it
left still held, the library must hold one document and one snapshot more
than before. -/
def releaseFrees : IO Bool := do
  let documents ← Ffi.Document.live
  let snapshots ← Ffi.Snapshot.live
  let command : TextM Unit := do
    let kept ← createText "kept"
    let dropped ← createText "dropped"
    discard kept.snapshot
    let released ← kept.snapshot
    released.release
    dropped.release
  let (result, table) ← command.runReal (← RealTexts.new)
  let documentsHeld ← Ffi.Document.live
  let snapshotsHeld ← Ffi.Snapshot.live
  -- The table is read here, so it is alive until now. A released slot stays
  -- in it, empty.
  return result.isOk && documentsHeld == documents + 1 && snapshotsHeld == snapshots + 1 &&
      table.documents.size == 2 &&
      (← table.snapshots.size) == 2

/-- What must hold of the read half of the real binding's table of
snapshots, which is all a reader off the editor thread is given. It is about
the binding's own table, so the port cannot say it. -/
def readerName : String :=
  "a snapshot a command took is found through the read half of the binding's table by its id, and reads what the command read; one taken by a later command is found too; one a command released is not found, and neither is an id never given"

/-- Whether the read half of the table finds what the commands' own
questions read. One command takes two snapshots of a text with two- and
four-byte characters and an escape, at two revisions, and releases a third;
a second command, run on the table the first left, takes another. The reader
was made before either ran. -/
def readerFinds : IO Bool := do
  let snapshots ← Snapshots.new
  let reader := snapshots.reader
  let first : TextM (TextId × SnapshotId × SnapshotId × SnapshotId × String) := do
    let text ← createText (TextContract.loaded)
    let early ← text.snapshot
    text.insert 0 "x"
    let released ← text.snapshot
    let late ← text.snapshot
    released.release
    return (text, early, late, released, ← late.read)
  let (.ok (text, early, late, released, read), table) ←
    first.runReal (.over snapshots) | return false
  let some foundEarly ← reader.find? early | return false
  let some foundLate ← reader.find? late | return false
  let gone ← reader.find? released
  let never ← reader.find? ⟨7⟩
  let (.ok later, _) ← text.snapshot.runReal table | return false
  let some foundLater ← reader.find? later | return false
  return (← foundEarly.read) == "héllo\r\n😀".push (Char.ofNat 0x10DCFF) &&
      (← foundLate.read) == read &&
      read == "xhéllo\r\n😀".push (Char.ofNat 0x10DCFF) &&
      (← foundLate.info).revision == 1 &&
      gone.isNone &&
      never.isNone &&
      (← foundLater.read) == read

/-- Runs `command` against the real binding, from a table with no texts, in
a run that is handed `arrived` as what a job held: for each, a snapshot the
library made of a document holding the string. The documents, the snapshots
and the table are dropped with the run. -/
def runHanded (arrived : Array (JobSnapshotId × String)) (command : TextM Bool) :
    IO (Except TextError Bool) := do
  let handed ← arrived.mapM fun (id, text) => return (id, ← (← Ffi.Document.new text).snapshot)
  return (← command.runReal (← RealTexts.new) handed).1

/-- A display recorder that reads `table`: the display a command run over
that table is handed, as the headless host hands its loop one. -/
def recorderOf (table : Snapshots) : BaseIO DisplayRecorder :=
  DisplayRecorder.new { advance := 1, lineHeight := 1 } table.reader

/-- What must hold of the library's objects once the cases of the editor API
have run. -/
def apiLeakName : String :=
  "the cases of the editor API leave nothing behind: each table is dropped with its case, and the library holds the documents and the snapshots it held before"

/-- The names of the cases of the editor API (`Editor/Api/Cases.lean`) that
do not hold of the real text binding, each played from a table with no
texts, with a recorder over that table as the display and nothing watched.
`apiLeakName` is among them if the library's counts are not then what they
were. -/
def apiFailures : IO (List String) := do
  let before := (← Ffi.Document.live, ← Ffi.Snapshot.live)
  let failed ←
    ApiCases.failures
        (fun play => do
          let table ← Snapshots.new
          return (← play.runReal (.over table) (← recorderOf table).handle).1)
        ApiCases.cases
  let after := (← Ffi.Document.live, ← Ffi.Snapshot.live)
  return failed.map (s!"the real text binding: {·}") ++
      if after == before then []
      else
        [s!"{apiLeakName} ({before.1} documents and {before.2} snapshots before, {after.1} and {after.2} after)"]

/-- Runs `properties` against the real binding, each from a table with no
texts, and then `adoptProperties`, each in a run handed its snapshots
(`runHanded`), and returns the names of those that did not hold. Each table
is dropped with its run, and so is what a run was handed, so the counts of
live documents and of live snapshots must then be what they were before: if
either is not, `tableName` is among the names. `releaseName` is among them
if a release did not free its object at once. -/
def failures (properties : List TextContract.Property)
    (adoptProperties : List TextContract.AdoptProperty) : IO (List String) := do
  let before := (← Ffi.Document.live, ← Ffi.Snapshot.live)
  let held ←
    TextContract.failures (fun command => return (← command.runReal (← RealTexts.new)).1) properties
  let failed := held ++ (← TextContract.adoptFailures runHanded adoptProperties)
  let released ← releaseFrees
  let found ← readerFinds
  let after := (← Ffi.Document.live, ← Ffi.Snapshot.live)
  return failed ++ (if released then [] else [releaseName]) ++
      (if found then [] else [readerName]) ++
      if after == before then []
      else
        [s!"{tableName} ({before.1} documents and {before.2} snapshots before, {after.1} and {after.2} after)"]

/-- How long a check waits, in milliseconds, for something that should happen
at once. Only broken code takes this long, and the check then fails instead
of hanging. -/
def patience : Nat :=
  5000

/-- Polls `condition` until it holds; `false` if it still does not after
`patience` milliseconds. -/
def eventually (condition : IO Bool) : IO Bool := do
  let deadline := (← IO.monoMsNow) + patience
  repeat
    if ← condition then
      return true
    if (← IO.monoMsNow) >= deadline then
      break
    IO.sleep 1
  return false

/-- An hour, in milliseconds: how long a job sleeps when its wait must not
complete while a check runs. -/
def hour : Nat :=
  3600000

/-- A job's outcome as a check compares it: the command it finished with is
replaced by the texts that command leaves when it runs against the editor's
models, since commands cannot be compared. -/
def texts : Job.Outcome (EditorM Unit) → Job.Outcome (Array String)
  | .finished command =>
    .finished (command.runModel (.over { advance := 1, lineHeight := 1 })).2.texts.contents
  | .failed message => .failed message
  | .cancelled => .cancelled

/-- `job` as it is spawned by a check: it finishes with a command that makes
one text, the job's value as a string. -/
def reporting {α : Type} [ToString α] (job : Unit → JobM α) : Work :=
  Work.of job fun value => discard <| createText (toString value)

/-- Whether the job behind `handle` ended as `expected`, within the bound. -/
def endedAs (handle : Job.Handle) (expected : Job.Outcome (Array String)) : IO Bool := do
  let ended ← eventually handle.ended
  return ended && (← handle.outcome?).map texts == some expected

/-- Runs `job` on the runner over the library's services, and returns how it
ended. A job that does not end in time has failed, and is cancelled. A job
that ended is settled, as whoever takes a finished job's result settles it,
so what its loads made is released. -/
def runOnTimers (services : Job.Services) (job : JobM Bool) : IO (Job.Outcome Bool) := do
  let handle ← Job.spawn services (reporting fun _ => job) (pure ())
  unless ← eventually handle.ended do
    handle.cancel
    return .failed "the job did not end"
  handle.settle
  match (← handle.outcome?).map texts with
  | some (.finished texts) =>
    return .finished (texts == #["true"])
  | some (.failed message) =>
    return .failed message
  | _ =>
    return .cancelled

/-- The names of the job port's contract properties that do not hold of the
runner over the library's timer service. -/
def jobFailures (services : Job.Services) : IO (List String) := do
  let failed ← JobContract.failures (runOnTimers services) JobContract.properties
  return failed.map (s!"the job runner over the timer service: {·}")

/-- Runs `job` on the runner over the library's services, spawned with a host
that records each post it is handed, and answers the posts once the job has
ended. A job that does not end in time is cancelled, and a job that ended is
settled. -/
def postedOnTimers (services : Job.Services) (job : JobM Unit) : IO (Array Invocation) := do
  let posts ← IO.mkRef #[]
  let handle ←
    Job.spawn services (Work.of (fun _ => job) fun _ => pure ()) (pure ()) fun invocation =>
        posts.modify (·.push invocation)
  unless ← eventually handle.ended do
    handle.cancel
  handle.settle
  posts.get

/-- The names of the job port's post properties that do not hold of the
runner over the library's timer service. -/
def postFailures (services : Job.Services) : IO (List String) := do
  let failed ← JobContract.postFailures (postedOnTimers services) JobContract.postProperties
  return failed.map (s!"the job runner over the timer service: {·}")

/-- Everything in `directory`, each as its name and its bytes. A directory
there would be a surprise too: it is named, with no bytes. -/
def filesOf (directory : System.FilePath) : IO (Array (String × ByteArray)) := do
  let mut files := #[]
  for entry in ← directory.readDir do
    let bytes ←
      if ← entry.path.isDir then
        pure ByteArray.empty
      else
        IO.FS.readBinFile entry.path
    files := files.push (entry.fileName, bytes)
  return files

/-- Runs a file property's job on the runner over the library's file
service, on real files: how the job ended, and the files afterwards.

The files are in a temporary directory made here for this one property,
whose path the job is handed; nothing else is written anywhere. The
property's files are written into it, the job runs, every file then in it is
read back, and it is removed, whatever happened. -/
def runFilesOnService (services : Job.Services) (property : JobContract.FileProperty) :
    IO (Job.Outcome Bool × Array (String × ByteArray)) := do
  let directory ← IO.FS.createTempDir
  try
    for (name, bytes) in property.files do
      IO.FS.writeBinFile (directory / name) bytes
    let outcome ← runOnTimers services (property.holds directory)
    return (outcome, ← filesOf directory)
  finally
    IO.FS.removeDirAll directory

/-- What must hold of the library's objects once the file properties have
run: it is about the library's counts, so the port cannot say it. -/
def fileLeakName : String :=
  "what the jobs of the file properties loaded is released when each job is settled, and no request is left in the file service"

/-- The names of the job port's file and diff properties that do not hold of
the runner over the library's file and diff services, on real files.
`fileLeakName` is among them if the library then holds a snapshot more than
before, `held` still holds one, or the file service or the diff service has a
request or a result left. -/
def fileFailures (services : Job.Services) (held : Job.HeldSnapshots) : IO (List String) := do
  let pending : IO UInt64 := return (← Ffi.filesPending) + (← Ffi.diffsPending)
  let before := (← Ffi.Snapshot.live, ← pending)
  let failed ←
    JobContract.fileFailures (runFilesOnService services)
        (JobContract.fileProperties ++ JobContract.diffProperties)
  let freed ←
    eventually do
        return (← Ffi.Snapshot.live, ← pending) == before && (← held.size) == 0
  let after := (← Ffi.Snapshot.live, ← pending, ← held.size)
  return failed.map (s!"the job runner over the file service: {·}") ++
      if freed then []
      else
        [s!"{fileLeakName} ({before.1} snapshots and {before.2} requests before, {after.1} and {after.2.1} after, {after.2.2} held)"]

/-- One behaviour, and how to observe it. -/
structure Check where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the behaviour; `true` when it holds. -/
  run : IO Bool

/-- Runs a process property's job on the runner over the library's process
service, on real processes: how the job ended.

Its commands run in a temporary directory made here for this one property,
whose path the job is handed; the property's files are written into it, and
it is removed, whatever happened. -/
def runProcessesOnService (services : Job.Services) (property : JobContract.ProcessProperty) :
    IO (Job.Outcome Bool) := do
  let directory ← IO.FS.createTempDir
  try
    for (name, bytes) in property.files do
      IO.FS.writeBinFile (directory / name) bytes
    runOnTimers services (property.holds directory)
  finally
    IO.FS.removeDirAll directory

/-- What must hold of the library's process service once the process
properties have run: it is about the library's count, so the port cannot say
it. -/
def processLeakName : String :=
  "every child the process properties ran is reaped, and the process service keeps no result"

/-- The names of the job port's process properties that do not hold of the
runner over the library's process service, on real processes.
`processLeakName` is among them if the service then has a run or a result
more than before. -/
def processFailures (services : Job.Services) : IO (List String) := do
  let before ← Ffi.processesPending
  let failed ←
    JobContract.processFailures (runProcessesOnService services) JobContract.processProperties
  let reaped ← eventually (return (← Ffi.processesPending) == before)
  let after ← Ffi.processesPending
  return failed.map (s!"the job runner over the process service: {·}") ++
      if reaped then [] else [s!"{processLeakName} ({before} before, {after} after)"]

/-- Runs a watch property's job on the runner over the library's watch and
process services, on real files: how the job ended.

Its directories and files are made in a temporary directory made here for
this one property, whose path the job is handed, and it is removed, whatever
happened. -/
def runWatchesOnService (services : Job.Services) (property : JobContract.FileWatchProperty) :
    IO (Job.Outcome Bool) := do
  let directory ← IO.FS.createTempDir
  try
    for name in property.directories do
      IO.FS.createDir (directory / name)
    for (name, bytes) in property.files do
      IO.FS.writeBinFile (directory / name) bytes
    runOnTimers services (property.holds directory)
  finally
    IO.FS.removeDirAll directory

/-- What must hold of the library's watch service once the watch properties
have run: it is about the library's count, so the port cannot say it. -/
def watchLeakName : String :=
  "every watch the watch properties started is ended with its job, and the watch service keeps no reply"

/-- The names of the job port's watch properties that do not hold of the
runner over the library's watch service, on real files. `watchLeakName` is
among them if the service then has a watch or a wait more than before. -/
def fileWatchFailures (services : Job.Services) : IO (List String) := do
  let before ← Ffi.watchesPending
  let failed ←
    JobContract.fileWatchFailures (runWatchesOnService services) JobContract.fileWatchProperties
  let ended ← eventually (return (← Ffi.watchesPending) == before)
  let after ← Ffi.watchesPending
  return failed.map (s!"the job runner over the watch service: {·}") ++
      if ended then [] else [s!"{watchLeakName} ({before} before, {after} after)"]

/-- The checks of the watch service's adapter that only the library can
show: a job's watch does not outlive it, and a path that is not UTF-8 is
delivered as missed of the watch's own path. -/
def fileWatchChecks (services : Job.Services) : List Check :=
  [{  name :=
        "a job's watch does not outlive it: once the job has ended the watch service holds nothing of it, and a write is delivered to no one"
      run := do
        let directory ← IO.FS.createTempDir
        try
          let before ← Ffi.watchesPending
          let job : JobM Bool := do
            let .ok _ ←
              FileWatch.start (.file (directory / "f")) JobContract.watchCoalescing | return false
            return true
          let outcome ← runOnTimers services job
          let ended ← eventually (return (← Ffi.watchesPending) == before)
          IO.FS.writeFile (directory / "f") "x"
          let stillEnded := (← Ffi.watchesPending) == before
          return outcome == .finished true && ended && stillEnded
        finally
          IO.FS.removeDirAll directory },
    { name :=
        "a change whose path is not UTF-8 is delivered as missed of the watch's own path, where the volume allows such a name"
      run := do
        let directory ← IO.FS.createTempDir
        try
          let job : JobM Bool := do
            let watch ← JobContract.watching (.directory directory false)
            let made ←
              Process.run (JobContract.sh directory "printf x > \"$(printf '\\377')\"") 1000
            match made with
            | .ok { exit := .code 0, .. } =>
              let told ← JobContract.readUntil watch (JobContract.toldIn · directory .missed)
              -- Lean cannot name the file to remove it: its name is not a
              -- string. So the shell that made it removes it.
              discard <| Process.run (JobContract.sh directory "rm -f \"$(printf '\\377')\"") 1000
              return told
            | made =>
              -- The volume refuses the name (APFS does): there is nothing
              -- to deliver. The job leaves a marker saying why, and the
              -- check says so on stderr.
              let why :=
                match made with
                | .ok ran => s!"{repr ran.exit}: {String.fromUTF8! ran.stderr}"
                | .error error => error.describe
              discard <|
                  Process.run (JobContract.sh directory s!"printf '%s' '{why}' > refused") 1000
              return true
          let outcome ← runOnTimers services job
          if outcome == .finished true then
            if ← (directory / "refused").pathExists then
              IO.eprintln
                  s!"contract-test: the volume refuses a name that is not UTF-8, so the change of one was not checked here ({← IO.FS.readFile (directory / "refused")})"
          return outcome == .finished true
        finally
          IO.FS.removeDirAll directory }]

/-- Whether `reply` is the refusal `expected`. -/
def refusedAs (expected : ProcessError) : Except ProcessError Process.Ran → Bool
  | .error refusal => refusal == expected
  | .ok _ => false

/-- Starts, straight through the library's bindings, a run under the id
`id` that sleeps for ten minutes in `directory`, so that the library's
process service refuses another run under that id. It is never completed: a
check cancels it before it ends. Whether the library took it. -/
def occupy (id : UInt64) (directory : System.FilePath) : IO Bool :=
  Ffi.processesRun id "/bin/sleep" #["600"] false #[] #[] directory.toString 10

/-- Runs `check` in a temporary directory of its own, removed whatever
happened, on `services` with a real process service whose table of the runs
with a time limit armed is one the check holds, so it can read how many
there are. -/
def timedCheck (services : Job.Services)
    (check : System.FilePath → Job.Services → Job.TimedRuns → IO Bool) : IO Bool := do
  let directory ← IO.FS.createTempDir
  let timed ← Job.TimedRuns.new
  let services :=
    { services with
      processes :=
        Job.realProcesses services.completions (← Job.RefusedRuns.new) services.timers timed }
  try
    check directory services timed
  finally
    IO.FS.removeDirAll directory

/-- What only the real process service can show: that cancelling a job
whose child is running kills the child, which the service then reaps; and
that a run the library does not take is refused at once by the adapter,
which keeps the refusal until it is taken or its wait is withdrawn
(`realProcesses`). The library refuses a run whose id is in use there, so
those checks first start a run under the id with `occupy`.

Each such check has its own table of refusals, and registers its ids in the
services' table of waits, so no id is one another wait in flight has. The
id the job's first wait gets is the one after the id the check registers:
no other wait is registered while a check runs. If it were not, the job's
run would be taken and the check would fail, not pass.

Seen to bite once by hand, on 2026-11-15, each with one line of
`realProcesses` taken out: without the completion of a run not taken, both
not-taken checks fail, the job waiting for ever; without keeping its
refusal, the first fails, the job getting no result instead; and without
the erasing in `cancel`, the second fails, the take finding the refusal.

The last three are the runs with a time limit, each on a table of the runs
whose alarm is armed that the check holds (`timedCheck`): taken within the
limit, cancelled before it, and timed out. Seen to bite once by hand, on
2026-11-16: without the disarming in the take, the first fails, its alarm
left in the table of waits; without the take and disarming in `cancel`, the
second fails; and with a timed-out run put back in the table at its take,
the third fails. -/
def processChecks (services : Job.Services) : List Check :=
  [{  name :=
        "a job whose child sleeps for ten minutes is cancelled: it ends cancelled, and the process service reaps the child, so nothing is pending that was not before"
      run := do
        let directory ← IO.FS.createTempDir
        try
          let before ← Ffi.processesPending
          let handle ←
            Job.spawn services
                (reporting fun _ => do
                  discard <| Process.run (JobContract.sh directory "/bin/sleep 600") 10
                  return true)
                (pure ())
          -- The run is in the library once the service counts it.
          let started ← eventually (return (← Ffi.processesPending) == before + 1)
          handle.cancel
          let cancelled ← endedAs handle .cancelled
          let reaped ← eventually (return (← Ffi.processesPending) == before)
          return started && cancelled && reaped
        finally
          IO.FS.removeDirAll directory },
    { name :=
        "a run the library does not take, its id being in use there, is refused at once as failed, and the job goes on to a run that ends; the refusal is gone once taken"
      run := do
        let directory ← IO.FS.createTempDir
        let refused ← Job.RefusedRuns.new
        let services :=
          { services with
            processes :=
              Job.realProcesses services.completions refused services.timers (← Job.TimedRuns.new) }
        let (probe, _) ← services.completions.register
        services.completions.finish probe .completed
        let taken := probe + 1
        let before ← Ffi.processesPending
        try
          let occupied ← occupy taken directory
          let handle ←
            Job.spawn services
                (reporting fun _ => do
                  let first ← Process.run (JobContract.sh directory "exit 0") 10
                  let second ← Process.run (JobContract.sh directory "exit 0") 10
                  return refusedAs Job.runNotTaken first &&
                      match second with
                      | .ok ran => ran.exit == .code 0
                      | .error _ => false)
                (pure ())
          let ended ← endedAs handle (.finished #["true"])
          unless ended do
            handle.cancel
          -- Asked again, the refusal is not there: the library answers, and
          -- it has no result for its own run under the id, still sleeping.
          let again ← services.processes.take taken (.run (JobContract.sh directory "exit 0") 10)
          discard <| Ffi.processesCancel taken
          let reaped ← eventually (return (← Ffi.processesPending) == before)
          return occupied && ended && refusedAs Job.runNoResult again && reaped
        finally
          discard <| Ffi.processesCancel taken
          IO.FS.removeDirAll directory },
    { name :=
        "a run the library does not take completes its wait at once, and withdrawing the wait erases the refusal kept for it"
      run := do
        let directory ← IO.FS.createTempDir
        let processes :=
          Job.realProcesses services.completions (← Job.RefusedRuns.new) services.timers
            (← Job.TimedRuns.new)
        let (id, wait) ← services.completions.register
        let before ← Ffi.processesPending
        let request := ProcessRequest.run (JobContract.sh directory "exit 0") 10
        try
          let occupied ← occupy id directory
          processes.start id request
          let completed ← wait.isResolved
          -- The withdrawal also cancels the library's run under the id.
          processes.cancel id
          let taken ← processes.take id request
          let reaped ← eventually (return (← Ffi.processesPending) == before)
          return occupied && completed && refusedAs Job.runNoResult taken && reaped
        finally
          discard <| Ffi.processesCancel id
          services.completions.finish id .completed
          IO.FS.removeDirAll directory },
    { name :=
        "a run with a time limit that ends well inside it, once taken, leaves no run in the table of time limits and its alarm disarmed: the table of waits is as it was"
      run :=
        timedCheck services fun directory services timed => do
          let waiting ← services.completions.waiting
          let outcome ←
            runOnTimers services do
                return (← Process.runWithin (JobContract.sh directory "exit 0") 10 hour) matches
                    .ok { exit := .code 0, .. }
          let disarmed ←
            eventually do
                return (← timed.size) == 0 && (← services.completions.waiting) == waiting
          return outcome == .finished true && disarmed },
    { name :=
        "a run with a time limit cancelled with its job before the limit leaves no run in the table of time limits and its alarm disarmed, and its child is reaped"
      run :=
        timedCheck services fun directory services timed => do
          let waiting ← services.completions.waiting
          let before ← Ffi.processesPending
          let handle ←
            Job.spawn services
                (reporting fun _ => do
                  discard <| Process.runWithin (JobContract.sh directory "/bin/sleep 600") 10 hour
                  return true)
                (pure ())
          let armed ←
            eventually do
                return (← Ffi.processesPending) == before + 1 && (← timed.size) == 1
          handle.cancel
          let cancelled ← endedAs handle .cancelled
          let disarmed ←
            eventually do
                return (← timed.size) == 0 && (← services.completions.waiting) == waiting
          let reaped ← eventually (return (← Ffi.processesPending) == before)
          return armed && cancelled && disarmed && reaped },
    { name :=
        "a run with a time limit that outlives it answers timed out, and then leaves no run in the table of time limits and nothing in the table of waits, and its child is reaped"
      run :=
        timedCheck services fun directory services timed => do
          let waiting ← services.completions.waiting
          let before ← Ffi.processesPending
          let outcome ←
            runOnTimers services do
                return refusedAs (.timedOut 200)
                    (← Process.runWithin (JobContract.sh directory "/bin/sleep 600") 10 200)
          let disarmed ←
            eventually do
                return (← timed.size) == 0 && (← services.completions.waiting) == waiting
          let reaped ← eventually (return (← Ffi.processesPending) == before)
          return outcome == .finished true && disarmed && reaped }]

/-- `count` jobs that each sleep for an hour. -/
def sleepers (services : Job.Services) (count : Nat) : IO (Array Job.Handle) := do
  let mut jobs := #[]
  for _ in [0:count] do
    jobs :=
      jobs.push
        (←
          Job.spawn services
              (reporting fun _ => do
                sleep hour
                return true)
              (pure ()))
  return jobs

/-- How long a warming waits, in milliseconds, for a task to start before it
takes the pool to be full. A task starts on a free thread in microseconds. -/
def warmPatience : Nat :=
  200

/-- The checks of the runner over the library's timer service
(`Editor/Job/Real.lean`): what only the real service can show. It is a
function, not a constant, because it calls bindings.

`pool` is the threads the pool was seen to have before the pump was started
(`Pool.whole`). No check knows the pool's size otherwise: that number is
Lean's, and `LEAN_NUM_THREADS` changes it. -/
def jobChecks (services : Job.Services) (pool : Array UInt64) : List Check :=
  -- More jobs than the pool has threads, and at least 64.
  let many := max 64 (pool.size + 1)
  [{
      name :=
        "jobs in real waits do not delay a new pool task: more jobs than the pool has threads all have a timer in the library while a new pool task runs",
      run := do
        let before ← Ffi.timersPending
        let jobs ← sleepers services many
        try
          -- Each job's timer is in the library's schedule, so every job has
          -- reached its wait.
          unless ← eventually (return (← Ffi.timersPending) == before + many.toUInt64) do
            return false
          let ran ← IO.Promise.new
          discard <| BaseIO.asTask (ran.resolve ())
          let notDelayed ← eventually ran.isResolved
          let allWaiting := (← Ffi.timersPending) == before + many.toUInt64
          let noneEnded ← jobs.allM fun job => return !(← job.ended)
          return notDelayed && allWaiting && noneEnded
        finally
          for job in jobs do
            job.cancel },
    { name :=
        "cancelling a job withdraws its timer: each job ends cancelled, and the library's schedule is back to what it held"
      run := do
        let before ← Ffi.timersPending
        let jobs ← sleepers services many
        try
          unless ← eventually (return (← Ffi.timersPending) == before + many.toUInt64) do
            return false
          for job in jobs do
            job.cancel
          let allCancelled ← jobs.allM (endedAs · .cancelled)
          return allCancelled && (← Ffi.timersPending) == before &&
              (← services.completions.waiting) == 0
        finally
          for job in jobs do
            job.cancel },
    { name :=
        "a deadline no machine word holds is not cut down: a job that waits for it is still waiting when a job that sleeps for nothing has finished"
      run := do
        let before ← Ffi.timersPending
        -- Cut down to a 64-bit word, `2 ^ 64 + 1` is 1: a deadline in the
        -- past, which the service would complete at once.
        let far ←
          Job.spawn services
              (reporting fun _ => do
                waitUntil (2 ^ 64 + 1)
                return true)
              (pure ())
        try
          unless ← eventually (return (← Ffi.timersPending) == before + 1) do
            return false
          let short ←
            Job.spawn services
                (reporting fun _ => do
                  sleep 0
                  return true)
                (pure ())
          let shortFinished ← endedAs short (.finished #["true"])
          -- The timers complete in the order of their deadlines, so had the
          -- far one been due it would have left the schedule first.
          let stillWaiting := (← Ffi.timersPending) == before + 1 && !(← far.ended)
          far.cancel
          return shortFinished && stillWaiting && (← endedAs far .cancelled)
        finally
          far.cancel },
    { name :=
        "a wait the timer service refuses ends the job as cancelled: it does not wait for ever"
      run := do
        -- Ids are a counter, so the id the job's wait will get is known: a
        -- timer that already has it makes the service refuse the job's.
        let (reserved, _) ← services.completions.register
        let taken := reserved + 1
        try
          unless ← Ffi.timersStart taken ((← Ffi.timersNow) + hour.toUInt64) do
            return false
          let jobs ← sleepers services 1
          let ended ← jobs.allM (endedAs · .cancelled)
          return ended && (← services.completions.waiting) == 1
        finally
          discard <| Ffi.timersCancel taken
          services.completions.finish reserved .cancelled },
    { name :=
        "the pump is not one of the pool's tasks: with the pump parked in its pull, every thread the pool had before the pump was started is still free to be held, and no other"
      run := do
        unless ← eventually (return (← Ffi.waiting .completion) == 1) do
          return false
        -- A pump that was a pool task would be parked on one of these
        -- threads, and the warming would stop one short.
        let threads ← Job.Pool.warm (pool.size + 2) warmPatience
        return !pool.isEmpty && threads.size == pool.size && threads.all pool.contains }]

/-- `handler`, a real syntax tree binding's over `table`, which after an
attach waits, with a bound, for the attached text's tree to be delivered:
so a highlighter set after the attach sees no delivery of that parse, and
no `parsed` event of it is left on the editor queue, which the watch checks
pull after these. A delivery a check makes after a highlight, by an edit,
leaves one, which the check pulls (`pulledParsed`). -/
def settlingAttach (table : Snapshots) (handler : SyntaxTreeHandler) : SyntaxTreeHandler :=
  fun request => do
  let reply ← handler request
  if let .attach snapshot _ := request then
    if let some found← table.find? snapshot then
      discard (Ffi.syntaxSettle found 5000)
  return reply

/-- `handler`, a real syntax tree binding's over `table`, which waits, with
a bound, for a snapshot's tree to be delivered before it forwards a question
of its captures or of a kept query's, and after an attach
(`settlingAttach`). -/
def settling (table : Snapshots) (handler : SyntaxTreeHandler) : SyntaxTreeHandler :=
  settlingAttach table fun request => do
    let asked :=
      match request with
      | .captures snapshot _ _ _ => some snapshot
      | .capturesOf snapshot _ _ _ => some snapshot
      | _ => none
    if let some snapshot := asked then
      if let some found← table.find? snapshot then
        discard (Ffi.syntaxSettle found 5000)
    handler request

/-- Whether the editor queue holds exactly one event, the library's report
of a parse delivered, which is pulled: what an edit of a highlighted text
leaves once its tree is delivered. It never parks a pull on an empty
queue. -/
def pulledParsed : IO Bool := do
  unless (← Ffi.queued .editor) == 1 do
    return false
  let event ← Ffi.nextEvent .editor
  return event.kind == .parsed && event.source.kind == .library

/-- How many events the editor queue held, each pulled: what a mode set over
a highlighted text leaves once its tree and its layers are delivered, the
library's reports of parses. It never parks a pull on an empty queue. -/
def drainedParsed : IO Nat := do
  let mut pulled := 0
  while (← Ffi.queued .editor) > 0 do
    discard (Ffi.nextEvent .editor)
    pulled := pulled + 1
  return pulled

/-- What a check of the runner over the library's file service works with: a
text store whose table of snapshots is published, the file service over its
read half, and a fake clock a check parks a job on. The file waits are
completed by the process's pump, through `completions`; the clock's by the
check. Each check has its own, over the process's one table of waits. -/
structure FileRig where
  /-- The table of snapshots the store publishes. -/
  published : Snapshots
  /-- What the rig's jobs hold. -/
  held : Job.HeldSnapshots
  /-- The clock a job of the rig sleeps on, which only the check moves. -/
  clock : Job.FakeClock
  /-- The table of waits, the clock and the library's file service. -/
  services : Job.Services

/-- A rig over the table of waits `completions`, which the pump serves. -/
def FileRig.new (completions : Job.Completions) : BaseIO FileRig := do
  let published ← Snapshots.new
  let held ← Job.HeldSnapshots.new
  let clock ← Job.FakeClock.new completions
  return {
      published, held, clock
      services :=
        { completions, timers := clock.timers
          files := Job.realFiles completions published.reader held } }

/-- A file's bytes, in the checks below: "héllo", a line feed, "😀" and the
byte `FF`, which is not UTF-8. Twelve bytes. -/
def noteBytes : ByteArray :=
  ⟨#[0x68, 0xC3, 0xA9, 0x6C, 0x6C, 0x6F, 0x0A, 0xF0, 0x9F, 0x98, 0x80, 0xFF]⟩

/-- The text `noteBytes` loads as, written out by hand. -/
def noteText : String :=
  "héllo\n😀".push (Char.ofNat 0x10DCFF)

/-- Runs `check` on a directory of its own holding `note.txt`, which holds
`noteBytes`, and removes the directory afterwards, whatever happened. -/
def withNote (check : System.FilePath → IO Bool) : IO Bool := do
  let directory ← IO.FS.createTempDir
  try
    IO.FS.writeBinFile (directory / "note.txt") noteBytes
    check directory
  finally
    IO.FS.removeDirAll directory

/-- The checks of the runner over the library's file service and the real
text binding (`Editor/Job/Real.lean`, `Editor/Text/Real.lean`): what only the
two together can show. It is a function, not a constant, because it calls
bindings. Every file is in a temporary directory its check makes and
removes. -/
def fileChecks (completions : Job.Completions) : List Check :=
  [{
      name :=
        "a load writes nothing to the editor's table: with a job parked after its load the published table is as it was and the library holds one snapshot more; the job's command adopts it into the table; and once the command has released it and the job is settled the library holds what it held",
      run :=
        withNote fun directory => do
          let rig ← FileRig.new completions
          let size ← rig.published.size
          let live ← Ffi.Snapshot.live
          let handle ←
            Job.spawn rig.services
                (reporting fun _ => do
                  discard <| JobContract.loaded (directory / "note.txt")
                  sleep 1000
                  return true)
                (pure ())
          try
            unless ← eventually (return (← rig.clock.waiting) == 1) do
              return false
            let parked :=
              (← rig.published.size) == size && (← Ffi.Snapshot.live) == live + 1 &&
                (← rig.held.size) == 1
            rig.clock.advance 1000
            unless ← eventually handle.ended do
              return false
            let #[loaded] ← handle.holding | return false
            -- The job's command, on this thread, as the loop runs it.
            let command : EditorM (SnapshotId × String) := do
              let adopted ← loaded.adopt
              return (adopted, ← adopted.read)
            let display := (← recorderOf rig.published).handle
            let (.ok (adopted, read), texts) ←
              Job.finishWith rig.held handle command (.over rig.published) display | return false
            let adoptedHeld :=
              (← rig.published.size) == size + 1 && (← Ffi.Snapshot.live) == live + 1 &&
                (← rig.held.size) == 0 &&
                (← handle.holding).isEmpty
            let (released, _) ← adopted.release.runReal texts
            return parked && read == noteText && adoptedHeld && released.isOk &&
                (← eventually (return (← Ffi.Snapshot.live) == live))
          finally
            handle.cancel },
    { name :=
        "a job's command run by Job.finishWith reaches the syntax tree it is handed: its text, highlighted as a mode with a syntax tree is entered, is attached in the library, and a query of it answers"
      run := do
        let rig ← FileRig.new completions
        let handle ← Job.spawn rig.services (reporting fun _ => pure 1) (pure ())
        unless ← eventually handle.ended do
          return false
        let real ← RealSyntaxTree.new rig.published.reader
        let syntaxTree := settlingAttach rig.published real.handle
        let command : EditorM SnapshotId := do
          let text ← createText "[1, 2]"
          Highlight.enter "json" text { grammar := "json" }
          text.snapshot
        let display := (← recorderOf rig.published).handle
        let (.ok snapshot, texts) ←
          Job.finishWith rig.held handle command (.over rig.published) display (syntaxTree :=
              syntaxTree) | return false
        let numbers : SyntaxTreeM Nat := do
          let query ← SyntaxTree.compile "json" "(number) @n"
          return (← SyntaxTree.captures snapshot query 0 6).size
        let some found ← rig.published.find? snapshot | return false
        unless ← Ffi.syntaxSettle found 5000 do
          return false
        let answered ← numbers.runWith syntaxTree
        -- The text's document is held until here: a document freed is
        -- detached.
        return answered matches .ok 2 && texts.documents.size == 1 },
    { name :=
        "a snapshot a job loaded that no command adopted is freed when the job is settled: the library holds what it held, and the editor's table never grew"
      run :=
        withNote fun directory => do
          let rig ← FileRig.new completions
          let live ← Ffi.Snapshot.live
          let handle ←
            Job.spawn rig.services
                (reporting fun _ => do
                  return (← JobContract.loaded (directory / "note.txt")).stamp.size)
                (pure ())
          let ended ← endedAs handle (.finished #["12"])
          let kept := (← Ffi.Snapshot.live) == live + 1 && (← rig.held.size) == 1
          let display := (← recorderOf rig.published).handle
          let (ran, _) ←
            Job.finishWith rig.held handle (pure () : EditorM Unit) (.over rig.published) display
          return ended && kept && ran.isOk &&
              (← eventually (return (← Ffi.Snapshot.live) == live)) &&
              (← rig.held.size) == 0 &&
              (← rig.published.size) == 0 },
    { name :=
        "cancelling a job whose load is in the file service behind other requests leaves the service and the runner with nothing of it, whether the cancel found the load waiting, being worked or done: the service's count is that of the requests ahead, and nothing is held"
      run :=
        withNote fun directory => do
          let rig ← FileRig.new completions
          let before ← Ffi.filesPending
          let live ← Ffi.Snapshot.live
          let snapshot ← (← Ffi.Document.new noteText).snapshot
          -- Five saves ahead of the job's load, started straight at the
          -- service under ids the table of waits gave out, so no job's wait
          -- has them. Each syncs its file, so the load is behind them.
          let mut ahead := #[]
          for index in [0:5] do
            let (id, _) ← completions.register
            unless
              ← Ffi.filesSave id snapshot (directory / s!"ahead-{index}.txt").toString .whatever do
              return false
            ahead := ahead.push id
          let handle ←
            Job.spawn rig.services
                (reporting fun _ => do
                  return (← JobContract.loaded (directory / "note.txt")).stamp.size)
                (pure ())
          try
            -- The job is in its wait once its request is at the service. On
            -- a file system that syncs slowly the load is still waiting
            -- then; on a fast one it may be done, and the job with it.
            let reached ←
              eventually do
                  return (← handle.flags.get).waiting.isSome || (← handle.ended)
            unless reached do
              return false
            handle.cancel
            let ended ← eventually handle.ended
            handle.settle
            -- The five ahead are waiting, being worked or done, and count
            -- either way; the job's load is gone, whichever it was.
            let withdrawn ← eventually (return (← Ffi.filesPending) == before + 5)
            -- The one snapshot left is the one made here, which is read last
            -- so that it is alive until then.
            return ended && withdrawn && (← rig.held.size) == 0 &&
                (← eventually (return (← Ffi.Snapshot.live) == live + 1)) &&
                (← snapshot.info).byteLength == 15
          finally
            handle.cancel
            for id in ahead do
              discard <| Ffi.filesCancel id
              completions.finish id .cancelled
            discard <|
                eventually do
                  return (← Ffi.filesPending) == before && (← Ffi.Snapshot.live) ≤ live + 1 },
    { name :=
        "a job saves a snapshot a command took, found through the published table, and a snapshot the command has released since is refused as naming none, and writes no file"
      run :=
        withNote fun directory => do
          let rig ← FileRig.new completions
          let take : TextM SnapshotId := do
            let text ← createText noteText
            let taken ← text.snapshot
            -- The text moves on: the snapshot does not.
            text.insert 0 "x"
            return taken
          let (.ok taken, texts) ← take.runReal (.over rig.published) | return false
          let saver (name : String) (job : System.FilePath → JobM Bool) : IO Bool := do
            let handle ←
              Job.spawn rig.services (reporting fun _ => job (directory / name)) (pure ())
            endedAs handle (.finished #["true"])
          let saved ←
            saver "taken.txt" fun path => do
                return (← JobContract.saved (.snapshot taken) path .absent).size == 12
          let (released, _) ← taken.release.runReal texts
          let refused ←
            saver "released.txt" fun path =>
                JobContract.saveRefusedAs .noSuchSnapshot (.snapshot taken) path .absent
          return saved && released.isOk && refused &&
              (← IO.FS.readBinFile (directory / "taken.txt")) == noteBytes &&
              !(← (directory / "released.txt").pathExists) }]

/-- Runs `checks` and returns the names of those that failed. A check that
throws has failed, and its error is reported with its name. -/
def checkFailures (checks : List Check) : IO (List String) :=
  checks.filterMapM fun check => do
    try
      return if ← check.run then none else some check.name
    catch error =>
      return some s!"{check.name} ({error})"

/-- The answers of the bracket walk over `contents` at every position, for
each kind, side, direction, escapedness and whether quoted brackets are
passed over, in that order: the question asked and the answer. -/
def unmatchedEverywhere (contents : String)
    (answer : Bracket → Bool → Bool → Bool → Bool → Nat → IO (Option Nat)) :
    IO (Array (String × Option Nat)) := do
  let mut answers := #[]
  for offset in
    (List.range (contents.utf8ByteSize + 1)).filter fun offset =>
      (String.Pos.Raw.mk offset).IsValid contents do
    for bracket in [Bracket.round, .square, .curly] do
      for opening in [false, true] do
        for forward in [false, true] do
          for escaped in [false, true] do
            for skipQuoted in [false, true] do
              let question :=
                s!"{repr contents} {bracket.opening} opening {opening} forward {forward} escaped {escaped} skipQuoted {skipQuoted} from {offset}"
              answers :=
                answers.push (question, ← answer bracket opening forward escaped skipQuoted offset)
  return answers

/-- What only a run against both shows: that the real binding's bracket walk
and the model's agree at every position of texts with quotes. The contract's
tables pin the quote rule at the cases they name, and its every-position
property only what any answer must be, so two ports of the rule could
disagree at an offset no table names; this check compares them there. A
disagreement fails the check with the first question the two answer
differently. -/
def pairChecks : List Check :=
  [{  name :=
        "at every position of texts with quotes, for each kind, side, direction, escapedness and whether quoted brackets are passed over, the real bracket walk answers what the text model does"
      run := do
        for contents in TextContract.bracketText :: TextContract.quotedBracketTexts do
          let model ←
            unmatchedEverywhere contents fun bracket opening forward escaped skipQuoted offset =>
                match
                  TextModel.unmatched? contents bracket opening forward escaped skipQuoted
                    offset with
                | .ok found => pure found
                | .error error => throw (IO.userError s!"the model refused: {repr error}")
          let (real, _) ←
            (do
                    let text ← createText contents
                    let mut found := #[]
                    for offset in [0:contents.utf8ByteSize + 1] do
                      if (String.Pos.Raw.mk offset).IsValid contents then
                        for bracket in [Bracket.round, .square, .curly] do
                          for opening in [false, true] do
                            for forward in [false, true] do
                              for escaped in [false, true] do
                                for skipQuoted in [false, true] do
                                  found :=
                                    found.push
                                      (←
                                        text.unmatched bracket opening forward escaped skipQuoted
                                            offset)
                    return found : TextM (Array (Option Nat))).runReal
                (← RealTexts.new)
          let real ←
            match real with
            | .ok found =>
              pure found
            | .error error =>
              throw (IO.userError s!"the binding refused: {repr error}")
          if real.size != model.size then
            return false
          for ((question, expected), got) in model.toList.zip real.toList do
            if expected != got then
              throw
                  (IO.userError
                    s!"{question}: the model answers {repr expected}, the binding {repr got}")
        return true }]

/-- Plays `case` on the real text binding and the library's file service, on
real files, and says what went wrong; `none` when the case held.

It is played as the runtime plays it. The first command runs against a store
whose table of snapshots is published. The job is run by the runner, over
the file service that reads that table, and finishes with its command, as a
job does (`Work.of`). That command is run by `Job.finishWith`, which hands
the run what the job held and then settles the job, as the loop does. The
last command runs like any other, handed nothing. The files are in a
temporary directory made here for this one case, which is removed whatever
happened. -/
def playOnLibrary (completions : Job.Completions) (case : FileCases.Case) : IO (Option String) := do
  let rig ← FileRig.new completions
  let directory ← IO.FS.createTempDir
  try
    for (name, bytes) in case.files do
      IO.FS.writeBinFile (directory / name) bytes
    let display := (← recorderOf rig.published).handle
    let (.ok start, texts) ←
      case.first.runReal (.over rig.published) display | return some "its first command was refused"
    let handle ←
      Job.spawn rig.services (Work.of (fun _ => case.job directory start) (case.handler start))
          (pure ())
    unless ← eventually handle.ended do
      handle.cancel
      return some "its job did not end"
    match ← handle.outcome? with
    | some (.finished command) =>
      let (ran, texts) ← Job.finishWith rig.held handle command texts display
      if let .error refusal := ran then
        return some s!"the job's command failed with {repr refusal}"
      let (verdict, _) ← (case.last start).runReal texts display
      let after := JobContract.byName (← filesOf directory)
      match verdict with
      | .error refusal =>
        return some s!"its last command failed with {repr refusal}"
      | .ok false =>
        return some "its last command says it did not hold"
      | .ok true =>
        if after == JobContract.byName case.after then
          return none
        return some s!"the files afterwards are {after.map (·.1)}, of {after.map (·.2.size)} bytes"
    | some (.failed message) =>
      return some s!"its job failed with `{message}`"
    | _ =>
      return some "its job was cancelled"
  finally
    IO.FS.removeDirAll directory

/-- What must hold of the library's objects once the cases have run. -/
def caseLeakName : String :=
  "the cases across the two ports leave nothing behind: each store is dropped with its case, what its job held was released, and the library holds the documents and the snapshots it held before, with no request left in the file service"

/-- The names of the cases across the text port and the job port that do not
hold of the real binding and the library's file service, each with what
went wrong. `caseLeakName` is among them if the library's counts are not
then what they were. -/
def caseFailures (completions : Job.Completions) : IO (List String) := do
  let before := (← Ffi.Document.live, ← Ffi.Snapshot.live, ← Ffi.filesPending)
  let failed ←
    FileCases.cases.filterMapM fun case => do
        return (← playOnLibrary completions case).map fun reason =>
            s!"the real text binding and the file service: {case.name} ({reason})"
  let freed ←
    eventually do
        return (← Ffi.Document.live, ← Ffi.Snapshot.live, ← Ffi.filesPending) == before
  return failed ++ if freed then [] else [caseLeakName]

/-- The cell sizes the display contract is run at, against the real binding
and against the recorder: one pixel by one, and eight by sixteen, as
`model-test` runs it against the model. -/
def displayCells : List Display.Cells :=
  [{ advance := 1, lineHeight := 1 }, { advance := 8, lineHeight := 16 }]

/-- Runs `property` against the real display binding over a display of
`cells`: each of its texts is a document and a snapshot of the library,
entered in a new table of snapshots, which the display reads. The binding
has a theme of no definition to send, so every face is layout's base and a
cell is the size the contract was given. -/
def runOnRealDisplay (cells : Display.Cells) (property : DisplayContract.Property) :
    IO (Except DisplayError Bool) := do
  let table ← Snapshots.new
  let ids ←
    property.texts.mapM fun text => do
        let document ← Ffi.Document.new text
        table.add (← document.snapshot)
  let display ← Ffi.Display.newCells cells.advance.toUInt64 cells.lineHeight.toUInt64
  (property.holds ids).runReal (← RealDisplay.over display table.reader #[])

/-- The names of the display contract's properties that do not hold of the
real binding, at each of `displayCells`. -/
def displayFailures : IO (List String) :=
  displayCells.flatMapM fun cells => do
    let failed ←
      DisplayContract.failures (runOnRealDisplay cells) (DisplayContract.properties cells)
    return failed.map
        (s!"the real display binding in cells of {cells.advance} by {cells.lineHeight}: {·}")

/-- A recorder in `cells` over a table of its own, which holds a snapshot of
a document of each of `texts`: the recorder, the table, and the ids of the
snapshots, in the order of `texts`. -/
def recorderOver (cells : Display.Cells) (texts : Array String) :
    IO (DisplayRecorder × Snapshots × Array SnapshotId) := do
  let table ← Snapshots.new
  let snapshots ←
    texts.mapM fun text => do
        table.add (← (← Ffi.Document.new text).snapshot)
  return (← DisplayRecorder.new cells table.reader, table, snapshots)

/-- Runs a property of the display interface's contract against a recorder
in `cells` over real snapshots of the property's texts. -/
def runOnRecorder (cells : Display.Cells) (property : DisplayContract.Property) :
    IO (Except DisplayError Bool) := do
  let (recorder, _, snapshots) ← recorderOver cells property.texts
  (property.holds snapshots).runWith recorder.handle

/-- The names of the display interface's contract properties that do not
hold of the recorder over real snapshots, at each of `displayCells`. -/
def recorderFailures : IO (List String) :=
  displayCells.flatMapM fun cells => do
    let failed ← DisplayContract.failures (runOnRecorder cells) (DisplayContract.properties cells)
    return failed.map
        (s!"the display recorder in cells of {cells.advance} by {cells.lineHeight}: {·}")

/-- A scene with no views, for the recorder's checks. -/
def emptyScene : Scene :=
  { size := ⟨640, 480⟩, views := #[], focused := none, echo := "published", pending := ""
    preedit := some "ka" }

/-- What only the recorder shows: what it keeps of a publish, and that it
reads the table it was given as the table is when it is asked. -/
def recorderChecks : List Check :=
  [{  name :=
        "the recorder has no scene before a publish, and the scene published after one, counted"
      run := do
        let (recorder, _, _) ← recorderOver { advance := 1, lineHeight := 1 } #[]
        let before ← recorder.last?
        let published ← (Display.publish emptyScene).runWith recorder.handle
        return before.isNone && published matches .ok () && (← recorder.last?) == some emptyScene &&
            (← recorder.published) == 1 },
    { name :=
        "a query of a snapshot released from the table the recorder reads is refused with noSuchSnapshot"
      run := do
        let (recorder, table, snapshots) ← recorderOver { advance := 1, lineHeight := 1 } #["ab"]
        let snapshot := snapshots[0]?.getD ⟨0⟩
        let query : Display.RowsQuery := { snapshot, width := 4, height := 1, anchor := 0 }
        let before ← (Display.rowsShown query).runWith recorder.handle
        discard <| table.release snapshot
        let after ← (Display.rowsShown query).runWith recorder.handle
        return (match before with
            | .ok rows => rows == #[⟨0, 2⟩]
            | .error _ => false) &&
            match after with
            | .error .noSuchSnapshot => true
            | _ => false }]

/-- The names of the clipboard interface's contract properties that do not
hold of the clipboard a host with no window keeps: one clipboard for the
whole list, so each property finds what the one before it left. -/
def clipboardFailures : IO (List String) := do
  let clipboard ← Clipboard.InProcess.new
  let failed ←
    ClipboardContract.failures
        (fun property => Program.runM (port := clipboardPort) clipboard.handle property.holds)
        ClipboardContract.properties
  return failed.map (s!"the in-process clipboard: {·}")

/-- The names of the clipboard interface's contract properties that do not
hold of its real binding, over the library's memory clipboard: one
clipboard for the whole list. The desktop's clipboard is never reached. -/
def realClipboardFailures : IO (List String) := do
  let clipboard ← Clipboard.Real.memory
  let failed ←
    ClipboardContract.failures
        (fun property => Program.runM (port := clipboardPort) clipboard.handle property.holds)
        ClipboardContract.properties
  return failed.map (s!"the real clipboard binding over the library's memory clipboard: {·}")

/-- A command that reads the clipboard, writes `text` to it and reads it
again: the three replies. -/
def clipboardRound (text : String) :
    EditorM
      (Except ClipboardError (Option String) ×
        Except ClipboardError Unit × Except ClipboardError (Option String)) :=
  do
  let before ← Clipboard.read
  let written ← Clipboard.write text
  return (before, written, ← Clipboard.read)

/-- The reason the library's failing clipboard is made with in
`clipboardChecks`: not ASCII, so a reason cut or mis-decoded at the glue
shows. -/
def failingReason : String :=
  "pas de presse-papiers: é"

/-- What the contract cannot show of the clipboard a host with no window
keeps, and where a command's clipboard requests go when it is run against
the library. -/
def clipboardChecks : List Check :=
  [{  name := "a new in-process clipboard holds no text, and holds what was written to it last"
      run := do
        let clipboard ← Clipboard.InProcess.new
        let before ← clipboard.held?
        let first ← clipboard.handle (.write "first")
        let second ← clipboard.handle (.write "second")
        return before.isNone && first matches .ok () && second matches .ok () &&
            (← clipboard.held?) == some "second" },
    { name :=
        "a command run against the library with no clipboard handed in is answered unavailable for a read and for a write"
      run := do
        let table ← Snapshots.new
        let (result, _) ← (clipboardRound "x").runReal (.over table) (← recorderOf table).handle
        return match result with
          | .ok (.error .unavailable, .error .unavailable, .error .unavailable) => true
          | _ => false },
    { name :=
        "a command run against the library with the in-process clipboard handed in reads what it wrote, and a later command reads it too"
      run := do
        let table ← Snapshots.new
        let display := (← recorderOf table).handle
        let clipboard ← Clipboard.InProcess.new
        let (first, texts) ←
          (clipboardRound "kept").runReal (.over table) display (clipboard := clipboard.handle)
        let (second, _) ←
          EditorM.runReal (Clipboard.lift Clipboard.read) texts display (clipboard :=
              clipboard.handle)
        return (match first with
            | .ok (.ok none, .ok (), .ok (some "kept")) => true
            | _ => false) &&
            match second with
            | .ok (.ok (some "kept")) => true
            | _ => false },
    { name :=
        "a read and a write of the library's failing clipboard each cross the glue as a failure with the library's reason whole"
      run := do
        let clipboard ← Ffi.Clipboard.failing failingReason
        let read ← clipboard.read
        let written ← clipboard.write "lost"
        return (match read with
            | .error reason => reason == failingReason
            | .ok _ => false) &&
            written == some failingReason },
    { name :=
        "the real clipboard binding over the library's failing clipboard answers a read and a write unavailable"
      run := do
        let real ← Clipboard.Real.failing failingReason
        let read ← real.handle .read
        let written ← real.handle (.write "lost")
        return read matches .error .unavailable && written matches .error .unavailable }]

/-- The names of the fuzzy matching interface's contract properties that do
not hold of its real binding. The binding keeps nothing, so each property
is run against the same handler. -/
def fuzzyFailures : IO (List String) := do
  let failed ←
    FuzzyContract.failures
        (fun property => Program.runM (port := fuzzyPort) Fuzzy.real property.holds)
        FuzzyContract.properties
  return failed.map (s!"the real fuzzy binding: {·}")

/-- The names of the completion styles' contract properties that do not hold
of the fuzzy style over the real fuzzy binding: the one contract check of
the style interface's real implementation, beside `model-test`'s on the
fuzzy model. -/
def styleFailures : IO (List String) := do
  let failed ←
    Completion.StyleContract.failures (Program.runM (port := fuzzyPort) Fuzzy.real)
      Completion.Styles.fuzzy
  return failed.map (s!"the fuzzy style over the real fuzzy binding: {·}")

/-- Where a command's fuzzy requests go when it is run against the
library: to the real binding, with nothing handed in. The case is the one
the contract fixes whatever the library's scores: of `wq`, `edit` and `w`
the pattern `w` matches the first and the third, and the third is the
pattern. -/
def fuzzyChecks : List Check :=
  [{  name :=
        "a command run against the library that asks for a fuzzy ranking is answered by the library's matcher: the candidate that is the pattern first, then the other that matches"
      run := do
        let table ← Snapshots.new
        let command : EditorM (Array Nat) := Fuzzy.rank "w" #["wq", "edit", "w"]
        let (result, _) ← command.runReal (.over table) (← recorderOf table).handle
        return match result with
          | .ok ranked => ranked == #[2, 0]
          | .error _ => false }]

/-- Documents of `texts` in the library, a table of a snapshot of each, the
ids of those snapshots in the order of `texts`, and a real syntax tree
binding over the table whose handler waits, with a bound, for a snapshot's
tree to be delivered before it forwards a question of its captures or of a
kept query's, and after an attach (`settlingAttach`). The
documents are returned so that the caller keeps them alive: a document
freed detaches its text. -/
def syntaxTreeOver (texts : Array String) :
    IO (Array Ffi.Document × Snapshots × Array SnapshotId × SyntaxTreeHandler) := do
  let table ← Snapshots.new
  let documents ← texts.mapM Ffi.Document.new
  let ids ←
    documents.mapM fun document => do
        table.add (← document.snapshot)
  let real ← RealSyntaxTree.new table.reader
  return (documents, table, ids, settling table real.handle)

/-- Runs `property` of the syntax tree interface's contract against the real
binding, over documents of its texts. -/
def runOnRealSyntaxTree (property : SyntaxTreeContract.Property) : IO Bool := do
  let (documents, _, ids, handler) ← syntaxTreeOver property.texts
  let result ← (property.holds ids).runWith handler
  -- The documents are read here, so they are alive for the whole run.
  for document in documents do
    discard document.read
  return result matches .ok true

/-- The names of the syntax tree interface's contract properties that do not
hold of its real binding. -/
def syntaxTreeFailures : IO (List String) := do
  let failed ← SyntaxTreeContract.failures runOnRealSyntaxTree SyntaxTreeContract.properties
  return failed.map (s!"the real syntax tree binding: {·}")

/-- Runs `check` against the real syntax tree binding over documents of
`texts`, handed the documents, which it may edit, the table of snapshots the
binding reads, which it may add to, the snapshots' ids and the binding's
handler; whether it answered `true`. -/
def onRealSyntaxTree (texts : Array String)
    (check : Array Ffi.Document → Snapshots → Array SnapshotId → SyntaxTreeHandler → IO Bool) :
    IO Bool := do
  let (documents, table, ids, handler) ← syntaxTreeOver texts
  let held ← check documents table ids handler
  for document in documents do
    discard document.read
  return held

/-- The captures `query` answers of the whole of `text`, as the texts of
their nodes. -/
def capturedTexts (text : String) (captures : Array SyntaxTree.Capture) : Array String :=
  captures.map fun capture => String.fromUTF8! (text.toUTF8.extract capture.start capture.stop)

/-- The capture names of the query of `kind` the library ships for
`grammar`; none when it ships none or the query does not compile. -/
def shippedNames (grammar : String) (kind : QueryKind) : IO (Option (Array String)) := do
  let table ← Snapshots.new
  let real ← RealSyntaxTree.new table.reader
  let program : SyntaxTreeM (Array String) := do
    let query ← SyntaxTree.compile grammar (← SyntaxTree.shippedQuery grammar kind)
    SyntaxTree.captureNames query
  return (← program.runWith real.handle).toOption

/-- What the indent primitive answers of each row of `text`, whose major
mode is the shipped Rust one, over the real syntax tree binding: the text,
the levels, and the texts the run left. Each question waits for its
snapshot's tree (`settling`). -/
def rustIndentLevels (table : Snapshots) (texts : RealTexts) (text : TextId) :
    IO (Option (Array (Option Nat))) := do
  let real ← RealSyntaxTree.new table.reader
  let levels : EditorM (Except SyntaxTreeError (Array (Option Nat))) := do
    text.indentLevels 0 ((← text.rowCount) - 1)
  let (.ok (.ok answered), _) ←
    levels.runReal texts (← recorderOf table).handle (syntaxTree :=
        settling table real.handle) | return none
  return some answered

/-- The opening level of a Rust text, written with a bar where the line
opens (`fixture`), whose major mode is the shipped Rust one, over the real
syntax tree binding, with what follows the bar on its row moved to the new
row when `rest`: `none` when the run was refused. The question waits for
its snapshot's tree (`settling`). -/
def rustOpeningLevel (fixture : String) (rest : Bool) :
    IO (Option (Except SyntaxTreeError (Option Nat))) := do
  let offset := ((fixture.splitOn "|").headD "").utf8ByteSize
  let source := fixture.replace "|" ""
  let table ← Snapshots.new
  let real ← RealSyntaxTree.new table.reader
  let asked : EditorM (Except SyntaxTreeError (Option Nat)) := do
    let text ← createText source
    Highlight.enter "rust" text { grammar := "rust" }
    text.openingLevel offset rest
  let (.ok answered, _) ←
    asked.runReal (.over table) (← recorderOf table).handle (syntaxTree :=
        settling table real.handle) | return none
  return some answered

/-- The rows of the opening rule's table over the real Rust grammar: a text
with a bar where a line opens, whether what follows the bar moves to the
new row (`RET`) or the new row is empty (`o`, `O`), and the level. -/
def rustOpeningRows : List (String × Bool × Option Nat) :=
  [("fn main() {|\n    let x = 1;\n}\n", true, some 1), ("fn main() {|}\n", true, some 0),
    ("fn main() {|", true, some 1), ("struct S {|", true, some 1),
    ("impl A {\n    fn f(&self) {|", true, some 2),
    ("fn main() {\n    if a {\n        if b {|", true, some 3),
    ("fn main() {\n    match x {|\n}\n", true, some 2),
    ("fn main() {\n    if a {|\n    let y = 2;\n}\n", true, some 2),
    ("fn main() {\n    foo(|\n}\n", true, some 2),
    ("fn main() {\n    let v = vec![|\n}\n", true, some 2),
    ("fn main() {\n    let x = ;\n    if a {|\n    }\n}\n", true, some 2),
    ("fn main() {\n    let x = 1;\n}|\n", false, some 0),
    ("fn main() {\n    let x = 1;\n|}\n", false, some 1),
    ("fn main() {\n    let x = 1;\n|}\n", true, some 0),
    ("fn main() {\n|    let x = 1;\n}\n", false, some 1),
    ("impl A {\n    fn f() {\n        x();|\n    }\n}\n", false, some 2),
    ("fn main() {\n    let s = \"ab|c\";\n}\n", true, none)]

/-- The levels the indent rule must give `source`, a rustfmt-formatted Rust
text indented four spaces a level, for each of its rows: `none` for the
rows in `kept`, kept as they are, `some` of the leading spaces divided by
four for every other row with content, and nothing asked of a blank row. -/
def rustIndentHolds (source : String) (kept : List String) (levels : Array (Option Nat)) : Bool :=
  let lines := (source.splitOn "\n").toArray
  lines.size == levels.size &&
    (lines.zip levels).all fun (line, level) =>
      if kept.contains line then level == none
      else
        if line.trimAscii.isEmpty then true
        else level == some ((line.toList.takeWhile (· == ' ')).length / 4)

/-- Rust texts with a bracket the tree did not close, each indented as its
levels must be: a call's `(` and an array's `[` whose partner is missing,
mid-function, followed by another function, whose rows after the bracket's
node keep their levels; and brackets left open at the text's end, which
the error that holds them counts on every row it reaches. -/
def rustUnclosedTexts : List String :=
  ["fn a() {\n    foo(1;\n}\n\nfn b() {\n    x\n}\n",
    "fn a() {\n    let v = [1, 2;\n}\n\nfn b() {\n    x\n}\n", "fn main() {\n    let x = 1;\n",
    "impl A {\n    fn f(&self) {\n        x();\n"]

/-- The indent levels of `source`, whose major mode is the shipped Rust one,
over the real syntax tree binding: `none` when the run was refused. The
question waits for its snapshot's tree (`settling`). -/
def rustSourceLevels (source : String) : IO (Option (Array (Option Nat))) := do
  let table ← Snapshots.new
  let real ← RealSyntaxTree.new table.reader
  let entered : EditorM TextId := do
    let text ← createText source
    Highlight.enter "rust" text { grammar := "rust" }
    return text
  let (.ok text, texts) ←
    entered.runReal (.over table) (← recorderOf table).handle (syntaxTree :=
        settling table real.handle) | return none
  rustIndentLevels table texts text

/-- A row of the tree's text objects over the Rust fixture: where the
cursor is, as the text it is at the start of (its first occurrence), the
object, the count, where the anchor of a visual selection is, as a text
whose first occurrence it is at the start of, or the end of when `atEnd`,
and the text the object covers and how, or none for no object. -/
structure ObjectRow where
  /-- The text the cursor is at the start of. -/
  needle : String
  /-- The object. -/
  object : Vocabulary.TextObject
  /-- The count, if one was typed. -/
  count : Option Nat := none
  /-- The text the anchor is at, in a visual state. -/
  anchor : Option (String × Bool) := none
  /-- What it covers: its text and its reach; none for no object. -/
  covers : Option (String × Vocabulary.Reach)

/-- The rows of the tree's text objects over `tests/syntax/rust/objects.rs`,
written by hand: all six objects; a count of 2, the method round a
closure; a visual selection of the closure widened to the method; the
inside of a unit struct, which is none; an argument first, last, alone and
on lines of its own; the inside of a closure whose body is an expression;
and the inside of a function, a struct, an impl and a closure from a cursor
in the node but outside the inside, on its `fn`, `struct`, `impl` or
parameters. -/
def objectRows : List ObjectRow :=
  [{  needle := "a + b", object := Evil.aFunction
      covers := some ("fn free(a: u8, b: u8) -> u8 {\n    a + b\n}", .exclusive) },
    { needle := "a + b", object := Evil.innerFunction, covers := some ("    a + b\n", .exclusive) },
    { needle := "v + extra", object := Evil.aFunction,
      covers := some ("|v| v + extra", .exclusive) },
    { needle := "v + extra", object := Evil.innerFunction,
      covers := some ("v + extra", .exclusive) },
    { needle := "v + extra", object := Evil.aFunction, count := some 2
      covers :=
        some
          ("fn sum(&self, extra: u8) -> u8 {\n        let add = |v| v + extra;\n        add(self.x) + call(\n            self.y,\n            extra,\n        )\n    }",
            .exclusive) },
    { needle := "|v|", object := Evil.aFunction, anchor := some ("v + extra", true)
      covers :=
        some
          ("fn sum(&self, extra: u8) -> u8 {\n        let add = |v| v + extra;\n        add(self.x) + call(\n            self.y,\n            extra,\n        )\n    }",
            .exclusive) },
    { needle := "x: u8", object := Evil.aClass
      covers := some ("struct Fields {\n    x: u8,\n    y: u8,\n}", .exclusive) },
    { needle := "x: u8", object := Evil.innerClass
      covers := some ("    x: u8,\n    y: u8,\n", .exclusive) },
    { needle := "Unit", object := Evil.aClass, covers := some ("struct Unit;", .exclusive) },
    { needle := "Unit", object := Evil.innerClass, covers := none },
    { needle := "Circle", object := Evil.aClass
      covers := some ("enum Shape {\n    Circle(f64),\n    Square(f64),\n}", .exclusive) },
    { needle := "area(&self) -> f64;", object := Evil.aFunction
      covers := some ("fn area(&self) -> f64;", .exclusive) },
    { needle := "area(&self) -> f64;", object := Evil.innerFunction, covers := none },
    { needle := "area(&self) -> f64;", object := Evil.aClass
      covers := some ("trait Area {\n    fn area(&self) -> f64;\n}", .exclusive) },
    { needle := "a: u8", object := Evil.anArgument, covers := some ("a: u8, ", .exclusive) },
    { needle := "b: u8", object := Evil.anArgument, covers := some (", b: u8", .exclusive) },
    { needle := "b: u8", object := Evil.innerArgument, covers := some ("b: u8", .exclusive) },
    { needle := "self.x", object := Evil.anArgument, covers := some ("self.x", .exclusive) },
    { needle := "self.y", object := Evil.anArgument
      covers := some ("self.y,\n            ", .exclusive) },
    { needle := "one: u8", object := Evil.anArgument, covers := some ("one: u8, ", .exclusive) },
    { needle := "fn free", object := Evil.anArgument, covers := none },
    { needle := "fn free", object := Evil.innerFunction,
      covers := some ("    a + b\n", .exclusive) },
    { needle := "struct Fields", object := Evil.innerClass
      covers := some ("    x: u8,\n    y: u8,\n", .exclusive) },
    { needle := "impl Fields", object := Evil.innerClass
      covers :=
        some
          ("    fn sum(&self, extra: u8) -> u8 {\n        let add = |v| v + extra;\n        add(self.x) + call(\n            self.y,\n            extra,\n        )\n    }\n",
            .exclusive) },
    { needle := "|v|", object := Evil.innerFunction, covers := some ("v + extra", .exclusive) }]

/-- The byte offset of the first occurrence of `needle` in `text`, or of
its end when `atEnd`; none when `text` does not hold it. -/
def offsetOfNeedle (text needle : String) (atEnd : Bool := false) : Option Nat :=
  match text.splitOn needle with
  | before :: _ :: _ => some (before.utf8ByteSize + if atEnd then needle.utf8ByteSize - 1 else 0)
  | _ => none

/-- What is wrong with each of `rows` over `text`, a text of the Rust
fixture whose mode is the shipped Rust one, each row's covered text edited
by `edited`, through the real syntax tree binding over `table`. -/
def objectRowsWrong (table : Snapshots) (texts : RealTexts) (text : TextId) (source : String)
    (edited : String → String) (rows : List ObjectRow) : IO (List String) := do
  let real ← RealSyntaxTree.new table.reader
  rows.filterMapM fun row => do
      let some head := offsetOfNeedle source row.needle | return some s!"no {row.needle}"
      let anchor := row.anchor.bind fun (needle, atEnd) => offsetOfNeedle source needle atEnd
      let asked : EditorM (Option (String × Vocabulary.Reach)) := do
        let some span ← row.object.span text { head, count := row.count, anchor } | return none
        let stop ←
          if span.reach == .inclusive then
            text.motion .nextCell span.stop
          else
            pure span.stop
        return some (← text.slice span.start stop, span.reach)
      let (answer, _) ←
        asked.runReal texts (← recorderOf table).handle (syntaxTree := settling table real.handle)
      let expected := row.covers.map fun (covered, reach) => (edited covered, reach)
      return match answer with
        | .ok covers =>
          if covers == expected then none
          else some s!"{row.object.name} at {repr row.needle}: {repr covers}"
        | .error refusal => some s!"{row.object.name} at {repr row.needle}: {repr refusal}"

/-- What only the real syntax tree binding shows over the fixtures in
`fixtures` (`tests/syntax`): the indent levels of a Rust fixture, before
and after an edit, the tree's text objects of another, before and after
edits, and the names the shipped Rust indents and text objects queries
capture. -/
def syntaxFixtureChecks (fixtures : System.FilePath) : List Check :=
  [{  name := "the shipped Rust text objects query names only what the text-object rule reads"
      run := do
        let some names ← shippedNames "rust" .textObjects | return false
        return !names.isEmpty && names.all Evil.TreeObjects.names.contains },
    { name :=
        "the tree's text objects of the Rust fixture, through the Lean editor API, cover the ranges written by hand, and still do after a function is inserted above and a line added inside a method's body"
      run := do
        let source ← IO.FS.readFile (fixtures / "rust" / "objects.rs")
        let table ← Snapshots.new
        let real ← RealSyntaxTree.new table.reader
        let entered : EditorM TextId := do
          let text ← createText source
          Highlight.enter "rust" text { grammar := "rust" }
          return text
        let (.ok text, texts) ←
          entered.runReal (.over table) (← recorderOf table).handle (syntaxTree :=
              settling table real.handle) | return false
        let before ← objectRowsWrong table texts text source id objectRows
        let line := "        let add = |v| v + extra;\n"
        let added := line ++ "        let unused = 1;\n"
        let inserted := "fn inserted() {}\n\n"
        let some at_ := offsetOfNeedle source line | return false
        let edit : EditorM Unit := do
          text.insert (at_ + line.utf8ByteSize) "        let unused = 1;\n"
          text.insert 0 inserted
        let (.ok (), texts) ← edit.runReal texts (← recorderOf table).handle | return false
        let edited := inserted ++ source.replace line added
        let after ← objectRowsWrong table texts text edited (·.replace line added) objectRows
        let read : EditorM String := text.read
        let (.ok now, _) ← read.runReal texts (← recorderOf table).handle | return false
        unless before.isEmpty && after.isEmpty do
          throw (IO.userError ("; ".intercalate (before ++ after)))
        return now == edited },
    { name := "the shipped Rust indents query names only what the indent rule reads"
      run := do
        let some names ← shippedNames "rust" .indents | return false
        return !names.isEmpty && names.all Indent.names.contains },
    { name :=
        "the indent levels of the Rust fixture are its own indentation, and the rows inside its multi-line string and block comment keep theirs, before and after an edit that wraps a statement in a new block"
      run := do
        let source ← IO.FS.readFile (fixtures / "rust" / "indent.rs")
        let kept := ["not indented by the rule\";", "       comment */"]
        let table ← Snapshots.new
        let real ← RealSyntaxTree.new table.reader
        let entered : EditorM TextId := do
          let text ← createText source
          Highlight.enter "rust" text { grammar := "rust" }
          return text
        let (.ok text, texts) ←
          entered.runReal (.over table) (← recorderOf table).handle (syntaxTree :=
              settling table real.handle) | return false
        let some before ← rustIndentLevels table texts text | return false
        -- A statement wrapped in a new `if` block, formatted.
        let statement := "                let y = x + 1;\n"
        let wrapped :=
          "                if y > 0 {\n                    let y = x + 1;\n                }\n"
        let some offset := (source.splitOn statement).head?.map (·.utf8ByteSize) | return false
        let edit : EditorM Unit := do
          text.delete offset (offset + statement.utf8ByteSize)
          text.insert offset wrapped
        let (.ok (), texts) ← edit.runReal texts (← recorderOf table).handle | return false
        let edited := source.replace statement wrapped
        let some after ← rustIndentLevels table texts text | return false
        -- The documents are read, so they live to here.
        let read : EditorM String := text.read
        let (.ok now, _) ← read.runReal texts (← recorderOf table).handle | return false
        return now == edited && rustIndentHolds source kept before &&
            rustIndentHolds edited kept after },
    { name :=
        "the opening level of Rust texts at an unclosed bracket counts every bracket the tree did not close, widened to the incomplete node that holds them: closed and unclosed at the text's end, three deep, a match, an if, a call and a vec! opened mid-function, a balanced error elsewhere, o and O on a closing row and in a body, and nothing inside a string"
      run := do
        let mut wrong := #[]
        for (fixture, rest, level) in rustOpeningRows do
          let answered ← rustOpeningLevel fixture rest
          let said :=
            match answered with
            | some (.ok got) => if got == level then none else some (repr got)
            | some (.error refusal) => some (repr refusal)
            | none => some "nothing"
          if let some said := said then
            wrong := wrong.push s!"{repr fixture} (rest {rest}) answered {said}"
        unless wrong.isEmpty do
          throw (IO.userError ("; ".intercalate wrong.toList))
        return true },
    { name :=
        "the indent levels of Rust texts with a bracket the tree did not close are their own indentation: a call's ( and an array's [ whose partner is missing mid-function count on no row after their node, so the function's } and the next function keep their levels, and brackets open at the text's end count on the rows their error holds"
      run := do
        let mut wrong := #[]
        for source in rustUnclosedTexts do
          match ← rustSourceLevels source with
          | some levels =>
            unless rustIndentHolds source [] levels do
              wrong := wrong.push s!"{repr source} answered {repr levels}"
          | none =>
            wrong := wrong.push s!"{repr source} was refused"
        unless wrong.isEmpty do
          throw (IO.userError ("; ".intercalate wrong.toList))
        return true }]

/-- What only the real syntax tree binding shows: the library's Rust
grammar, a query of one grammar asked of a text parsed with another, and a
text edited through its document reparsed. -/
def syntaxTreeChecks : List Check :=
  [{  name := "the library's syntax service has a Rust grammar beside JSON"
      run := do
        let grammars ←
          SyntaxTree.grammars.runWith fun request => do
              let (_, _, _, handler) ← syntaxTreeOver #[]
              handler request
        return grammars.toOption.any fun names => names.contains "rust" && names.contains "json" },
    { name := "a Rust function's name is captured through the binding, by its field"
      run :=
        onRealSyntaxTree #["fn one() {}\nstruct S;\nfn two(x: u8) {}\n"] fun _ _ ids handler => do
          let program : SyntaxTreeM (Array SyntaxTree.Capture) := do
            SyntaxTree.attach (SyntaxTreeContract.nth ids 0) "rust"
            let query ← SyntaxTree.compile "rust" "(function_item name: (identifier) @name)"
            SyntaxTree.captures (SyntaxTreeContract.nth ids 0) query 0 39
          let text := "fn one() {}\nstruct S;\nfn two(x: u8) {}\n"
          return match ← program.runWith handler with
            | .ok captures => capturedTexts text captures == #["one", "two"]
            | .error _ => false },
    { name := "a query of JSON asked of a text parsed as Rust is refused as of the wrong grammar"
      run :=
        onRealSyntaxTree #["fn one() {}"] fun _ _ ids handler => do
          let program : SyntaxTreeM Bool := do
            SyntaxTree.attach (SyntaxTreeContract.nth ids 0) "rust"
            let query ← SyntaxTree.compile "json" "(number) @n"
            SyntaxTreeContract.refusedWith .wrongGrammar
                (SyntaxTree.captures (SyntaxTreeContract.nth ids 0) query 0 3)
          return (← program.runWith handler) matches .ok true },
    { name :=
        "a text edited through its document is reparsed: its new function's name is captured once the tree of the edit is delivered"
      run :=
        onRealSyntaxTree #["fn one() {}\n"] fun documents table ids handler => do
          let some document := documents[0]? | return false
          let attached ← (SyntaxTree.attach (SyntaxTreeContract.nth ids 0) "rust").runWith handler
          unless ← document.replace 0 0 "fn zero() {}\n" do
            return false
          -- The snapshot of the edited text enters the table, as the
          -- editor's would after the edit.
          let edited ← table.add (← document.snapshot)
          let program : SyntaxTreeM (Array SyntaxTree.Capture) := do
            let query ← SyntaxTree.compile "rust" "(function_item name: (identifier) @name)"
            SyntaxTree.captures edited query 0 25
          let text := "fn zero() {}\nfn one() {}\n"
          return attached matches .ok () &&
              match ← program.runWith handler with
              | .ok captures => capturedTexts text captures == #["zero", "one"]
              | .error _ => false },
    { name :=
        "an injection and a keep with a query of another grammar than the text's, and a language whose injections query is of another grammar than its highlights query, are refused as of the wrong grammar"
      run :=
        onRealSyntaxTree #["fn one() {}"] fun _ _ ids handler => do
          let snapshot := SyntaxTreeContract.nth ids 0
          let program : SyntaxTreeM Bool := do
            SyntaxTree.attach snapshot "rust"
            let json ← SyntaxTree.compile "json" "(number) @n"
            let rust ← SyntaxTree.compile "rust" "(identifier) @id"
            return (←
                  SyntaxTreeContract.refusedWith .wrongGrammar (SyntaxTree.inject snapshot json)) &&
                (←
                  SyntaxTreeContract.refusedWith .wrongGrammar
                      (SyntaxTree.keep snapshot .indents json)) &&
                (←
                  SyntaxTreeContract.refusedWith .wrongGrammar
                      (SyntaxTree.injectLanguage snapshot "rust" rust #[none] (some json)))
          return (← program.runWith handler) matches .ok true },
    { name :=
        "a highlight with a query of another grammar than its text's is refused as of the wrong grammar"
      run :=
        onRealSyntaxTree #["fn one() {}"] fun _ _ ids handler => do
          let program : SyntaxTreeM Bool := do
            SyntaxTree.attach (SyntaxTreeContract.nth ids 0) "rust"
            let query ← SyntaxTree.compile "json" "(number) @n"
            SyntaxTreeContract.refusedWith .wrongGrammar
                (SyntaxTree.highlight (SyntaxTreeContract.nth ids 0) query #[none])
          return (← program.runWith handler) matches .ok true },
    { name :=
        "a Rust text highlighted by the shipped default and edited is drawn by the real display with its keywords in the keyword face's colour, once the edit's tree is delivered and reported on the editor queue"
      run := do
        let table ← Snapshots.new
        let real ← RealSyntaxTree.new table.reader
        let syntaxTree := settlingAttach table real.handle
        let red := Color.rgb 0xcc 0 0
        let display ← Ffi.Display.newCells 8 16
        let shown ←
          RealDisplay.over display table.reader
              #[{ name := ⟨"syntax.keyword"⟩, face := { foreground := some red } }]
        let highlighted : EditorM TextId := do
          let text ← createText "fn one() {}\n"
          Highlight.enter "rust" text { grammar := "rust" }
          return text
        let (.ok text, texts) ←
          highlighted.runReal (.over table) shown.handle (syntaxTree := syntaxTree) | return false
        let edited : EditorM (SnapshotId × MarkerId) := do
          text.insert 0 "fn zero() {}\n"
          return (← text.snapshot, ← text.mark (.anchor { offset := 0, bias := .before }))
        let (.ok (snapshot, scroll), texts) ←
          edited.runReal texts shown.handle (syntaxTree := syntaxTree) | return false
        let some found ← table.find? snapshot | return false
        unless ← Ffi.syntaxSettle found 5000 do
          return false
        let reported ← pulledParsed
        let scene : Scene :=
          { size := { width := 160, height := 64 }
            views :=
              #[{ id := ⟨0⟩, rect := { x := 0, y := 0, width := 160, height := 64 }, snapshot
                  scroll, selections := #[], cursor := { shape := .block, face := ⟨"cursor"⟩ }
                  decorations := #[], status := #[] }]
            focused := none, echo := "", pending := "", preedit := none }
        let publish : EditorM Unit := Display.publish scene
        let (published, _) ← publish.runReal texts shown.handle
        let frame ← display.frameText
        -- Each row starts with `fn`: its first run, two bytes, in red.
        return reported && published.isOk && (frame.splitOn "runs 0..2:cc0000ff/").length == 3 },
    { name :=
        "a TOML text entered with the toml language's tree is drawn by the real display with its table header's key and its key in the type face's colour, its string in the string face's colour and the header's brackets in the punctuation face's colour"
      run := do
        let table ← Snapshots.new
        let real ← RealSyntaxTree.new table.reader
        let syntaxTree := settlingAttach table real.handle
        let red := Color.rgb 0xcc 0 0
        let green := Color.rgb 0 0xcc 0
        let blue := Color.rgb 0 0 0xcc
        let display ← Ffi.Display.newCells 8 16
        let shown ←
          RealDisplay.over display table.reader
              #[{ name := ⟨"syntax.type"⟩, face := { foreground := some red } },
                { name := ⟨"syntax.string"⟩, face := { foreground := some green } },
                { name := ⟨"syntax.punctuation"⟩, face := { foreground := some blue } }]
        let entered : EditorM (SnapshotId × MarkerId) := do
          let text ← createText "[package]\nname = \"x\"\n"
          Highlight.enter "toml" text Language.toml.syntaxTree
          return (← text.snapshot, ← text.mark (.anchor { offset := 0, bias := .before }))
        let (.ok (snapshot, scroll), texts) ←
          entered.runReal (.over table) shown.handle (syntaxTree := syntaxTree) | return false
        let some found ← table.find? snapshot | return false
        unless ← Ffi.syntaxSettle found 5000 do
          return false
        discard drainedParsed
        let scene : Scene :=
          { size := { width := 160, height := 64 }
            views :=
              #[{ id := ⟨0⟩, rect := { x := 0, y := 0, width := 160, height := 64 }, snapshot
                  scroll, selections := #[], cursor := { shape := .block, face := ⟨"cursor"⟩ }
                  decorations := #[], status := #[] }]
            focused := none, echo := "", pending := "", preedit := none }
        let publish : EditorM Unit := Display.publish scene
        let (published, _) ← publish.runReal texts shown.handle
        let frame ← display.frameText
        -- `[package]`: the brackets blue, the key red; `name = "x"`: the key
        -- red, ` = ` in no face of these, the string green.
        let header := "runs 0..1:0000ccff/ffffffff 1..8:cc0000ff/ffffffff 8..9:0000ccff/ffffffff\n"
        let pair := "runs 0..4:cc0000ff/ffffffff 4..7:000000ff/ffffffff 7..10:00cc00ff/ffffffff\n"
        return published.isOk && (frame.splitOn header).length == 2 &&
            (frame.splitOn pair).length == 2 },
    { name :=
        "a Lean text entered with the lean language's tree is drawn by the real display with its keyword in the keyword face's colour, its string in the string face's colour and its comment in the comment face's colour"
      run := do
        let table ← Snapshots.new
        let real ← RealSyntaxTree.new table.reader
        let syntaxTree := settlingAttach table real.handle
        let red := Color.rgb 0xcc 0 0
        let green := Color.rgb 0 0xcc 0
        let blue := Color.rgb 0 0 0xcc
        let display ← Ffi.Display.newCells 8 16
        let shown ←
          RealDisplay.over display table.reader
              #[{ name := ⟨"syntax.keyword"⟩, face := { foreground := some red } },
                { name := ⟨"syntax.string"⟩, face := { foreground := some green } },
                { name := ⟨"syntax.comment"⟩, face := { foreground := some blue } }]
        let entered : EditorM (SnapshotId × MarkerId) := do
          let text ← createText "def x := \"a\"\n-- c\n"
          Highlight.enter "lean" text Language.lean.syntaxTree
          return (← text.snapshot, ← text.mark (.anchor { offset := 0, bias := .before }))
        let (.ok (snapshot, scroll), texts) ←
          entered.runReal (.over table) shown.handle (syntaxTree := syntaxTree) | return false
        let some found ← table.find? snapshot | return false
        unless ← Ffi.syntaxSettle found 5000 do
          return false
        discard drainedParsed
        let scene : Scene :=
          { size := { width := 160, height := 64 }
            views :=
              #[{ id := ⟨0⟩, rect := { x := 0, y := 0, width := 160, height := 64 }, snapshot
                  scroll, selections := #[], cursor := { shape := .block, face := ⟨"cursor"⟩ }
                  decorations := #[], status := #[] }]
            focused := none, echo := "", pending := "", preedit := none }
        let publish : EditorM Unit := Display.publish scene
        let (published, _) ← publish.runReal texts shown.handle
        let frame ← display.frameText
        -- `def x := "a"`: `def` red, ` x := ` in no face of these, the
        -- string green; `-- c`: the comment blue.
        let definition :=
          "runs 0..3:cc0000ff/ffffffff 3..9:000000ff/ffffffff 9..12:00cc00ff/ffffffff\n"
        let comment := "runs 0..4:0000ccff/ffffffff\n"
        return published.isOk && (frame.splitOn definition).length == 2 &&
            (frame.splitOn comment).length == 2 },
    { name :=
        "a Lean text entered with the lean language's tree is drawn by the real display with a namespace's name in the module face's colour, not hidden by the identifier's variable capture"
      run := do
        let table ← Snapshots.new
        let real ← RealSyntaxTree.new table.reader
        let syntaxTree := settlingAttach table real.handle
        let red := Color.rgb 0xcc 0 0
        let yellow := Color.rgb 0xcc 0xcc 0
        let display ← Ffi.Display.newCells 8 16
        let shown ←
          RealDisplay.over display table.reader
              #[{ name := ⟨"syntax.keyword"⟩, face := { foreground := some red } },
                { name := ⟨"syntax.module"⟩, face := { foreground := some yellow } }]
        let entered : EditorM (SnapshotId × MarkerId) := do
          let text ← createText "namespace A.B\n"
          Highlight.enter "lean" text Language.lean.syntaxTree
          return (← text.snapshot, ← text.mark (.anchor { offset := 0, bias := .before }))
        let (.ok (snapshot, scroll), texts) ←
          entered.runReal (.over table) shown.handle (syntaxTree := syntaxTree) | return false
        let some found ← table.find? snapshot | return false
        unless ← Ffi.syntaxSettle found 5000 do
          return false
        discard drainedParsed
        let scene : Scene :=
          { size := { width := 160, height := 64 }
            views :=
              #[{ id := ⟨0⟩, rect := { x := 0, y := 0, width := 160, height := 64 }, snapshot
                  scroll, selections := #[], cursor := { shape := .block, face := ⟨"cursor"⟩ }
                  decorations := #[], status := #[] }]
            focused := none, echo := "", pending := "", preedit := none }
        let publish : EditorM Unit := Display.publish scene
        let (published, _) ← publish.runReal texts shown.handle
        let frame ← display.frameText
        -- `namespace A.B`: `namespace` red, the space in no face of these,
        -- the name `A.B` yellow.
        let line := "runs 0..9:cc0000ff/ffffffff 9..10:000000ff/ffffffff 10..13:cccc00ff/ffffffff\n"
        return published.isOk && (frame.splitOn line).length == 2 },
    { name :=
        "a Markdown text with a fenced Rust block, entered with the shipped default, is drawn by the real display with the fence's `fn` in the keyword face's colour"
      run := do
        let table ← Snapshots.new
        let real ← RealSyntaxTree.new table.reader
        let syntaxTree := settlingAttach table real.handle
        let red := Color.rgb 0xcc 0 0
        let display ← Ffi.Display.newCells 8 16
        let shown ←
          RealDisplay.over display table.reader
              #[{ name := ⟨"syntax.keyword"⟩, face := { foreground := some red } }]
        let entered : EditorM (SnapshotId × MarkerId) := do
          let text ← createText "# Title\n\n```rust\nfn one() {}\n```\n"
          Highlight.enter "markdown" text { grammar := "markdown" }
          return (← text.snapshot, ← text.mark (.anchor { offset := 0, bias := .before }))
        let (.ok (snapshot, scroll), texts) ←
          entered.runReal (.over table) shown.handle (syntaxTree := syntaxTree) | return false
        let some found ← table.find? snapshot | return false
        -- The settle waits for the layers the injections find, which the
        -- library delivers at the same revision.
        unless ← Ffi.syntaxSettle found 5000 do
          return false
        let reported ← drainedParsed
        let scene : Scene :=
          { size := { width := 160, height := 96 }
            views :=
              #[{ id := ⟨0⟩, rect := { x := 0, y := 0, width := 160, height := 96 }, snapshot
                  scroll, selections := #[], cursor := { shape := .block, face := ⟨"cursor"⟩ }
                  decorations := #[], status := #[] }]
            focused := none, echo := "", pending := "", preedit := none }
        let publish : EditorM Unit := Display.publish scene
        let (published, _) ← publish.runReal texts shown.handle
        let frame ← display.frameText
        -- One row starts with a keyword: the fence's `fn`, in red.
        return reported > 0 && published.isOk &&
            (frame.splitOn "runs 0..2:cc0000ff/").length == 2 },
    { name :=
        "a Markdown text with emphasis and inline code, entered with the inline grammar's captures mapped to faces, is drawn by the real display with the emphasis and the code span in their faces' colours"
      run := do
        let table ← Snapshots.new
        let real ← RealSyntaxTree.new table.reader
        let syntaxTree := settlingAttach table real.handle
        let green := Color.rgb 0 0xcc 0
        let blue := Color.rgb 0 0 0xcc
        let display ← Ffi.Display.newCells 8 16
        let shown ←
          RealDisplay.over display table.reader
              #[{ name := ⟨"test.emphasis"⟩, face := { foreground := some green } },
                { name := ⟨"test.literal"⟩, face := { foreground := some blue } }]
        -- The delimiters draw nothing, so each span is one run. The text has
        -- no fenced block: `text.literal` here can only be the inline
        -- layer's.
        let captures :=
          [("text.emphasis", some ⟨"test.emphasis"⟩), ("text.literal", some ⟨"test.literal"⟩),
            ("punctuation.delimiter", none)]
        let entered : EditorM (SnapshotId × MarkerId) := do
          let text ← createText "Some *emphasis* and `code`.\n"
          Highlight.enter "markdown" text { grammar := "markdown", captures }
          return (← text.snapshot, ← text.mark (.anchor { offset := 0, bias := .before }))
        let (.ok (snapshot, scroll), texts) ←
          entered.runReal (.over table) shown.handle (syntaxTree := syntaxTree) | return false
        let some found ← table.find? snapshot | return false
        unless ← Ffi.syntaxSettle found 5000 do
          return false
        discard drainedParsed
        let scene : Scene :=
          { size := { width := 320, height := 32 }
            views :=
              #[{ id := ⟨0⟩, rect := { x := 0, y := 0, width := 320, height := 32 }, snapshot
                  scroll, selections := #[], cursor := { shape := .block, face := ⟨"cursor"⟩ }
                  decorations := #[], status := #[] }]
            focused := none, echo := "", pending := "", preedit := none }
        let publish : EditorM Unit := Display.publish scene
        let (published, _) ← publish.runReal texts shown.handle
        let frame ← display.frameText
        -- `*emphasis*` is bytes 5 to 15 of its row, and `` `code` `` 20 to 26.
        return published.isOk && (frame.splitOn "5..15:00cc00ff").length == 2 &&
            (frame.splitOn "20..26:0000ccff").length == 2 }]

/-- Runs a property of the watch port's contract against the real binding
over `timers`. The library is told the interrupt key, and the property's
interrupt keys arrive through the library's window input, as a window's
would, before `holds` runs. Afterwards the events are taken off the editor
queue, the flag is lowered for whatever `holds` left up, and the library is
left with no interrupt key, so the next property starts with the flag down
and the queue empty. `false` when a key could not be posted. -/
def runOnWatch (timers : Job.Timers) (property : WatchContract.Property) : IO Bool := do
  unless ← Event.setInterruptKey (some Watch.interruptKey) do
    return false
  try
    let mut posted := 0
    for _ in [0:property.arrived] do
      if ← Event.post (.key Watch.interruptKey true "") then
        posted := posted + 1
    let held ← Program.runM (port := watchPort) (Watch.real timers) property.holds
    for _ in [0:posted] do
      discard <| Ffi.nextEvent .editor
      Ffi.interruptLower
    return held && posted == property.arrived && !(← Ffi.interruptRaised)
  finally
    discard <| Event.setInterruptKey none

/-- The names of the watch port's contract properties that do not hold of
the real binding over `timers`. -/
def watchFailures (timers : Job.Timers) : IO (List String) := do
  let failed ← WatchContract.failures (runOnWatch timers) WatchContract.properties
  return failed.map (s!"the real watch binding: {·}")

/-- What a command of the watch checks is: given its call, a program whose
value is what to write back. -/
abbrev Dispatched :=
  Call → EditorM (Option Config.Write)

/-- The keys the key string `text` names; none when it is refused. -/
def keys (text : String) : List Key :=
  (Key.parse text).toOption.getD []

/-- A scene with no views whose echo is `echo`: what the command `spin`
publishes, so that a display handler tells its publishes apart. -/
def spinScene (echo : String) : Scene :=
  { emptyScene with echo }

/-- The command `spin` of the watch checks: it replaces what the selection
covers with `spin`, and then, five times over, publishes a scene whose echo
says which round it is and makes a text named for the round. -/
def spin : Dispatched := fun call => do
  Loop.insert call.target "spin"
  for round in [1:6] do
    Display.publish (spinScene s!"spin {round}")
    discard <| createText s!"after {round}"
  return none

/-- The command `stamp` of the watch checks: it replaces what the selection
covers with the keys it was called with, as a key string. -/
def stamp : Dispatched := fun call => do
  Loop.insert call.target (Key.notations call.keys)
  return none

/-- What a step of the watch checks is handed: one keymap for every view,
which binds `C-c l` to `spin` and `C-c s` to `stamp`, and those two
commands. -/
def watchKeys : Loop.Keys TestScheme.scheme :=
  { maps := fun _ _ =>
      [Keymap.ofList
          [(keys "C-c l", ({ command := "spin" } : Invocation)),
            (keys "C-c s", { command := "stamp" })]]
    command? := fun name => ([("spin", spin), ("stamp", stamp)].find? (·.1 == name)).map (·.2) }

/-- What only the watch port's real binding shows. -/
def watchChecks (timers : Job.Timers) : List Check :=
  [{  name :=
        "the watch binding's clock is the job port's: over a fake clock it reads that clock's reading, and each reading is a read of that clock"
      run := do
        let clock ← Job.FakeClock.new (← Job.Completions.new)
        let handler := Watch.real clock.timers
        let first ← Program.runM (port := watchPort) handler Watch.now
        clock.advance 60
        let second ← Program.runM (port := watchPort) handler Watch.now
        return first == 0 && second == 60 && (← clock.reads) == 2 },
    { name :=
        "the interrupt key arrives during a command's third publish, on the real text binding: the command makes no request after it, the buffer's text is as before, the echo says interrupted, the event then pulled is marked, taking it lowers the flag, and the next key's command runs to its end"
      run := do
        unless ← Event.setInterruptKey (some Watch.interruptKey) do
          return false
        try
          let published ← Snapshots.new
          let recorder ← DisplayRecorder.new { advance := 8, lineHeight := 16 } published.reader
          -- The key arrives while the command is inside its third publish,
          -- on this thread: nothing else runs between.
          let display : DisplayHandler := fun request => do
            if let .publish scene := request then
              if scene.echo == "spin 3" then
                discard <| Event.post (.key Watch.interruptKey true "")
            recorder.handle request
          let watch := Watch.real timers
          let run {α : Type} (texts : RealTexts) (program : EditorM α) :
            IO (Option α × RealTexts) := do
            let (result, texts) ← program.runReal texts display (watch := watch)
            return (result.toOption, texts)
          let press (text : String) : List Received :=
            (keys text).map fun key => { event := .key key true "", stamp := 0 }
          let takes (loop : Loop TestScheme.scheme) (received : List Received) :
            EditorM (Loop TestScheme.scheme) := do
            let mut loop := loop
            for one in received do
              loop := (← loop.take watchKeys one).loop
            return loop
          let read (loop : Loop TestScheme.scheme) : EditorM String := do
            let some target := loop.state.focusedTarget? | throw .noSuchText
            target.buffer.text.read
          let (started, texts) ←
            run (RealTexts.over published) (Loop.start TestScheme.scheme ⟨640, 480⟩)
          let some loop := started | return false
          -- The command, interrupted in its third round.
          let (interrupted, texts) ←
            run texts do
                let loop ← takes loop (press "C-c l")
                return (loop, ← read loop)
          let some (loop, after) := interrupted | return false
          let made ←
            texts.documents.filterMapM fun document => do
                let some document := document | return none
                return some (← document.read)
          let raised ← Ffi.interruptRaised
          -- The interrupt key is next on the queue, marked.
          let pulled ← Ffi.nextEvent .editor
          let .ok received := Event.ofFfi pulled | return false
          let (lowered, texts) ← run texts (takes loop [received])
          let some loop := lowered | return false
          let down ← Ffi.interruptRaised
          let echoed := loop.state.echo
          -- The next key's command runs to its end.
          let (next, _) ←
            run texts do
                let loop ← takes loop (press "C-c s")
                return (loop.state.echo, ← read loop)
          return after == "" && made == #["", "after 1", "after 2"] && raised &&
              received.interrupt &&
              received.event == .key Watch.interruptKey true "" &&
              !down &&
              echoed == "spin: interrupted" &&
              next == some ("", "C-c s")
        finally
          discard <| Event.setInterruptKey none }]

/-! ## `:!` over the real process service -/

/-- The keys of the shell checks: none bound, and the ex line's commands and
the shell's by name; the shell's job is the one registered. -/
def shellKeys : Loop.Keys TestScheme.scheme :=
  { command? := fun name =>
      ((Ex.commands ++ Shell.commands).find? (·.name == name)).bind fun registration =>
        match registration.action with
        | .call run =>
          some fun call => do
            run call
            return none
        | _ => none
    registered := { jobs := (· == Shell.runJob) } }

/-- `stepped`'s loop once what the step asked for is done, as a host does
it: each invocation it answered run as a step of its own, and each job it
started spawned on `services`, waited for, and its command delivered, each
taken in the same way, at most `depth` deep. `none` when a job did not end
in time or ended otherwise than finished, or a step was refused. -/
partial def settle (services : Job.Services) (display : DisplayHandler) (texts : RealTexts)
    (stepped : Loop.Stepped TestScheme.scheme) (depth : Nat := 8) :
    IO (Option (Loop TestScheme.scheme × RealTexts)) := do
  if depth == 0 then
    return none
  let mut loop := stepped.loop
  let mut texts := texts
  for invocation in stepped.answered do
    let (next, after) ← (loop.invoke shellKeys invocation).runReal texts display
    let .ok next := next | return none
    let some (settled, after) ← settle services display after next (depth - 1) | return none
    loop := settled
    texts := after
  for start in stepped.starts do
    let some work :=
      (Shell.jobs.find? (·.name == start.name)).map (·.work start.arguments) | return none
    let handle ← Job.spawn services work (pure ())
    unless ← eventually handle.ended do
      handle.cancel
      return none
    let some (.finished command) ← handle.outcome? | return none
    handle.settle
    let (next, after) ← (loop.deliver shellKeys s!"job {start.name}" command).runReal texts display
    let .ok next := next | return none
    let some (settled, after) ← settle services display after next (depth - 1) | return none
    loop := settled
    texts := after
  return some (loop, texts)

/-- What only the real process service shows of `:!` and a filter, with the
loop's working directory the fixtures' (`fixtures`, `tests/shell`). -/
def shellChecks (services : Job.Services) (fixtures : System.FilePath) : List Check :=
  let ran (line : String) (contents : String) : IO (Option (String × String)) := do
    let published ← Snapshots.new
    let recorder ← DisplayRecorder.new { advance := 8, lineHeight := 16 } published.reader
    let display := recorder.handle
    let begin : EditorM (Loop TestScheme.scheme) := do
      let loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
      let some target := loop.state.focusedTarget? | throw TextError.noSuchText
      target.buffer.text.insert 0 contents
      return { loop with state := { loop.state with workingDirectory := fixtures } }
    let (started, texts) ← begin.runReal (RealTexts.over published) display
    let .ok loop := started | return none
    let (stepped, texts) ←
      (loop.invoke shellKeys { command := Ex.name, arguments := [.str line] }).runReal texts display
    let .ok stepped := stepped | return none
    let some (loop, texts) ← settle services display texts stepped | return none
    let read : EditorM String := do
      let some target := loop.state.focusedTarget? | throw TextError.noSuchText
      target.buffer.text.read
    let (text, _) ← read.runReal texts display
    let .ok text := text | return none
    return some (loop.state.echo, text)
  [{  name :=
        "criterion 16: over the real process service, `:!` running the fixture `hello` leaves `hello` in the echo area, and its child is reaped"
      run := do
        let before ← Ffi.processesPending
        let said ← ran s!"!'{fixtures / "hello"}'" ""
        let reaped ← eventually (return (← Ffi.processesPending) == before)
        return said == some ("hello", "") && reaped },
    { name :=
        "criterion 17: over the real process service, `:%!/usr/bin/sort` over the lines b, c and a leaves a, b and c, and its child is reaped"
      run := do
        let before ← Ffi.processesPending
        let said ← ran "%!/usr/bin/sort" "b\nc\na\n"
        let reaped ← eventually (return (← Ffi.processesPending) == before)
        return said == some ("3 lines filtered", "a\nb\nc\n") && reaped }]

/-! ## A compile over the real process service -/

/-- The keys of the compile checks: none bound, and the compile mode's
commands by name; its job is the one registered. -/
def compileKeys : Loop.Keys TestScheme.scheme :=
  { command? := fun name =>
      (Compile.commands.find? (·.name == name)).bind fun registration =>
        match registration.action with
        | .call run =>
          some fun call => do
            run call
            return none
        | _ => none
    registered := { jobs := (· == Compile.runJob) } }

/-- The text of the first compilation buffer, if there is one. -/
def compilationText (loop : Loop TestScheme.scheme) : EditorM (Option String) := do
  match (loop.state.buffers.toList.filterMap id).find? (·.name.startsWith "*compilation: ") with
  | some buffer =>
    return some (← buffer.text.read)
  | none =>
    return none

/-- What only the real process service shows of a compile: its output in
the compilation buffer before the child ends, with the fixture
`three-lines` (`fixtures`, `tests/compile`), which waits for files the
check makes. -/
def compileChecks (services : Job.Services) (fixtures : System.FilePath) : List Check :=
  [{  name :=
        "criterion 11: over the real process service, the fixture three-lines shows each line in the compilation buffer before it ends, and its exit status in the last line; its child is reaped"
      run := do
        let before ← Ffi.processesPending
        let directory ← IO.FS.createTempDir
        try
          let published ← Snapshots.new
          let recorder ← DisplayRecorder.new { advance := 8, lineHeight := 16 } published.reader
          let display := recorder.handle
          -- A scratch buffer has no workspace: the directory scope is the
          -- loop's working directory, where the fixture looks for its files.
          let begin : EditorM (Loop TestScheme.scheme) := do
            let loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
            return { loop with state := { loop.state with workingDirectory := directory } }
          let (started, texts) ← begin.runReal (RealTexts.over published) display
          let .ok loop := started | return false
          let line := s!"'{fixtures / "three-lines"}'"
          let (stepped, texts) ←
            (loop.invoke compileKeys
                    { command := Compile.compileName, arguments := [.str line] }).runReal
                texts display
          let .ok stepped := stepped | return false
          let some start := stepped.starts[0]? | return false
          let some work :=
            (Compile.jobs.find? (·.name == start.name)).map (·.work start.arguments) | return false
          let posts ← IO.mkRef (#[] : Array Invocation)
          let handle ←
            Job.spawn services work (pure ()) fun invocation => posts.modify (·.push invocation)
          let loopRef ← IO.mkRef stepped.loop
          let textsRef ← IO.mkRef texts
          -- Delivers `command` as the loop delivers a job's, and reads the
          -- compilation buffer after it.
          let deliver (command : EditorM Unit) : IO (Option String) := do
            let (next, after) ←
              ((← loopRef.get).deliver compileKeys s!"job 1 {Compile.runJob}" command).runReal
                  (← textsRef.get) display
            textsRef.set after
            let .ok next := next | return none
            loopRef.set next.loop
            let (text, after) ← (compilationText next.loop).runReal (← textsRef.get) display
            textsRef.set after
            return (text.toOption).join
          let postsAt (count : Nat) : IO Bool := eventually (return (← posts.get).size ≥ count)
          let deliverPost (index : Nat) : IO (Option String) := do
            let some invocation := (← posts.get)[index]? | return none
            deliver (runPosted invocation)
          unless ← postsAt 1 do
            handle.cancel
            return false
          let first ← deliverPost 0
          IO.FS.writeFile (directory / "go-1") ""
          unless ← postsAt 2 do
            handle.cancel
            return false
          let second ← deliverPost 1
          IO.FS.writeFile (directory / "go-2") ""
          unless ← eventually handle.ended do
            handle.cancel
            return false
          -- What the child wrote after `two` came in posts of its own or with
          -- its end: each is delivered, in order, then the job's command.
          let mut last := second
          for index in [2:(← posts.get).size] do
            last ← deliverPost index
          let some (.finished command) ← handle.outcome? | return false
          last ← deliver command
          handle.settle
          let reaped ← eventually (return (← Ffi.processesPending) == before)
          let lastLine (text : String) : String :=
            ((text.splitOn "\n").filter (!·.isEmpty)).getLast?.getD ""
          let has (text : Option String) (part : String) : Bool :=
            text.any fun text => (text.splitOn "\n").contains part
          return has first "one" && !has first "two" &&
              !(first.any fun text => (text.splitOn "Compilation").length > 1) &&
              has second "two" &&
              !has second "three" &&
              has last "three" &&
              (last.map lastLine).any
                (·.startsWith "Compilation exited abnormally with code 2 after ") &&
              reaped
        finally
          IO.FS.removeDirAll directory }]

/-! ## A child's environment over the real process service -/

/-- The standard output of `command` run through `services`, as text; a
refusal, a status other than 0 or output that is not UTF-8 fails the job. -/
def outputOf (command : Process.Command) : JobM String := do
  let ran ← JobContract.ranOk command
  unless ran.exit == .code 0 do
    throw s!"{command.program} ended with {repr ran.exit}"
  let some text := String.fromUTF8? ran.stdout | throw s!"{command.program} wrote what is not UTF-8"
  return text

/-- `services` whose jobs share environments over a state of their own with
`setting`, the headless mode and a limit of `limit` milliseconds, which
report into `said`. -/
def withEnvironment (services : Job.Services) (setting : Process.Setting) (limit : Nat)
    (said : IO.Ref (Array String)) : IO Job.Services := do
  let state ← IO.mkRef ({ setting, host := .headless, limit } : Process.Environments)
  return { services with
      environments := Job.sharedEnvironments state fun text => said.modify (·.push text) }

/-- A temporary directory of its own for `check`, holding the file
`fixture-path` with the line `<directory>/tools:/usr/bin:/bin`, the `PATH`
the mise fixture prints there; removed afterwards, whatever happened. -/
def withFixturePath (check : System.FilePath → String → IO Bool) : IO Bool := do
  let directory ← IO.FS.createTempDir
  try
    let path := s!"{directory}/tools:/usr/bin:/bin"
    IO.FS.writeFile (directory / "fixture-path") s!"{path}\n"
    check directory path
  finally
    IO.FS.removeDirAll directory

/-- What `command` prints when a job runs it through `services`; `none`
when the job did not finish with it. -/
def printedThrough (services : Job.Services) (command : Process.Command) : IO (Option String) := do
  let handle ← Job.spawn services (reporting fun _ => outputOf command) (pure ())
  unless ← eventually handle.ended do
    handle.cancel
    return none
  handle.settle
  match (← handle.outcome?).map texts with
  | some (.finished #[text]) =>
    return some text
  | _ =>
    return none

/-- What the job port shows only over the real process service: the lookup
of a child's environment with mise standing in as the fixtures under
`fixtures` (`tests/process-environment`). Each check works in temporary
directories of its own, which it removes, and none sets a variable of the
test process or changes its working directory. -/
def environmentChecks (services : Job.Services) (fixtures : System.FilePath) : List Check :=
  let printenv (directory : System.FilePath) (program := "/usr/bin/printenv") : Process.Command :=
    { program, arguments := #["PATH"], directory }
  [{  name :=
        "with mise standing in as a fixture, a child started in each of two directories, by its path and by a bare name, gets that directory's fixture PATH, and nothing is reported"
      run :=
        withFixturePath fun first firstPath =>
          withFixturePath fun second secondPath => do
            let said ← IO.mkRef #[]
            let services ← withEnvironment services (.mise (some (fixtures / "mise"))) 1000 said
            let before ← Ffi.processesPending
            let outcome ←
              runOnTimers services do
                  let byPath ← [first, second].mapM fun directory => outputOf (printenv directory)
                  let bare ←
                    [first, second].mapM fun directory => outputOf (printenv directory "printenv")
                  return byPath == [firstPath ++ "\n", secondPath ++ "\n"] && bare == byPath
            let reaped ← eventually (return (← Ffi.processesPending) == before)
            return outcome == .finished true && (← said.get).isEmpty && reaped },
    { name :=
        "with a mise that sleeps past a limit of 1 s, the lookup is killed within 2 s of its start, its group reaped, the child gets the inherited environment, and the timeout is reported once"
      run :=
        withFixturePath fun directory _ => do
          let some inherited ← printedThrough services (printenv directory) | return false
          let said ← IO.mkRef #[]
          let services ← withEnvironment services (.mise (some (fixtures / "slow-mise"))) 1000 said
          let before ← Ffi.processesPending
          let outcome ←
            runOnTimers services do
                -- The lookup starts after this reading.
                let start ← now
                let path ← outputOf (printenv directory)
                let ended ← now
                return ended - start < 2000 && path == inherited
          let reaped ← eventually (return (← Ffi.processesPending) == before)
          return outcome == .finished true &&
              (← said.get) == #[Process.failureMessage directory (.timedOut 1000)] &&
              reaped }]

/-- The names of the environment checks that fail over the real process
service, and, when the environment a child of the test process gets is not
the same after them as before, that: `/usr/bin/env` run with the inherited
setting, in a temporary directory, before the first and after the last. -/
def environmentFailures (services : Job.Services) (fixtures : System.FilePath) : IO (List String) :=
  do
  let env (directory : System.FilePath) : Process.Command :=
    { program := "/usr/bin/env", directory }
  let directory ← IO.FS.createTempDir
  try
    let before ← printedThrough services (env directory)
    let failed ← checkFailures (environmentChecks services fixtures)
    let after ← printedThrough services (env directory)
    return failed ++
        if before.isSome && before == after then []
        else
          ["the test process's environment after the environment checks is what it was before them"]
  finally
    IO.FS.removeDirAll directory

/-! ## The workspace finder over the real process and file services -/

/-- A temporary directory of its own for `check`, with its real path, so that
what the git fixture prints names it as the finder does; removed
afterwards, whatever happened. -/
def withBase {α : Type} (check : System.FilePath → IO α) : IO α := do
  let directory ← IO.FS.createTempDir
  try
    check (← IO.FS.realPath directory)
  finally
    IO.FS.removeDirAll directory

/-- Writes `content` as the file `path`, with the directories on the way. -/
def writeMaking (path : System.FilePath) (content : String) : IO Unit := do
  if let some parent := path.parent then
    IO.FS.createDirAll parent
  IO.FS.writeFile path content

/-- Writes the git fixture's file for `repository` in its top level: the
three lines rev-parse prints there (`tests/workspaces/README`), and its
`origin`, if it has one. -/
def writeRepository (repository : Workspace.Repository) : IO Unit := do
  writeMaking (repository.toplevel / "fixture-git")
      ((String.fromUTF8? repository.revParsed).getD "")
  if let some origin := repository.origin then
    writeMaking (repository.toplevel / "fixture-origin") s!"{origin}\n"

/-- Writes `world` to disk, for the finder's run over the real services: each
repository's fixture files, each marker file, empty, each marker directory,
and each directory of `asked`. -/
def materialize (world : Workspace.World) (asked : Array System.FilePath) : IO Unit := do
  for repository in world.repositories do
    writeRepository repository
  for marker in world.markers do
    writeMaking marker ""
  for directory in world.markerDirectories ++ asked do
    IO.FS.createDirAll directory

/-- The git a property's finder runs over the real services: the fixture
under `fixtures`, or, in a world with no git, a path under `base` where
nothing is, which the process service refuses as `notFound`. -/
def gitOf (world : Workspace.World) (fixtures base : System.FilePath) : String :=
  if world.git then (fixtures / "git").toString else (base / "no-git").toString

/-- The names of the workspace finder's contract properties
(`Editor/Workspace/Contract.lean`) that do not hold of `Workspace.find`
over the library's process and file services, each world written out in a
temporary directory of its own, with git standing in as the fixture under
`fixtures` (`tests/workspaces`); and that every child it ran is reaped. -/
def workspaceFailures (services : Job.Services) (fixtures : System.FilePath) : IO (List String) :=
  do
  let before ← Ffi.processesPending
  let failed ←
    (Workspace.FinderContract.properties "/").filterMapM fun named =>
        withBase fun base => do
          let some property :=
            (Workspace.FinderContract.properties base).find? (·.name == named.name)
            | return some named.name
          materialize property.world (property.asked.map (·.1))
          let outcome ← runOnTimers services (property.holds (gitOf property.world fixtures base))
          return if outcome == .finished true then none
            else some s!"{property.name} ({repr outcome})"
  let reaped ← eventually (return (← Ffi.processesPending) == before)
  return failed.map (s!"the workspace finder over the process and file services: {·}") ++
      if reaped then [] else ["every child the workspace finder ran is reaped"]

/-- The names of the mode marker search's contract properties
(`Editor/Workspace/Contract.lean`, `Workspace.MarkerContract`) that do not
hold of `Workspace.presentMarkers` over the library's file service, each
world written out in a temporary directory of its own. -/
def modeMarkerFailures (services : Job.Services) : IO (List String) := do
  let failed ←
    (Workspace.MarkerContract.properties "/").filterMapM fun named =>
        withBase fun base => do
          let some property :=
            (Workspace.MarkerContract.properties base).find? (·.name == named.name)
            | return some named.name
          materialize property.world (property.asked.map (·.1))
          let outcome ← runOnTimers services property.holds
          return if outcome == .finished true then none
            else some s!"{property.name} ({repr outcome})"
  return failed.map (s!"the mode marker search over the file service: {·}")

/-- Whether `Workspace.find`, with git standing in as the fixture under
`fixtures`, answers each directory of `asked` with its answer, over
`services`; and that every child it ran is reaped. -/
def findsThrough (services : Job.Services) (fixtures : System.FilePath)
    (asked : List (System.FilePath × Option Workspace.Found)) : IO Bool := do
  let before ← Ffi.processesPending
  let outcome ←
    runOnTimers services do
        let found ←
          asked.mapM fun (directory, _) =>
              Workspace.find { git := (fixtures / "git").toString } directory
        return found == asked.map (·.2)
  let reaped ← eventually (return (← Ffi.processesPending) == before)
  return outcome == .finished true && reaped

/-- The tree of the workspace checks under `base`: a main checkout `main`,
whose `.git` is a directory, a worktree-shaped `wt`, whose `.git` is a file,
of the same common directory, each with a `src` directory and the git
fixture's file, and `plain`, which holds only `Cargo.toml` and a `src`
directory. -/
def writeWorkspaceTree (base : System.FilePath) : IO Unit := do
  IO.FS.createDirAll (base / "main" / ".git")
  IO.FS.createDirAll (base / "main" / "src")
  writeMaking (base / "main" / "fixture-git") s!"{base / "main"}\n{base / "main" / ".git"}\nmain\n"
  writeMaking (base / "wt" / ".git") s!"gitdir: {base / "main" / ".git" / "worktrees" / "wt"}\n"
  IO.FS.createDirAll (base / "wt" / "src")
  writeMaking (base / "wt" / "fixture-git") s!"{base / "wt"}\n{base / "main" / ".git"}\nfeature\n"
  writeMaking (base / "plain" / "Cargo.toml") ""
  IO.FS.createDirAll (base / "plain" / "src")

/-- What the workspace finder shows over the real process and file
services, with git standing in as the fixture under `fixtures`
(`tests/workspaces`): a main checkout and a worktree-shaped directory are
two workspaces of one project, as the models say. Each check works in a
temporary directory of its own, which it removes, and none sets a variable
of the test process or changes its working directory. -/
def workspaceChecks (services : Job.Services) (fixtures : System.FilePath) : List Check :=
  [{  name :=
        "over the real process and file services, a main checkout and a worktree-shaped directory resolve to two workspaces, with the fixture's branches, of one project identified by the common git directory; a directory with only a marker resolves through it"
      run :=
        withBase fun base => do
          writeWorkspaceTree base
          let commonDir := base / "main" / ".git"
          let project : Project :=
            { identity := .commonDir commonDir, name := "main", commonDir := some commonDir }
          findsThrough services fixtures
              [(base / "main" / "src",
                  some { root := base / "main", branch := some (.named "main"), project }),
                (base / "wt" / "src",
                  some { root := base / "wt", branch := some (.named "feature"), project }),
                (base / "plain" / "src", some (Workspace.Found.ofMarker (base / "plain")))] },
    { name :=
        "over the real process and file services, with an origin for each, the main checkout and the worktree-shaped directory share the project of the normalised origin"
      run :=
        withBase fun base => do
          writeWorkspaceTree base
          let origin := "git@github.com:o/r.git"
          writeMaking (base / "main" / "fixture-origin") s!"{origin}\n"
          writeMaking (base / "wt" / "fixture-origin") "https://github.com/o/r\n"
          let commonDir := base / "main" / ".git"
          let project (remote : String) : Project :=
            { identity := .remote "github.com/o/r", name := "r", remote := some remote
              commonDir := some commonDir }
          findsThrough services fixtures
              [(base / "main" / "src",
                  some
                    { root := base / "main", branch := some (.named "main"),
                      project := project origin }),
                (base / "wt" / "src",
                  some
                    { root := base / "wt", branch := some (.named "feature")
                      project := project "https://github.com/o/r" })] }]

/-! ## The shipped modes over the real process service -/

/-- `command` with `PATH` set to `path` in its own environment, in place of
any `PATH` it sets. -/
def withPath (path : String) (command : Process.Command) : Process.Command :=
  { command with
    environment :=
      { command.environment with
        set := (command.environment.set.filter (·.1 != "PATH")).push ("PATH", path) } }

/-- `services` whose process service starts every child with `PATH` set to
`path`, after the environment its directory's lookup gives it: each request
that starts a child is matched constructor by constructor, so the replies'
types line up. The test process's own environment is never touched. -/
def onFixturePath (services : Job.Services) (path : String) : Job.Services :=
  let processes := services.processes
  let pathed : ProcessRequest → ProcessRequest
    | .run command limit => .run (withPath path command) limit
    | .runWithin command limit time => .runWithin (withPath path command) limit time
    | .runInput command input limit time => .runInput (withPath path command) input limit time
    | .start command streaming => .start (withPath path command) streaming
    | other => other
  { services with
    processes :=
      { start := fun id request => processes.start id (pathed request)
        take := fun id request =>
          match request with
          | .run command limit => processes.take id (.run (withPath path command) limit)
          | .runWithin command limit time =>
            processes.take id (.runWithin (withPath path command) limit time)
          | .runInput command input limit time =>
            processes.take id (.runInput (withPath path command) input limit time)
          | .start command streaming => processes.take id (.start (withPath path command) streaming)
          | .read process => processes.take id (.read process)
          | .write process bytes => processes.take id (.write process bytes)
          | .closeInput process => processes.take id (.closeInput process)
        cancel := processes.cancel } }

/-- The jobs of the project mode checks: the file commands', the workspace
finder's and the compile mode's, as a host registers them. -/
def projectJobs : Array Config.JobRegistration :=
  Files.jobs ++ Workspace.jobs ++ Compile.jobs

/-- The keys of the project mode checks: none bound; the file commands',
the workspace's and the compile mode's commands by name; their jobs
registered; and the loop told the shipped contributions. -/
def projectKeys : Loop.Keys TestScheme.scheme :=
  { command? := fun name =>
      ((Files.commands ++ Workspace.commands ++ Compile.commands).find? (·.name == name)).bind
        fun registration =>
        match registration.action with
        | .call run =>
          some fun call => do
            run call
            return none
        | _ => none
    registered :=
      { jobs := fun name => projectJobs.any (·.name == name)
        compile := { contributions := Compile.shipped } } }

/-- What the project mode checks run with: their services, whose file
service reads the table of snapshots their texts publish and keeps its loads
in `held`, and the display those texts are drawn on. -/
structure ProjectRig where
  /-- The table of snapshots the texts publish. -/
  published : Snapshots
  /-- What the jobs hold. -/
  held : Job.HeldSnapshots
  /-- The display. -/
  display : DisplayHandler
  /-- The services the jobs run on. -/
  services : Job.Services

/-- A rig over `services`, whose children get `path` as their `PATH`
(`onFixturePath`), with a file service of its own. -/
def ProjectRig.new (services : Job.Services) (path : String) : IO ProjectRig := do
  let published ← Snapshots.new
  let held ← Job.HeldSnapshots.new
  let recorder ← DisplayRecorder.new { advance := 8, lineHeight := 16 } published.reader
  return {
      published, held, display := recorder.handle
      services :=
        { onFixturePath services path with
          files := Job.realFiles services.completions published.reader held } }

/-- `stepped`'s loop once what the step asked for is done, as a host does
it: each invocation it answered run as a step of its own; each job it
started spawned on the rig's services with its posts collected, waited for,
then each post delivered in order (`runPosted`) and then its command, handed
what the job held (`Job.finishWith`); each taken in the same way, at most
`depth` deep. Only a job's end is waited for. `none` when a job did not end
in time or ended otherwise than finished, or a step was refused. -/
partial def settleProjects (rig : ProjectRig) (texts : RealTexts)
    (stepped : Loop.Stepped TestScheme.scheme) (depth : Nat := 8) :
    IO (Option (Loop TestScheme.scheme × RealTexts)) := do
  if depth == 0 then
    return none
  let mut loop := stepped.loop
  let mut texts := texts
  for invocation in stepped.answered do
    let (next, after) ← (loop.invoke projectKeys invocation).runReal texts rig.display
    let .ok next := next | return none
    let some (settled, after) ← settleProjects rig after next (depth - 1) | return none
    loop := settled
    texts := after
  for start in stepped.starts do
    let some work :=
      (projectJobs.find? (·.name == start.name)).map (·.work start.arguments) | return none
    let posts ← IO.mkRef (#[] : Array Invocation)
    let handle ←
      Job.spawn rig.services work (pure ()) fun invocation => posts.modify (·.push invocation)
    unless ← eventually handle.ended do
      handle.cancel
      return none
    let label := s!"job {start.name}"
    for invocation in ← posts.get do
      let (next, after) ←
        (loop.deliver projectKeys label (runPosted invocation)).runReal texts rig.display
      let .ok next := next | return none
      let some (settled, after) ← settleProjects rig after next (depth - 1) | return none
      loop := settled
      texts := after
    let some (.finished command) ← handle.outcome? | return none
    let (next, after) ←
      Job.finishWith rig.held handle (loop.deliver projectKeys label command) texts rig.display
    let .ok next := next | return none
    let some (settled, after) ← settleProjects rig after next (depth - 1) | return none
    loop := settled
    texts := after
  return some (loop, texts)

/-- The loop, with its working directory `base`, once each of
`invocations` has run and settled (`settleProjects`), in order. -/
def runSettled (rig : ProjectRig) (base : System.FilePath) (invocations : List Invocation) :
    IO (Option (Loop TestScheme.scheme × RealTexts)) := do
  let begin : EditorM (Loop TestScheme.scheme) := do
    let loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
    return { loop with state := { loop.state with workingDirectory := base } }
  let (started, texts) ← begin.runReal (RealTexts.over rig.published) rig.display
  let .ok loop := started | return none
  let mut loop := loop
  let mut texts := texts
  for invocation in invocations do
    let (stepped, after) ← (loop.invoke projectKeys invocation).runReal texts rig.display
    let .ok stepped := stepped | return none
    let some (settled, after) ← settleProjects rig after stepped | return none
    loop := settled
    texts := after
  return some (loop, texts)

/-- The invocation that opens `path`. -/
def openFile (path : System.FilePath) : Invocation :=
  { command := Files.openName, arguments := [.str path.toString] }

/-- The invocation of `compile-command` with the answer `answer`. -/
def compileCommandOf (answer : String) : Invocation :=
  { command := Compile.commandName, arguments := [.str answer] }

/-- The invocation of `next-error`. -/
def nextError : Invocation :=
  { command := Compile.nextName }

/-- The text of the buffer called `name` in `loop`. -/
def bufferText (rig : ProjectRig) (texts : RealTexts) (loop : Loop TestScheme.scheme)
    (name : String) : IO (Option String) := do
  let read : EditorM (Option String) := do
    let some id := loop.state.findBuffer name | return none
    let some buffer := loop.state.buffer? id | return none
    return some (← buffer.text.read)
  let (text, _) ← read.runReal texts rig.display
  return text.toOption.join

/-- The file of the focused view's buffer in `loop`, and the row and column
of its cursor. -/
def focusedAt (rig : ProjectRig) (texts : RealTexts) (loop : Loop TestScheme.scheme) :
    IO (Option (String × Nat × Nat)) := do
  let read : EditorM (Option (String × Nat × Nat)) := do
    let some target := loop.state.focusedTarget? | return none
    let some file := target.buffer.file | return none
    let selection ← target.selection
    let head := (selection.ranges[selection.primary]?.map (·.head)).getD 0
    let point ← target.buffer.text.pointOf head
    return some (file.path.toString, point.row, point.column)
  let (at_, _) ← read.runReal texts rig.display
  return at_.toOption.join

/-- The locations of the workspace at `root` in `loop`, as each one's
format, file, line, column and message. -/
def locationsAt (loop : Loop TestScheme.scheme) (root : System.FilePath) :
    Array (String × String × Nat × Option Nat × Option String) :=
  (Compile.recordOf loop.state (.workspace (.local root))).locations.map fun site =>
    (site.format, site.file.toString, site.line, site.column, site.message)

/-- The lines of the file `path`, without the empty one after its last line
feed. -/
def fileLines (path : System.FilePath) : IO (List String) := do
  let lines := (← IO.FS.readFile path).splitOn "\n"
  return if lines.getLast? == some "" then lines.dropLast else lines

/-- Whether `text` is `header`, then the lines of the file `canned`, then a
last line that starts `last`. -/
def compiledAs (text : Option String) (header : String) (canned : System.FilePath) (last : String) :
    IO Bool := do
  let lines ← fileLines canned
  return text.any fun text =>
      match (text.splitOn "\n").filter (· != "") |>.reverse with
      | final :: rest => final.startsWith last && rest.reverse == header :: lines.filter (· != "")
      | [] => false

/-- Copies the tree `source` to `target`, every file with its bytes. -/
partial def copyTree (source target : System.FilePath) : IO Unit := do
  IO.FS.createDirAll target
  for entry in ← source.readDir do
    if ← entry.path.isDir then
      copyTree entry.path (target / entry.fileName)
    else
      IO.FS.writeBinFile (target / entry.fileName) (← IO.FS.readBinFile entry.path)

/-- Writes the git fixture's file in `root`: the three lines rev-parse
prints there, its top level `root`, the common directory `common` and the
branch `branch`. -/
def writeFixtureGit (root common : System.FilePath) (branch : String) : IO Unit :=
  writeMaking (root / "fixture-git") s!"{root}\n{common}\n{branch}\n"

/-- The trees of the project mode checks under `base`, from the fixtures
under `compile` (`tests/compile`): `cargo`, `lake` and `mise`, each a
repository of its own on `main`, and `cargo-wt`, a copy of `cargo` shaped as
its worktree on `feature`, whose `.git` names an absolute path. -/
def materializeProjects (base compile : System.FilePath) : IO Unit := do
  for tree in ["cargo", "lake", "mise"] do
    copyTree (compile / tree) (base / tree)
  copyTree (compile / "cargo") (base / "cargo-wt")
  for tree in ["cargo", "lake", "mise"] do
    IO.FS.createDirAll (base / tree / ".git")
    writeFixtureGit (base / tree) (base / tree / ".git") "main"
  writeMaking (base / "cargo-wt" / ".git")
      s!"gitdir: {base / "cargo" / ".git" / "worktrees" / "cargo-wt"}\n"
  writeFixtureGit (base / "cargo-wt") (base / "cargo" / ".git") "feature"

/-- Runs `check` in a base of its own holding the project trees
(`materializeProjects`), on a rig whose children find the fixture programs
of `compile` and the git fixture of `workspaces` first on their `PATH`;
then whether every child it started was reaped. -/
def withProjects (services : Job.Services) (compile workspaces : System.FilePath)
    (check : ProjectRig → System.FilePath → IO Bool) : IO Bool :=
  withBase fun base => do
    materializeProjects base compile
    let rig ← ProjectRig.new services s!"{compile / "bin"}:{workspaces}:/usr/bin:/bin"
    let before ← Ffi.processesPending
    let held ← check rig base
    let reaped ← eventually (return (← Ffi.processesPending) == before)
    return held && reaped

/-- What only the real process service shows of the shipped modes, with
fixture programs standing in for cargo, lake, mise and git (`compile`,
`tests/compile`, and `workspaces`, `tests/workspaces`), first on each
child's `PATH`: each check opens files of the trees `materializeProjects`
writes, runs a named command and steps to its locations. -/
def projectModeChecks (services : Job.Services) (compile workspaces : System.FilePath) :
    List Check :=
  let canned (name : String) : System.FilePath := compile / "bin" / name
  [{  name :=
        "modes criterion 8: over the real process service with the fixture cargo, compile-command build in the Cargo fixture fills cargo@main's compilation buffer with the fixture's output, ends exited abnormally with code 101, and next-error visits the rustc location in the fixture tree"
      run :=
        withProjects services compile workspaces fun rig base => do
          let main := base / "cargo" / "src" / "main.rs"
          let some (stepped, texts) ←
            runSettled rig base [openFile main, compileCommandOf "build", nextError] | return false
          let text ← bufferText rig texts stepped "*compilation: cargo@main*"
          let shown ←
            compiledAs text s!"cargo@main in {base / "cargo"}: cargo build"
                (canned "cargo-build.txt") "Compilation exited abnormally with code 101 after "
          return shown &&
              locationsAt stepped (base / "cargo") ==
                #[("rustc", main.toString, 4, some 18, some "mismatched types")] &&
              (← focusedAt rig texts stepped) == some (main.toString, 3, 17) },
    { name :=
        "modes criterion 9: over the real process service with the fixture lake, compile-command build in the Lean fixture fills lake@main's compilation buffer with the fixture's output and ends exited abnormally with code 1"
      run :=
        withProjects services compile workspaces fun rig base => do
          let some (built, texts) ←
            runSettled rig base
                [openFile (base / "lake" / "Foo" / "Bar.lean"),
                  compileCommandOf "build"] | return false
          let text ← bufferText rig texts built "*compilation: lake@main*"
          compiledAs text s!"lake@main in {base / "lake"}: lake build" (canned "lake-build.txt")
              "Compilation exited abnormally with code 1 after " },
    { name :=
        "modes criterion 10: after that build, next-error visits Foo/Bar.lean line 12 column 4 in the Lean fixture tree: row 11, character 4, the x of its last line"
      run :=
        withProjects services compile workspaces fun rig base => do
          let bar := base / "lake" / "Foo" / "Bar.lean"
          let some (stepped, texts) ←
            runSettled rig base [openFile bar, compileCommandOf "build", nextError] | return false
          return locationsAt stepped (base / "lake") ==
                #[("lean", bar.toString, 12, some 4, some "unknown identifier 'x'")] &&
              (← focusedAt rig texts stepped) == some (bar.toString, 11, 4) },
    { name :=
        "modes criterion 11: with the fixture mise, mise-mode offers the fixture's tasks in the mise tree, after cargo-mode's in the nested crate, and running test, whose output is rustc's errors, finds them through cargo-mode's format in the nested crate"
      run :=
        withProjects services compile workspaces fun rig base => do
          let crateMain := base / "mise" / "crate" / "src" / "main.rs"
          let some (opened, _) ← runSettled rig base [openFile crateMain] | return false
          let some (tested, _) ←
            runSettled rig base
                [openFile crateMain, compileCommandOf "test (mise-mode)"] | return false
          let state := opened.state
          let modes :=
            match state.focusedTarget? with
            | some target => Workspace.onModesOf state target.window.buffer
            | none => #[]
          let offered :=
            Compile.offers Compile.shipped #[] modes
              (Compile.listedCommands state (some (.local (base / "mise"))))
          let crate := base / "mise" / "crate"
          let mise := base / "mise"
          return modes ==
                #[{ mode := "cargo-mode", root := crate }, { mode := "mise-mode", root := mise }] &&
              offered.map (fun offer => (offer.candidate, offer.line, offer.root)) ==
                #[("build (cargo-mode)", "cargo build", crate),
                  ("test (cargo-mode)", "cargo test", crate),
                  ("clippy (cargo-mode)", "cargo clippy", crate),
                  ("build (mise-mode)", "mise run build", mise),
                  ("test (mise-mode)", "mise run test", mise)] &&
              locationsAt tested mise ==
                #[("rustc", crateMain.toString, 4, some 18, some "mismatched types")] },
    { name :=
        "modes criterion 12: build run in the Cargo fixture and in its worktree-shaped copy fills two compilation buffers with separate error lists, next-error in each visits its own tree's file, and both workspaces read one project history holding cargo build once"
      run :=
        withProjects services compile workspaces fun rig base => do
          let main := base / "cargo" / "src" / "main.rs"
          let wtMain := base / "cargo-wt" / "src" / "main.rs"
          let some (built, texts) ←
            runSettled rig base
                [openFile main, compileCommandOf "build", openFile wtMain,
                  compileCommandOf "build"] | return false
          let some (inWt, wtTexts) ←
            runSettled rig base
                [openFile main, compileCommandOf "build", openFile wtMain, compileCommandOf "build",
                  nextError] | return false
          let some (inMain, mainTexts) ←
            runSettled rig base
                [openFile main, compileCommandOf "build", openFile wtMain, compileCommandOf "build",
                  openFile main, nextError] | return false
          let history :=
            match
              built.state.focusedTarget?.bind fun target =>
                built.state.workspaceOf? target.window.buffer with
            | some (_, project) =>
              built.state.workspaces.getOfProject Compile.historyStore project.identity
            | none => #[]
          let mainText ← bufferText rig texts built "*compilation: cargo@main*"
          let wtText ← bufferText rig texts built "*compilation: cargo@feature*"
          return mainText.isSome && wtText.isSome &&
              (locationsAt built (base / "cargo")).map (·.2.1) == #[main.toString] &&
              (locationsAt built (base / "cargo-wt")).map (·.2.1) == #[wtMain.toString] &&
              (← focusedAt rig wtTexts inWt) == some (wtMain.toString, 3, 17) &&
              (← focusedAt rig mainTexts inMain) == some (main.toString, 3, 17) &&
              history == #["cargo build"] }]

end ContractTest

/-- Runs the text port's contract against its real binding, then the job
port's contract and the job checks against the runner over the library's
timer service, the display interface's against the recorder and the watch
port's against its real binding, then shuts down: exits 0 when everything
holds, and 1 after naming on stderr what does not.

Its five arguments are the directory of the fixtures a child's
environment is looked up with (`tests/process-environment`), the directory
of the fixture that stands in for git in the workspace finder's checks
(`tests/workspaces`), the directory of the fixture `:!` runs, which is also
the editor's working directory in those checks (`tests/shell`), the
directory of the fixtures `compile` runs, with the programs that stand for
cargo, lake and mise and the trees the shipped modes are checked in
(`tests/compile`), and the directory of the syntax fixtures (`tests/syntax`), each made absolute here;
any other command line is status 2, with the usage on stderr.

The pool's threads are learnt first, by warming it, before anything else
runs: the check that the pump is not one of the pool's tasks compares
against them. Then the completion pump runs on a dedicated task for the rest
of the run. Shutdown is quit, which must end the pump, then an explicit
exit: a task that failed a check may still be blocked in the library. -/
def main (arguments : List String) : IO UInt32 := do
  -- The fixtures of the environment checks, the workspace checks, the shell
  -- checks, the compile checks and the syntax checks, made absolute here, at
  -- the edge.
  let (fixtures, workspaceFixtures, shellFixtures, compileFixtures, syntaxFixtures) ←
    match arguments with
    | [directory, workspaces, shell, compile, syntaxDirectory] =>
      pure
          (← IO.FS.realPath directory, ← IO.FS.realPath workspaces, ← IO.FS.realPath shell,
            ← IO.FS.realPath compile, ← IO.FS.realPath syntaxDirectory)
    | _ =>
      IO.eprintln
          "usage: contract-test <the directory of the process-environment fixtures> <the directory of the workspace fixtures> <the directory of the shell fixtures> <the directory of the compile fixtures> <the directory of the syntax fixtures>"
      return 2
  let pool ← Editor.Job.Pool.whole ContractTest.warmPatience
  let completions ← Editor.Job.Completions.new
  -- No command of this run publishes a snapshot to these services: the file
  -- properties save what their own jobs loaded.
  let published ← Editor.Snapshots.new
  let held ← Editor.Job.HeldSnapshots.new
  let timers := Editor.Job.realTimers completions
  let services : Editor.Job.Services :=
    { completions, timers
      files := Editor.Job.realFiles completions published.reader held
      processes :=
        Editor.Job.realProcesses completions (← Editor.Job.RefusedRuns.new) timers
          (← Editor.Job.TimedRuns.new)
      fileWatches := Editor.Job.realFileWatches completions (← Editor.Job.RealWatches.new)
      diffs :=
        Editor.Job.realDiffs completions published.reader held (← Editor.Job.RefusedDiffs.new) }
  let pump ← IO.asTask (prio := .dedicated) (Editor.Job.pump completions)
  let properties := Editor.TextContract.properties
  -- The undo tree's cases run through the same binding, so the count of
  -- live documents covers the texts they make too.
  let cases := Editor.UndoTreeCases.cases
  let adoptProperties := Editor.TextContract.adoptProperties
  let textFailed ← ContractTest.failures (properties ++ cases) adoptProperties
  let pairChecks := ContractTest.pairChecks
  let pairCheckFailed ← ContractTest.checkFailures pairChecks
  let jobFailed ← ContractTest.jobFailures services
  let postFailed ← ContractTest.postFailures services
  let fileFailed ← ContractTest.fileFailures services held
  let processFailed ← ContractTest.processFailures services
  let processChecks := ContractTest.processChecks services
  let processCheckFailed ← ContractTest.checkFailures processChecks
  let environmentChecks := ContractTest.environmentChecks services fixtures
  let environmentFailed ← ContractTest.environmentFailures services fixtures
  let workspaceFailed ← ContractTest.workspaceFailures services workspaceFixtures
  let modeMarkerFailed ← ContractTest.modeMarkerFailures services
  let workspaceChecks := ContractTest.workspaceChecks services workspaceFixtures
  let workspaceCheckFailed ← ContractTest.checkFailures workspaceChecks
  let shellChecks := ContractTest.shellChecks services shellFixtures
  let shellCheckFailed ← ContractTest.checkFailures shellChecks
  let compileChecks := ContractTest.compileChecks services compileFixtures
  let compileCheckFailed ← ContractTest.checkFailures compileChecks
  let projectModeChecks := ContractTest.projectModeChecks services compileFixtures workspaceFixtures
  let projectModeCheckFailed ← ContractTest.checkFailures projectModeChecks
  let fileWatchFailed ← ContractTest.fileWatchFailures services
  let fileWatchChecks := ContractTest.fileWatchChecks services
  let fileWatchCheckFailed ← ContractTest.checkFailures fileWatchChecks
  -- The job checks first: the last of them measures the pool, which a later
  -- check must not have grown.
  let checks := ContractTest.jobChecks services pool
  let checkFailed ← ContractTest.checkFailures checks
  let fileChecks := ContractTest.fileChecks completions
  let fileCheckFailed ← ContractTest.checkFailures fileChecks
  let caseFailed ← ContractTest.caseFailures completions
  let displayFailed ← ContractTest.displayFailures
  let recorderContractFailed ← ContractTest.recorderFailures
  let recorderChecks := ContractTest.recorderChecks
  let recorderFailed ← ContractTest.checkFailures recorderChecks
  let clipboardFailed ← ContractTest.clipboardFailures
  let realClipboardFailed ← ContractTest.realClipboardFailures
  let clipboardChecks := ContractTest.clipboardChecks
  let clipboardCheckFailed ← ContractTest.checkFailures clipboardChecks
  let fuzzyFailed ← ContractTest.fuzzyFailures
  let styleFailed ← ContractTest.styleFailures
  let fuzzyChecks := ContractTest.fuzzyChecks
  let fuzzyCheckFailed ← ContractTest.checkFailures fuzzyChecks
  let syntaxTreeFailed ← ContractTest.syntaxTreeFailures
  let syntaxTreeChecks :=
    ContractTest.syntaxTreeChecks ++ ContractTest.syntaxFixtureChecks syntaxFixtures
  let syntaxTreeCheckFailed ← ContractTest.checkFailures syntaxTreeChecks
  let watchFailed ← ContractTest.watchFailures services.timers
  let watchChecks := ContractTest.watchChecks services.timers
  let watchCheckFailed ← ContractTest.checkFailures watchChecks
  let apiFailed ← ContractTest.apiFailures
  Editor.Ffi.quit
  let pumpEnded ← ContractTest.eventually (IO.hasFinished pump)
  let failed :=
    textFailed.map (s!"the real text binding: {·}") ++ pairCheckFailed ++ jobFailed ++ postFailed ++
      fileFailed ++
      processFailed ++
      processCheckFailed ++
      environmentFailed ++
      workspaceFailed ++
      modeMarkerFailed ++
      workspaceCheckFailed ++
      shellCheckFailed ++
      compileCheckFailed ++
      projectModeCheckFailed ++
      fileWatchFailed ++
      fileWatchCheckFailed ++
      checkFailed ++
      fileCheckFailed ++
      caseFailed ++
      displayFailed ++
      recorderContractFailed ++
      recorderFailed ++
      clipboardFailed ++
      realClipboardFailed ++
      clipboardCheckFailed ++
      fuzzyFailed ++
      styleFailed ++
      fuzzyCheckFailed ++
      syntaxTreeFailed ++
      syntaxTreeCheckFailed ++
      watchFailed ++
      watchCheckFailed ++
      apiFailed ++
      if pumpEnded then [] else ["quit ends the completion pump"]
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    IO.Process.exit 1
  IO.println
      s!"contract-test: {properties.length + adoptProperties.length} properties hold of the real text binding, {cases.length} cases of the undo tree hold over it, {pairChecks.length} check of its bracket walk against the text model passed, and its documents and snapshots are freed when released and with its table; {Editor.JobContract.properties.length} properties hold of the job runner over the timer service, and {Editor.JobContract.postProperties.length} post properties, and {Editor.JobContract.fileProperties.length} file properties over the file service, on real files, and {Editor.JobContract.processProperties.length} process properties over the process service, on real processes, with {processChecks.length} checks of the process service's adapter and {environmentChecks.length} of a child's environment over it, with mise standing in as a fixture, and {(Editor.Workspace.FinderContract.properties "/").length} properties of the workspace finder over the process and file services, with {workspaceChecks.length} checks of it, with git standing in as a fixture, and {(Editor.Workspace.MarkerContract.properties "/").length} properties of the mode marker search over the file service, and {shellChecks.length} checks of `:!` over the process service, and {compileChecks.length} of a compile, and {projectModeChecks.length} of the shipped modes with fixture programs, and {Editor.JobContract.fileWatchProperties.length} watch properties over the watch service, on real files, with {fileWatchChecks.length} checks of the watch service's adapter; {checks.length} checks of the timer service passed, {fileChecks.length} of the file service, {Editor.FileCases.cases.length} cases across the text port and the job port hold of the binding and the file service; {(Editor.DisplayContract.properties { advance := 1, lineHeight := 1 }).length} properties of the display interface hold of its real binding in cells of {ContractTest.displayCells.length} sizes, and of the recorder over real snapshots in cells of the same sizes, and {recorderChecks.length} checks of the recorder passed; {Editor.ClipboardContract.properties.length} properties of the clipboard interface hold of the in-process clipboard and of the real binding over the library's memory clipboard, and {clipboardChecks.length} checks of it passed; {Editor.FuzzyContract.properties.length} properties of the fuzzy matching interface hold of its real binding, {Editor.Completion.StyleContract.properties.length} properties of the completion styles hold of the fuzzy style over it, and {fuzzyChecks.length} check of a command's ranking passed; {Editor.SyntaxTreeContract.properties.length} properties of the syntax tree interface hold of its real binding over the library's syntax service, and {syntaxTreeChecks.length} checks of it passed; {Editor.WatchContract.properties.length} properties of the watch port hold of its real binding, and {watchChecks.length} checks of it passed; {Editor.ApiCases.cases.length} cases of the editor API hold of the real text binding; and quit ended the pump"
  (← IO.getStdout).flush
  IO.Process.exit 0
