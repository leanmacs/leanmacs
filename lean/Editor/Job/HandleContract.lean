import Editor.InferredWait
import Editor.Job.Runner

/-!
# The contract of a file request's handle

What `Services.fileWorked` (`Editor/Job/Runner.lean`) does over a file port,
as a list of properties of its own: a handle is not a job request, so it is
not in the job port's contract (`Editor/Job/Contract.lean`). Each property
runs on a `HandleRig`, which gives the services, a directory to write in,
how to hold the file service's work until the rig lets it go, and what the
service still keeps of the requests handed to it. The same list runs two
ways:

- against the fake file service (`FakeFiles`, `Editor/Job/Fake.lean`), by
  `model-test` (`ModelTest.handleContractChecks`), held by its held
  completions (`holdCompletions`, `letGo`);
- against the real file port over the Rust library (`realFiles`,
  `Editor/Job/Real.lean`), by `contract-test`
  (`ContractTest.handleContractChecks`), held by the file service's
  in-process hold (`ContractTest/Support/FileHold.lean`).

What a handle promises is that its reply is seen through it and through
nothing else: the reply is taken from the service when the request's wait
ends, whether or not the task is still held, so a dropped task leaves the
service keeping nothing, and a held one ends with the reply.

Two properties pin the host's activity count over the port
(`Editor/Job/Runner.lean`, "Activity"), each on a count of its own: a
handle's request holds a unit from its start until its `noted` has run
(`handleCounts`), and a job's load holds the job's unit while the service
holds it (`jobLoadCounts`). The count's end is waited for on its own change,
never on time.

**A deadline here is a hang guard, never a result**: a task is awaited with
`Job.awaitWithin`, and one that has not ended within `patience` is reported
as a hang. That a task has *not* ended while the service's work is held is
read once, with `IO.hasFinished`, while the rig holds it: nothing can end
the request then, so a handle that ends at its call is seen every time.

This module imports only the runner's ports. The list is plain data, so it
is a constant: nothing in it calls a service when the module is initialised.
-/

namespace Editor.HandleContract

open Editor.Job

/-- The guard of the task's end, a handle's or a flush's, which must come;
only a hang reaches it, and the property then fails as a hang. -/
def patience : HangGuard :=
  .on "the task's end, a handle's or a flush's" 10000

/-- The file port a handle is made over, as the contract runs it. -/
structure HandleRig where
  /-- Which port, as a failure names it. -/
  name : String
  /-- The services, the file port among them. -/
  services : Services
  /-- A directory that is there, which the properties write in, each under
  a name of its own. -/
  directory : System.FilePath
  /-- The bytes of the file at a path, or `none` when no file is there. -/
  read : System.FilePath → IO (Option ByteArray)
  /-- Holds the service's work from now on, so nothing handed to it is
  worked until the rig lets it go, and gives back how to let it go. -/
  held : IO (IO Unit)
  /-- How much the service still keeps of the requests handed to it: what
  it holds until a reply is taken or a wait withdrawn. -/
  kept : IO Nat
  /-- Whether the service has said a request's outcome anywhere but its
  reply: `false` for a service with no such readout. -/
  leaked : IO Bool := pure false

/-- One property of a handle: whether it holds on a rig, or why not, thrown. -/
structure Property where
  /-- What must hold, as a sentence. -/
  name : String
  /-- Observes it on a rig. -/
  holds : HandleRig → IO Bool

/-- `task`'s value, or a hang thrown when it has not ended within
`patience`. -/
def awaited {α : Type} (what : String) (task : Task α) : IO α := do
  let some value ←
    awaitWithin patience
        task | throw <| IO.userError s!"a hang: {what} had not ended within {patience.ms} ms"
  return value

/-- Flushes the rig's file service and waits for the flush: every request
handed to it before has been worked, and its wait ended, once this returns. -/
def HandleRig.flushedFiles (rig : HandleRig) : IO Unit := do
  let ended ← awaited "the flush of the files" (← rig.services.flushed .files)
  unless ended == .completed do
    throw <| IO.userError "the flush of the files was cancelled"

/-- What a reply that comes to nothing came to, said for a failure. -/
def saidUnit : Except FileError Unit → String
  | .ok () => "done"
  | .error error => error.describe

/-- With the service's work held, two appends handed through handles, one
into a directory that is not there and one into the rig's, have not ended;
let go, the first ends `notFound` and the second done, with its bytes in
the file; and once the service is flushed it keeps nothing of either, and
said neither outcome anywhere else. -/
def heldSeenOnlyThroughHandle : Property where
  name :=
    "a request held behind the service's work has not ended while it is held; let go, its handle ends with its reply, and the service keeps nothing of it and says it nowhere else"
  holds rig := do
    let before ← rig.kept
    let release ← rig.held
    let missing ← rig.services.fileWorked (.append (rig.directory / "none" / "log") "x".toUTF8)
    let written ← rig.services.fileWorked (.append (rig.directory / "held-log") "y".toUTF8)
    let early := (← IO.hasFinished missing) || (← IO.hasFinished written)
    release
    let missingReply : Except FileError Unit ← awaited "the append into no directory" missing
    let writtenReply : Except FileError Unit ← awaited "the append" written
    rig.flushedFiles
    let after ← rig.kept
    let leaked ← rig.leaked
    let bytes ← rig.read (rig.directory / "held-log")
    let missingFailed :=
      match missingReply with
      | .error .notFound => true
      | _ => false
    let writtenDone :=
      match writtenReply with
      | .ok () => true
      | _ => false
    unless
      !early && missingFailed && writtenDone && bytes == some "y".toUTF8 && after == before &&
        !leaked do
      throw <|
          IO.userError
            s!"a handle had {if early then "ended" else "not ended"} while the work was held; the append into no directory came to {saidUnit missingReply} and the append to {saidUnit writtenReply}, the file holding {bytes.map String.fromUTF8?}; the service kept {after}, {before} before, and {if leaked then "said an outcome elsewhere" else "said none elsewhere"}"
    return true

/-- `noted` has the reply by the time the task ends: a map of the task run
on the thread that ends it reads what `noted` was handed. -/
def notedBeforeEnd : Property where
  name := "what a handle hands to `noted` is there by the time its task has ended"
  holds rig := do
    let seen ← IO.mkRef (none : Option String)
    let task ←
      rig.services.fileWorked (.append (rig.directory / "noted-log") "n".toUTF8) (noted :=
          fun reply => seen.set (some (saidUnit reply)))
    let read ← BaseIO.mapTask (sync := true) (fun (_ : Except FileError Unit) => seen.get) task
    let atEnd ← awaited "the noted append" read
    rig.flushedFiles
    unless atEnd == some "done" do
      throw <| IO.userError s!"when the task ended, `noted` had been handed {atEnd}"
    return true

/-- A handle dropped at once still has its reply taken when its wait ends:
once the service is flushed it keeps nothing of the request, and the
request was worked. -/
def dropped : Property where
  name :=
    "a request whose handle is dropped at once is worked, and once the service is flushed it keeps nothing of it"
  holds rig := do
    let before ← rig.kept
    let release ← rig.held
    discard <| rig.services.fileWorked (.append (rig.directory / "dropped-log") "z".toUTF8)
    release
    rig.flushedFiles
    let after ← rig.kept
    let bytes ← rig.read (rig.directory / "dropped-log")
    unless after == before && bytes == some "z".toUTF8 do
      throw <|
          IO.userError
            s!"the service kept {after}, {before} before, and the file held {bytes.map String.fromUTF8?}"
    return true

/-- A snapshot no table holds: what a refused save names. -/
def unheld : SnapshotId :=
  ⟨1000000007⟩

/-- A save naming a snapshot the service does not hold ends `noSuchSnapshot`,
and the service keeps nothing of it. -/
def refusedAtStart : Property where
  name :=
    "a save naming a snapshot the service does not hold ends with `noSuchSnapshot`, and the service keeps nothing of it"
  holds rig := do
    let before ← rig.kept
    let task ←
      rig.services.fileWorked (.save (.snapshot unheld) (rig.directory / "refused") .whatever)
    let reply : Except FileError File.Stamp ← awaited "the refused save" task
    rig.flushedFiles
    let after ← rig.kept
    let refused :=
      match reply with
      | .error .noSuchSnapshot => true
      | _ => false
    unless refused && after == before do
      let said :=
        match reply with
        | .ok _ => "saved"
        | .error error => error.describe
      throw <|
          IO.userError s!"the save came to {said}, and the service kept {after}, {before} before"
    return true

/-- The rig's services keeping a count of their activity of their own
(`Activity.counting`), and that count. -/
def HandleRig.counted (rig : HandleRig) : BaseIO (Services × Activity) := do
  let activity ← Activity.counting
  return ({ rig.services with activity }, activity)

/-- `changedAfter` is an inferred wait (`Editor/InferredWait.lean`). -/
def changedAfter.inferredWait : InferredWait :=
  .count [`Editor.Job.Runner, `Editor.Job.Activity]

/-- The count `activity` reads at its next change after `seen`, waited for on
the change itself; a hang thrown past `patience`. -/
def changedAfter (activity : Activity) (seen : Activity.Seen) : IO Activity.Seen := do
  discard <| awaited s!"a change of the count from {repr seen}" (← activity.changedSince seen.epoch)
  activity.seen

/-- A handle's request holds a unit of the host's activity from its start
until its `noted` has run: one while the service's work is held, one when
`noted` is handed the reply, and none at the count's next change. -/
def handleCounts : Property where
  name :=
    "a handle's request holds a unit of the host's activity from its start, while the service holds it and when `noted` is handed its reply, and none once it has ended"
  holds rig := do
    let (services, activity) ← rig.counted
    let atNoted ← IO.mkRef (none : Option Nat)
    let release ← rig.held
    let task ←
      services.fileWorked (.append (rig.directory / "counted-log") "c".toUTF8) (noted := fun _ => do
          atNoted.set (some (← activity.seen).running))
    let held ← activity.seen
    release
    let ended ← changedAfter activity held
    let reply : Except FileError Unit ← awaited "the counted append" task
    rig.flushedFiles
    let noted ← atNoted.get
    unless
      held.running == 1 && noted == some 1 && ended.running == 0 && (← activity.refused) == 0 do
      throw <|
          IO.userError
            s!"the count read {held.running} with the request held, {noted} at `noted` and {ended.running} once it had ended, the append coming to {saidUnit reply}"
    return true

/-- A job's load on the file port holds the job's unit while the service
holds the load, and none once the service has been let go and the job has
ended. -/
def jobLoadCounts : Property where
  name :=
    "a job's load holds the job's unit of the host's activity while the service holds it, and none once it has been let go and the job has ended"
  holds rig := do
    let (services, activity) ← rig.counted
    let started ← IO.Promise.new
    let services :=
      { services with
        files :=
          { services.files with
            start := fun id request => do
              services.files.start id request
              started.resolve () } }
    let release ← rig.held
    let job : Work :=
      Work.of (fun _ => File.load (rig.directory / "no-such-file") 100) fun _ => pure ()
    let handle ← spawn services job (pure ())
    try
      discard <| awaited "the load's start" started.result?
      let held ← activity.seen
      release
      let ended ← changedAfter activity held
      let outcome ← awaited "the job" handle.outcome.result?
      handle.settle
      rig.flushedFiles
      let finished :=
        match outcome with
        | some (.finished _) => true
        | _ => false
      unless held.running == 1 && ended.running == 0 && finished && (← activity.refused) == 0 do
        throw <|
            IO.userError
              s!"the count read {held.running} with the load held and {ended.running} once the job had ended, the job {if finished then "finished" else "not finished"}"
      return true
    finally
      handle.cancel
      release

/-- H-order: with the service's work held, two requests handed through
handles have not ended; let go, the first's reply is noted before the
second's: the service answers in the order it was handed requests, which
the stepped fake promises and the real service's one in-order worker must
keep. The order is read on the thread that ends each task, in the order
they end. -/
def handedOrder : Property where
  name :=
    "two requests handed through handles while the service's work is held have not ended; let go, the first's reply is noted before the second's"
  holds rig := do
    let release ← rig.held
    let first ← rig.services.fileWorked (.append (rig.directory / "order-first") "a".toUTF8)
    let second ← rig.services.fileWorked (.append (rig.directory / "order-second") "b".toUTF8)
    let early := (← IO.hasFinished first) || (← IO.hasFinished second)
    let log ← IO.mkRef (#[] : Array String)
    let firstNoted ← BaseIO.mapTask (sync := true) (fun _ => log.modify (·.push "first")) first
    let secondNoted ← BaseIO.mapTask (sync := true) (fun _ => log.modify (·.push "second")) second
    release
    awaited "the first request's reply" firstNoted
    awaited "the second request's reply" secondNoted
    let order ← log.get
    unless !early && order == #["first", "second"] do
      throw <|
          IO.userError
            s!"while held a reply had {if early then "ended" else "not ended"}; let go they were noted in the order {order}"
    return true

/-- Every property, in the order they run. -/
def properties : List Property :=
  [heldSeenOnlyThroughHandle, notedBeforeEnd, dropped, refusedAtStart, handleCounts, jobLoadCounts,
    handedOrder]

/-- Runs every property on each of `rigs`, and returns the failures, each
named `<rig>: <property>`, with what it saw. -/
def failures (rigs : List HandleRig) : IO (List String) := do
  let mut failed := []
  for rig in rigs do
    for property in properties do
      let name := s!"{rig.name}: {property.name}"
      try
        unless ← property.holds rig do
          failed := failed ++ [name]
      catch error =>
        failed := failed ++ [s!"{name} ({error})"]
  return failed

end Editor.HandleContract
