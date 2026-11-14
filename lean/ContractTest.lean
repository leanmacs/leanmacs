import Editor.Command.Model
import Editor.Command.Real
import Editor.Display.Contract
import Editor.Display.Recorder
import Editor.Event.Queue
import Editor.File.Cases
import Editor.InputScheme.Test
import Editor.Job.Contract
import Editor.Job.Fake
import Editor.Job.Pool
import Editor.Job.Real
import Editor.Key.Notation
import Editor.Loop
import Editor.Text.Contract
import Editor.Text.Model
import Editor.Text.Real
import Editor.UndoTree.Cases
import Editor.Watch.Contract
import Editor.Watch.Real

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
- The cases of the undo tree (`Editor/UndoTree/Cases.lean`), which is plain
  Lean over the text port, through the same binding and in the same run, so
  the count of live documents covers the texts they make. `model-test` runs
  them against the text model.
- The job port's contract (`Editor/Job/Contract.lean`) against the runner
  over the library's timer service, with the completion pump
  (`Editor/Job/Real.lean`). `model-test` runs it against the model and
  against the runner over the fake clock.
- The job port's file properties (`JobContract.fileProperties`) against the
  runner over the library's file service, on real files
  (`runFilesOnService`, `fileFailures`). Each property has a temporary
  directory of its own, made here, handed to its job as a path, read back
  when the job has ended and removed whatever happened; no file is touched
  anywhere else. `model-test` runs the same list against the model of files
  and against the runner over the fake of the file service.

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
against the recorder a host with no window answers it with
(`Editor/Display/Recorder.lean`), over snapshots the library made, at the
two cell sizes `model-test` runs it at against the model
(`displayFailures`). `recorderChecks` pins what only the recorder shows:
that it keeps and counts what is published, and that it reads the table of
snapshots as it is when asked.

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

/-- The names of the job port's file properties that do not hold of the
runner over the library's file service, on real files. `fileLeakName` is
among them if the library then holds a snapshot more than before, `held`
still holds one, or the file service has a request or a result left. -/
def fileFailures (services : Job.Services) (held : Job.HeldSnapshots) : IO (List String) := do
  let before := (← Ffi.Snapshot.live, ← Ffi.filesPending)
  let failed ← JobContract.fileFailures (runFilesOnService services) JobContract.fileProperties
  let freed ←
    eventually do
        return (← Ffi.Snapshot.live, ← Ffi.filesPending) == before && (← held.size) == 0
  let after := (← Ffi.Snapshot.live, ← Ffi.filesPending, ← held.size)
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

/-- The cell sizes the display interface's contract is run at against the
recorder: the two `model-test` runs it at against the model. -/
def displayCells : List Display.Cells :=
  [{ advance := 1, lineHeight := 1 }, { advance := 8, lineHeight := 16 }]

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
def displayFailures : IO (List String) :=
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

end ContractTest

/-- Runs the text port's contract against its real binding, then the job
port's contract and the job checks against the runner over the library's
timer service, the display interface's against the recorder and the watch
port's against its real binding, then shuts down: exits 0 when everything
holds, and 1 after naming on stderr what does not.

The pool's threads are learnt first, by warming it, before anything else
runs: the check that the pump is not one of the pool's tasks compares
against them. Then the completion pump runs on a dedicated task for the rest
of the run. Shutdown is quit, which must end the pump, then an explicit
exit: a task that failed a check may still be blocked in the library. -/
def main : IO UInt32 := do
  let pool ← Editor.Job.Pool.whole ContractTest.warmPatience
  let completions ← Editor.Job.Completions.new
  -- No command of this run publishes a snapshot to these services: the file
  -- properties save what their own jobs loaded.
  let published ← Editor.Snapshots.new
  let held ← Editor.Job.HeldSnapshots.new
  let services : Editor.Job.Services :=
    { completions, timers := Editor.Job.realTimers completions
      files := Editor.Job.realFiles completions published.reader held }
  let pump ← IO.asTask (prio := .dedicated) (Editor.Job.pump completions)
  let properties := Editor.TextContract.properties
  -- The undo tree's cases run through the same binding, so the count of
  -- live documents covers the texts they make too.
  let cases := Editor.UndoTreeCases.cases
  let adoptProperties := Editor.TextContract.adoptProperties
  let textFailed ← ContractTest.failures (properties ++ cases) adoptProperties
  let jobFailed ← ContractTest.jobFailures services
  let fileFailed ← ContractTest.fileFailures services held
  -- The job checks first: the last of them measures the pool, which a later
  -- check must not have grown.
  let checks := ContractTest.jobChecks services pool
  let checkFailed ← ContractTest.checkFailures checks
  let fileChecks := ContractTest.fileChecks completions
  let fileCheckFailed ← ContractTest.checkFailures fileChecks
  let caseFailed ← ContractTest.caseFailures completions
  let displayFailed ← ContractTest.displayFailures
  let recorderChecks := ContractTest.recorderChecks
  let recorderFailed ← ContractTest.checkFailures recorderChecks
  let watchFailed ← ContractTest.watchFailures services.timers
  let watchChecks := ContractTest.watchChecks services.timers
  let watchCheckFailed ← ContractTest.checkFailures watchChecks
  Editor.Ffi.quit
  let pumpEnded ← ContractTest.eventually (IO.hasFinished pump)
  let failed :=
    textFailed.map (s!"the real text binding: {·}") ++ jobFailed ++ fileFailed ++ checkFailed ++
      fileCheckFailed ++
      caseFailed ++
      displayFailed ++
      recorderFailed ++
      watchFailed ++
      watchCheckFailed ++
      if pumpEnded then [] else ["quit ends the completion pump"]
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    IO.Process.exit 1
  IO.println
      s!"contract-test: {properties.length + adoptProperties.length} properties hold of the real text binding, {cases.length} cases of the undo tree hold over it, and its documents and snapshots are freed when released and with its table; {Editor.JobContract.properties.length} properties hold of the job runner over the timer service, and {Editor.JobContract.fileProperties.length} file properties over the file service, on real files; {checks.length} checks of the timer service passed, {fileChecks.length} of the file service, {Editor.FileCases.cases.length} cases across the text port and the job port hold of the binding and the file service; {(Editor.DisplayContract.properties { advance := 1, lineHeight := 1 }).length} properties of the display interface hold of the recorder over real snapshots in cells of {ContractTest.displayCells.length} sizes, and {recorderChecks.length} checks of the recorder passed; {Editor.WatchContract.properties.length} properties of the watch port hold of its real binding, and {watchChecks.length} checks of it passed; and quit ended the pump"
  (← IO.getStdout).flush
  IO.Process.exit 0
