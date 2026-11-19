import Editor.Command.Real
import Editor.Job.Runner
import Editor.Text.Real

/-!
# The job runner's real services

The clock port, the file port, the process port and the file-watch port
(`Job.Timers`, `Job.Files`, `Job.Processes`, `Job.FileWatches`,
`Editor/Job/Runner.lean`) answered by the Rust library's timer service, its
file service, its process service and its watch service, and the completion
pump. This is the only job module that
imports `Editor.Ffi`, so only an executable linked with the library imports
it: the editor, and `contract-test`, which runs the job port's contract
against it.

## The clock

`realTimers` is a thin adapter: each operation of the port is one call of a
binding. A wait goes to the library as its id and its deadline, and the
library queues a completion with that id when the deadline has come.

- **Deadlines are machine words there.** The port's deadlines are `Nat`. One
  that no 64-bit word holds is clamped to the largest, never wrapped:
  wrapped, `2 ^ 64 + 1` is 1, a deadline in the past, and the wait would
  complete at once.
- **A wait the service refuses ends as `cancelled`.** The service refuses
  an id that is already waiting, or when it cannot start its thread. The
  job cannot go on without its wait, and must not wait for ever.

## The files

`realFiles` is a thin adapter over the bindings of the library's file
service. A request goes to the library with its wait's id, the library
queues a completion with that id when it has worked the request, and the
reply is then taken from the library by the id, once.

- **A load's snapshot is held here, for the job.** When a load's reply is
  taken, the library's snapshot goes into `HeldSnapshots` under the wait's
  id, which is the `JobSnapshotId` the reply carries: an id is a counter
  that is never used again in a process, so no two loads share one.
  `release` drops the entry, which frees the library's object unless a
  command adopted it into the text store, which then holds it too.
- **A save finds its snapshot by its source**: in `HeldSnapshots` for one
  the job loaded, and through the read half of the text store's published
  table (`SnapshotReader`, `Editor/Text/Real.lean`) for one a command took,
  as the table is when the save is started. The library keeps its own hold
  on the text, so the save is unaffected by a release that comes later.
- **It cannot write the text store's table: it is not given one.** It is
  given the read half. What a load makes enters the store only when the
  job's command adopts it, on the editor thread (`finishWith`).
- **A request that never reaches the library is completed here, at once**:
  a save whose source names no snapshot, whose reply is `noSuchSnapshot`,
  and a request the library's service does not take, whose reply is
  `failed`. The reply is kept until it is taken.
- **A stamp request** goes to the library as its path alone, and its reply
  is the stamp the library read, or none.
- **Numbers are machine words there.** A limit or a size no 64-bit word
  holds is sent as the largest, never wrapped.
- **Cancelling** a wait cancels the request at the library: one still
  waiting is never worked, a save being worked does not replace its file,
  and a result already kept is dropped.

## The processes

`realProcesses` is a thin adapter over the bindings of the library's
process service. A run goes to the library with its wait's id, as words and
one string; the library queues a completion with that id when the run has
come to something, and the reply is then taken from the library by the id,
once.

- **A run the library does not take is refused here, at once**, as
  `failed`: its id is in use there, or the service could not start its
  thread. The refusal is kept until it is taken (`RefusedRuns`), as
  `realFiles` keeps its own.
- **Numbers are machine words there.** A limit no 64-bit word holds is sent
  as the largest, never wrapped.
- **Cancelling** a wait cancels the run at the library, which kills the
  child's process group if it is running and reaps the child: that is how a
  cancelled job's child ends. A result already kept is dropped.
- **A refusal as shut down** becomes `failed` with the library's words: the
  editor shuts the service down only as it quits.
- **A run with a time limit** goes to the library as a run, and an alarm
  for its limit is armed on the clock (`timers`) under a wait of its own,
  kept in `TimedRuns`. When the alarm completes before the run is taken, the
  run is marked timed out and cancelled at the library, which kills the
  child's group and reaps it, and the run's wait is completed; its take
  answers `timedOut`. A take, and a cancel, disarm the alarm. The table is
  one atomic step for each change, so the alarm acts only on a run not yet
  taken. When a run ends just as its alarm completes, the alarm may come
  first, and the run is answered `timedOut`, its result dropped: harmless
  for a lookup, which falls back as it would for any failure.
- **A streaming child** goes to the library as an open under its start's
  wait's id, which names it from then on; a read, a write and a close each go
  with their own wait's id, and each reply is taken once
  (`Ffi.processesTakeStream`): a delivery's frames, written, or input closed.
  A request the library does not take is refused at once as `failed`, as a
  run is. Cancelling the child's id kills it; cancelling a read's or a
  write's withdraws that wait alone.

## The searches

`realGreps` is a thin adapter over the bindings of the library's grep
service, in `realFileWatches`'s shape. A start goes to the library under its
wait's id, which names the search from then on, with each overlay's source
resolved to a snapshot handle as a diff's is (`realDiffs`); a `next` goes
with its own wait's id, and each reply is taken once (`Ffi.grepTake`). A
start whose overlay names no snapshot, and a request the library does not
take, are refused here at once and the refusal kept until it is taken
(`RealGreps`). The walk's refusal of the root, which the library delivers as
the end of the first read, is that read's refusal.

## The file watches

`realFileWatches` is a thin adapter over the bindings of the library's watch
service. A start goes to the library under its wait's id, which names the
watch from then on; a `next` goes with its own wait's id, and each reply is
taken once (`Ffi.watchesTake`).

- **A request the library does not take is refused here, at once**, as
  `failed`, as a run is; the refusal is kept until it is taken
  (`RealWatches`).
- **Numbers are machine words there.** A window or a bound no 64-bit word
  holds is sent as the largest, never wrapped.
- **A path that is not UTF-8** is delivered as a change of the watch's own
  path with `missed`: the job is told that something changed which it
  cannot name. APFS refuses such names, so this happens only on Linux, or on
  a volume that is not APFS. The adapter keeps each watch's path for it.
- **A refusal as shut down** becomes `failed` with the library's words: the
  editor shuts the service down only as it quits.
- **Cancelling** the id of a watch ends it at the library, which drops its
  registration once no other watch shares it; cancelling a `next`'s id
  withdraws that wait alone.

`finishWith` is how a finished job's command is run: it hands the run what
the job held, then settles the job. The program it is handed is the
caller's: the headless host hands it the command loop's delivery of the
job's command (`Loop.deliver`, `Editor/Headless.lean`), with what its loop
watches, so the command is guarded against the library's interrupt flag as
a key's is, and with its clipboard, so the command reaches the clipboard a
key's does.

## The pump

`pump` is the one place completions come back in: a loop that pulls the
completion queue and, for each completion, ends the wait whose id it
carries (`Completions.finish`). It blocks in the library, so it runs on a
dedicated task, never one of the pool's, and there is one for the process's
one table of waits. Quitting the queues ends it. A completion carries an id
whichever service queued it, so the pump serves the timers, the files, the
processes and the file watches alike.

A completion for an id that is no longer waiting, because its job was
cancelled meanwhile, is dropped by the table.

## Tests

`contract-test` (`ContractTest.lean`), in the gate: the job port's contract
over these services, its file properties on real files in temporary
directories, its process properties on real processes in temporary
directories, its watch properties on real files in temporary directories,
and what only the real services can show, a cancelled job's child reaped and
a job's watch ended with it among them. `config-test`
(`ConfigTest.fileChecks`): a job that loads a file through the headless
host.
-/

namespace Editor.Job

/-- `deadline` as the library takes it: a 64-bit word, the largest there is
for a deadline no word holds. Converted without looking, such a deadline
would wrap round to an early one. -/
def word (deadline : Nat) : UInt64 :=
  (min deadline (UInt64.size - 1)).toUInt64

/-- The clock port answered by the library's timer service. `completions` is
the table its waits are registered in. -/
def realTimers (completions : Completions) : Timers :=
  { now := (return (← Ffi.timersNow).toNat : IO Nat).catchExceptions fun _ => pure 0
    start := fun id deadline => do
      let started ← (Ffi.timersStart id (word deadline)).catchExceptions fun _ => pure false
      -- Nothing will complete a wait the service did not take.
      unless started do
        completions.finish id .cancelled
    cancel := fun id =>
      (discard <| Ffi.timersCancel id : IO Unit).catchExceptions fun _ => pure () }

/-- The library's snapshots that jobs hold: what each load made, under the
`JobSnapshotId` its reply named. It is the runner's own state, like the
table of waits, and it is written off the editor thread, by the job's thread
that fetches a load's reply and by whoever settles a job. It is not the text
store's table, and nothing here can write that one. Every change is one
atomic step. -/
structure HeldSnapshots where private mk ::
  /-- The snapshots, by the number of their id. -/
  private slots : IO.Ref (Std.HashMap Nat Ffi.Snapshot)
  /-- The refusals of the file requests that never reached the library,
  which the file service's adapter completed itself, by the id of their
  wait, until their reply is fetched or their wait withdrawn. It is here
  because this is the state the adapter is handed. -/
  private refused : IO.Ref (Std.HashMap UInt64 FileError)

namespace HeldSnapshots

/-- A table that holds nothing. -/
def new : BaseIO HeldSnapshots :=
  return ⟨← IO.mkRef {}, ← IO.mkRef {}⟩

/-- Holds `snapshot` under `id`. -/
def put (held : HeldSnapshots) (id : JobSnapshotId) (snapshot : Ffi.Snapshot) : BaseIO Unit :=
  held.slots.modify (·.insert id.number snapshot)

/-- The library's snapshot held under `id`, if one is. -/
def find? (held : HeldSnapshots) (id : JobSnapshotId) : BaseIO (Option Ffi.Snapshot) :=
  return (← held.slots.get)[id.number]?

/-- Gives up what is held under `id`, if anything is: the library's object
is freed unless something else holds it, as the text store does once a
command has adopted it. -/
def release (held : HeldSnapshots) (id : JobSnapshotId) : BaseIO Unit :=
  held.slots.modify (·.erase id.number)

/-- How many snapshots are held. A readout for tests. -/
def size (held : HeldSnapshots) : BaseIO Nat :=
  return (← held.slots.get).size

end HeldSnapshots

/-- The port's form of a stamp of the library. -/
def stampOf (stamp : Ffi.FileStamp) : File.Stamp where
  seconds := stamp.seconds
  nanoseconds := stamp.nanoseconds.toNat
  size := stamp.size.toNat

/-- The library's form of what a save expects. A stamp's size that no 64-bit
word holds is sent as the largest, and its nanoseconds, of which the library
takes 32 bits, as the largest of those: neither is a number any file has, so
the library answers as the model does, that the file is not the one
expected, and nothing wraps round to a stamp a file might have. -/
def expectation : File.Expect → Ffi.FileExpect
  | .whatever => .whatever
  | .absent => .absent
  | .unchanged stamp =>
    .unchanged
      { seconds := stamp.seconds
        nanoseconds := (min stamp.nanoseconds 0xFFFFFFFF).toUInt64
        size := word stamp.size }

/-- The port's refusal for a refusal by the library. The platform's words
for a denial stay behind: the port's `denied` carries none. -/
def errorOf : Ffi.FileRefusal → FileError
  | .relativePath => .relativePath
  | .notFound => .notFound
  | .notAFile => .notAFile
  | .notADirectory => .notADirectory
  | .denied _ => .denied
  | .binary offset => .binary offset.toNat
  | .tooLarge size limit => .tooLarge size.toNat limit.toNat
  | .changed found => .changed (found.map stampOf)
  | .noTemporaryName => .noTemporaryName
  | .failed detail => .failed detail

/-- What a request is refused with when the library's service did not take
it: its id is in use there, or the service has no thread. -/
def notTaken : FileError :=
  .failed "the file service did not take the request"

/-- What a request is refused with when the library has no result for it of
the kind it asked for, though its wait completed. -/
def noResult : FileError :=
  .failed "the file service kept no result for the request"

/-- What there is for the wait `id`, which has completed: the refusal the
adapter kept for a request that never reached the library, or else what the
library hands over for it, once. A result the bindings cannot read is a
failure that says so. -/
def fetched (held : HeldSnapshots) (id : UInt64) : BaseIO (FileError ⊕ Option Ffi.FileResult) := do
  let refusal? ← held.refused.modifyGet fun refused => (refused[id]?, refused.erase id)
  match refusal? with
  | some refusal =>
    return .inl refusal
  | none =>
    (return .inr (← Ffi.filesTake id) : IO (FileError ⊕ Option Ffi.FileResult)).catchExceptions
        fun error => pure (.inl (.failed (toString error)))

/-- The reply to a load that was started as the wait `id`, which has
completed. A loaded snapshot is held under the wait's id, which is never
used again in a process, so it is the snapshot's name. -/
def takenLoad (held : HeldSnapshots) (id : UInt64) : BaseIO (Except FileError File.Loaded) := do
  match ← fetched held id with
  | .inl refusal =>
    return .error refusal
  | .inr (some (.loaded snapshot stamp lineFeeds crlfs)) =>
    let name : JobSnapshotId := ⟨id.toNat⟩
    held.put name snapshot
    return .ok
        { snapshot := name, stamp := stampOf stamp, endings := ⟨lineFeeds.toNat, crlfs.toNat⟩ }
  | .inr (some (.refused refusal)) =>
    return .error (errorOf refusal)
  | .inr _ =>
    return .error noResult

/-- The reply to a save that was started as the wait `id`, which has
completed. -/
def takenSave (held : HeldSnapshots) (id : UInt64) : BaseIO (Except FileError File.Stamp) := do
  match ← fetched held id with
  | .inl refusal =>
    return .error refusal
  | .inr (some (.saved stamp)) =>
    return .ok (stampOf stamp)
  | .inr (some (.refused refusal)) =>
    return .error (errorOf refusal)
  | .inr _ =>
    return .error noResult

/-- The reply to a stamp request that was started as the wait `id`, which
has completed. -/
def takenStamp (held : HeldSnapshots) (id : UInt64) :
    BaseIO (Except FileError (Option File.Stamp)) := do
  match ← fetched held id with
  | .inl refusal =>
    return .error refusal
  | .inr (some (.stamped stamp)) =>
    return .ok (stamp.map stampOf)
  | .inr (some (.refused refusal)) =>
    return .error (errorOf refusal)
  | .inr _ =>
    return .error noResult

/-- The port's kind of an entry's kind code from the library: 0 a file, 1 a
directory, anything else other. -/
def kindOf : UInt64 → File.Kind
  | 0 => .file
  | 1 => .directory
  | _ => .other

/-- The reply to a listing that was started as the wait `id`, which has
completed. -/
def takenList (held : HeldSnapshots) (id : UInt64) : BaseIO (Except FileError (Array File.Entry)) :=
  do
  match ← fetched held id with
  | .inl refusal =>
    return .error refusal
  | .inr (some (.listed entries)) =>
    return .ok (entries.map fun (name, kind) => { name, kind := kindOf kind })
  | .inr (some (.refused refusal)) =>
    return .error (errorOf refusal)
  | .inr _ =>
    return .error noResult

/-- The reply to `request`, which was started as the wait `id` and has
completed. -/
def taken (held : HeldSnapshots) (id : UInt64) : (request : FileRequest) → BaseIO request.Reply
  | .load .. => takenLoad held id
  | .save .. => takenSave held id
  | .stamp _ => takenStamp held id
  | .list _ => takenList held id

/-- The file port answered by the library's file service. `completions` is
the table its waits are registered in, `published` the read half of the text
store's table of snapshots, and `held` where what its loads make is kept. -/
def realFiles (completions : Completions) (published : SnapshotReader) (held : HeldSnapshots) :
    Files :=
  { start := fun id request => do
      match request with
      | .load path limit =>
        let started ←
          (Ffi.filesLoad id path.toString (word limit)).catchExceptions fun _ => pure false
        unless started do
          refuse id notTaken
      | .save source path expect =>
        let snapshot? ←
          match source with
          | .snapshot taken =>
            published.find? taken
          | .held loaded =>
            held.find? loaded
        match snapshot? with
        | none =>
          refuse id .noSuchSnapshot
        | some snapshot =>
          let started ←
            (Ffi.filesSave id snapshot path.toString (expectation expect)).catchExceptions fun _ =>
                pure false
          unless started do
            refuse id notTaken
      | .stamp path =>
        let started ← (Ffi.filesStamp id path.toString).catchExceptions fun _ => pure false
        unless started do
          refuse id notTaken
      | .list path =>
        let started ← (Ffi.filesList id path.toString).catchExceptions fun _ => pure false
        unless started do
          refuse id notTaken
    take := fun id request => taken held id request
    cancel := fun id => do
      held.refused.modify (·.erase id)
      (discard <| Ffi.filesCancel id : IO Unit).catchExceptions fun _ => pure ()
    release := held.release }
where
  /-- Completes the wait `id` at once, with `refusal` kept as what its take
  answers: for a request that never reaches the library. -/
  refuse (id : UInt64) (refusal : FileError) : BaseIO Unit := do
    held.refused.modify (·.insert id refusal)
    completions.finish id .completed

/-- The refusals of the diffs that never reached the library, which the diff
service's adapter completed itself, by the id of their wait, until their
reply is fetched or their wait withdrawn. Every change is one atomic step. -/
structure RefusedDiffs where private mk ::
  /-- The refusals, by the id of their wait. -/
  private refused : IO.Ref (Std.HashMap UInt64 DiffError)

/-- A table that holds no refusal. -/
def RefusedDiffs.new : BaseIO RefusedDiffs :=
  return ⟨← IO.mkRef {}⟩

/-- The snapshot reads of `JobRequest.snapshot`, answered from the read half
of the text store's table (`published`): the library's text of the
snapshot the table holds for the id now, read in the call (`Ffi.Snapshot.read`,
which reads a value that never changes, on the job's thread); `none` for an
id the table holds nothing for, and for a read the library refuses. -/
def realSnapshots (published : SnapshotReader) (id : SnapshotId) : BaseIO (Option String) := do
  let some snapshot ← published.find? id | return none
  match ← (Ffi.Snapshot.read snapshot).toBaseIO with
  | .ok text =>
    return some text
  | .error _ =>
    return none

/-- The port's form of a step of the library's script. -/
def stepOf : Ffi.ScriptStep → Diff.Step
  | .retain count => .retain count.toNat
  | .delete count => .delete count.toNat
  | .insert start count => .insert start.toNat count.toNat

/-- The port's form of a hunk of the library's answer. -/
def hunkOf (hunk : Ffi.HunkWords) : Diff.Hunk :=
  { oldStart := hunk.oldStart.toNat, oldStop := hunk.oldStop.toNat
    newStart := hunk.newStart.toNat, newStop := hunk.newStop.toNat }

/-- The diff port answered by the library's diff service. A source is found as
a save's is: in `held` for one the job loaded, and through the read half of
the text store's table (`published`) for one a command took, as the table is
when the diff is started; the library keeps its own hold on both texts. A
diff whose source names no snapshot, and one the library's service does not
take, never reaches the library: it is completed here, at once, with its
refusal kept in `refused` until it is taken. A limit no word holds is sent as
the largest. -/
def realDiffs (completions : Completions) (published : SnapshotReader) (held : HeldSnapshots)
    (refused : RefusedDiffs) : Diffs :=
  { start := fun id request => do
      let find (source : File.Source) : BaseIO (Option Ffi.Snapshot) :=
        match source with
        | .snapshot taken => published.find? taken
        | .held loaded => held.find? loaded
      let (old, new) := request.sources
      match ← find old, ← find new with
      | some old, some new =>
        let start :=
          match request with
          | .lines _ _ limit => Ffi.diffsStart id old new (word limit)
          | .hunks _ _ limit => Ffi.diffsStartHunks id old new (word limit)
        let started ← start.catchExceptions fun _ => pure false
        unless started do
          refuse id (.failed "the diff service did not take the request")
      | _, _ =>
        refuse id .noSuchSnapshot
    take := fun id request =>
      match request with
      | .lines .. => takeScript id
      | .hunks .. => takeHunks id
    cancel := fun id => do
      refused.refused.modify (·.erase id)
      (discard <| Ffi.diffsCancel id : IO Unit).catchExceptions fun _ => pure () }
where
  /-- Completes the wait `id` at once, with `refusal` kept as what its take
  answers. -/
  refuse (id : UInt64) (refusal : DiffError) : BaseIO Unit := do
    refused.refused.modify (·.insert id refusal)
    completions.finish id .completed
  /-- The refusal kept for the wait `id`, taken out of the table. -/
  refusalOf (id : UInt64) : BaseIO (Option DiffError) :=
    refused.refused.modifyGet fun table => (table[id]?, table.erase id)
  /-- The script of the wait `id`, or why there is none. -/
  takeScript (id : UInt64) : BaseIO (Except DiffError Diff.Script) := do
    if let some refusal← refusalOf id then
      return .error refusal
    let script? ←
      (return .ok (← Ffi.diffsTake id) :
              IO (Except String (Option (Array Ffi.ScriptStep)))).catchExceptions
          fun error => pure (.error (toString error))
    match script? with
    | .ok (some script) =>
      return .ok (script.map stepOf)
    | .ok none =>
      return .error (.failed "the diff service kept no script for the request")
    | .error detail =>
      return .error (.failed detail)
  /-- The hunks of the wait `id`, or why there are none. -/
  takeHunks (id : UInt64) : BaseIO (Except DiffError Diff.Hunks) := do
    if let some refusal← refusalOf id then
      return .error refusal
    let hunks? ←
      (return .ok (← Ffi.diffsTakeHunks id) :
              IO (Except String (Option (Array Ffi.HunkWords)))).catchExceptions
          fun error => pure (.error (toString error))
    match hunks? with
    | .ok (some hunks) =>
      return .ok (hunks.map hunkOf)
    | .ok none =>
      return .error (.failed "the diff service kept no hunks for the request")
    | .error detail =>
      return .error (.failed detail)

/-- The refusals of the process runs that never reached the library, which
the process service's adapter completed itself, by the id of their wait,
until their reply is fetched or their wait withdrawn. It is the runner's own
state, like the table of waits. Every change is one atomic step. -/
structure RefusedRuns where private mk ::
  /-- The refusals, by the id of their wait. -/
  private refused : IO.Ref (Std.HashMap UInt64 ProcessError)

/-- A table that holds no refusal. -/
def RefusedRuns.new : BaseIO RefusedRuns :=
  return ⟨← IO.mkRef {}⟩

/-- The port's form of how the library says a child ended. -/
def exitOf : Ffi.ProcessExit → Process.Exit
  | .code n => .code n.toNat
  | .signal n => .signal n.toNat

/-- The port's reply for a result of the library's process service. A
refusal as shut down is `failed` with its words: a job sees it only if it
runs a program while the editor is quitting. A cut run is answered only to a
run that keeps its head (`takenHead`); here it is a failure that says so. -/
def runReplyOf : Ffi.ProcessResult → Except ProcessError Process.Ran
  | .ran exit stdout stderr => .ok { exit := exitOf exit, stdout, stderr }
  | .relativeDirectory _ => .error .relativeDirectory
  | .relativeProgram _ => .error .relativeProgram
  | .notFound detail => .error (.notFound detail)
  | .denied detail => .error (.denied detail)
  | .outputTooLarge .out limit => .error (.outputTooLarge .out limit.toNat)
  | .outputTooLarge .err limit => .error (.outputTooLarge .err limit.toNat)
  | .shutDown detail => .error (.failed detail)
  | .failed detail => .error (.failed detail)
  | .cut _ _ => .error (.failed "the process service cut a run that did not ask for it")

/-- What a run is refused with when the library's service did not take it:
its id is in use there, or the service could not start its thread. -/
def runNotTaken : ProcessError :=
  .failed "the process service did not take the request"

/-- What a run is refused with when the library has no result for it, though
its wait completed. -/
def runNoResult : ProcessError :=
  .failed "the process service kept no result for the request"

/-- The reply to the run that was started as the wait `id`, which has
completed: the refusal the adapter kept for a run that never reached the
library, or else what the library hands over for it, once. A result the
bindings cannot read is a failure that says so. -/
def takenRun (refused : RefusedRuns) (id : UInt64) : BaseIO (Except ProcessError Process.Ran) := do
  let refusal? ← refused.refused.modifyGet fun refused => (refused[id]?, refused.erase id)
  if let some refusal := refusal? then
    return .error refusal
  let taken ←
    (return .ok (← Ffi.processesTake id) :
            IO (Except ProcessError (Option Ffi.ProcessResult))).catchExceptions
        fun error => pure (.error (.failed (toString error)))
  match taken with
  | .error refusal =>
    return .error refusal
  | .ok (some result) =>
    return runReplyOf result
  | .ok none =>
    return .error runNoResult

/-- The reply to the run that keeps its head that was started as the wait
`id`, which has completed, as `takenRun` takes a run's: a cut run is
`Process.Head.cut`, and one that ran to its end `Process.Head.whole`. -/
def takenHead (refused : RefusedRuns) (id : UInt64) : BaseIO (Except ProcessError Process.Head) :=
  do
  let refusal? ← refused.refused.modifyGet fun refused => (refused[id]?, refused.erase id)
  if let some refusal := refusal? then
    return .error refusal
  let taken ←
    (return .ok (← Ffi.processesTake id) :
            IO (Except ProcessError (Option Ffi.ProcessResult))).catchExceptions
        fun error => pure (.error (.failed (toString error)))
  match taken with
  | .error refusal =>
    return .error refusal
  | .ok (some (.cut stdout stderr)) =>
    return .ok (.cut stdout stderr)
  | .ok (some result) =>
    return (runReplyOf result).map .whole
  | .ok none =>
    return .error runNoResult

/-- The port's form of a stream's frames as the library delivered them. -/
def framesOf : Ffi.StreamFrames → Process.Frames
  | .lines lines => .lines lines
  | .bytes bytes => .bytes bytes

/-- The port's form of how the library says a streaming child ended. -/
def endOf : Ffi.StreamEnd → Process.End
  | .exited exit => .exited (exitOf exit)
  | .lineTooLong .out bound => .lineTooLong .out bound.toNat
  | .lineTooLong .err bound => .lineTooLong .err bound.toNat
  | .failed detail => .failed detail

/-- The refusal a reply about a streaming child is, if it is one: a refusal
as a run's is, input closed, or a reply of another request's kind, which is
a failure that says so. -/
def streamRefusalOf : Ffi.StreamReply → ProcessError
  | .refused result =>
    match runReplyOf result with
    | .error refusal => refusal
    | .ok _ => .failed "the process service answered a streaming request with a run's result"
  | .inputClosed detail => .inputClosed detail
  | _ => .failed "the process service answered with a reply of another request's kind"

/-- The reply about a streaming child that was asked for as the wait `id`,
which has completed: the refusal the adapter kept for a request that never
reached the library, or else what the library hands over, once. -/
def takenStream (refused : RefusedRuns) (id : UInt64) :
    BaseIO (Except ProcessError Ffi.StreamReply) := do
  let refusal? ← refused.refused.modifyGet fun refused => (refused[id]?, refused.erase id)
  if let some refusal := refusal? then
    return .error refusal
  let taken ←
    (return .ok (← Ffi.processesTakeStream id) :
            IO (Except ProcessError (Option Ffi.StreamReply))).catchExceptions
        fun error => pure (.error (.failed (toString error)))
  match taken with
  | .error refusal =>
    return .error refusal
  | .ok (some reply) =>
    return .ok reply
  | .ok none =>
    return .error runNoResult

/-- A run with a time limit while its alarm is armed: the alarm's wait, and
whether the alarm has ended the run. -/
structure TimedRun where
  /-- The wait of the alarm, on the clock. -/
  alarm : UInt64
  /-- Whether the alarm came before the run was taken, and killed it. -/
  timedOut : Bool := false

/-- The runs with a time limit whose alarm is armed, by the id of their wait.
It is the runner's own state, made beside `RefusedRuns`. Every change is one
atomic step, so "the alarm acts only on a run not yet taken" and "a take
marks it taken" exclude each other. -/
structure TimedRuns where private mk ::
  /-- The runs, by the id of their wait. -/
  private runs : IO.Ref (Std.HashMap UInt64 TimedRun)

namespace TimedRuns

/-- A table that holds no run. -/
def new : BaseIO TimedRuns :=
  return ⟨← IO.mkRef {}⟩

/-- Takes the run `id` out of the table, if it is there: it is no longer the
alarm's to end. -/
def take (timed : TimedRuns) (id : UInt64) : BaseIO (Option TimedRun) :=
  timed.runs.modifyGet fun runs => (runs[id]?, runs.erase id)

/-- Marks the run `id` timed out, if it is in the table and is not already:
whether it was marked by this call. -/
def expire (timed : TimedRuns) (id : UInt64) : BaseIO Bool :=
  timed.runs.modifyGet fun runs =>
    match runs[id]? with
    | some run =>
      if run.timedOut then (false, runs) else (true, runs.insert id { run with timedOut := true })
    | none => (false, runs)

/-- How many runs have an alarm armed. A readout for tests. -/
def size (timed : TimedRuns) : BaseIO Nat :=
  return (← timed.runs.get).size

end TimedRuns

/-- Disarms the alarm of a run with a time limit: the clock will not
complete it, and its wait ends as `cancelled`. -/
def disarm (completions : Completions) (timers : Timers) (run : TimedRun) : BaseIO Unit := do
  timers.cancel run.alarm
  completions.finish run.alarm .cancelled

/-- Arms the alarm of the run `id`, which the library has taken, for `time`
milliseconds on `timers`. When the alarm completes while the run is not yet
taken, the run is marked timed out, cancelled at the library, which kills
the child's group and reaps it, and its wait is completed: its take then
answers `timedOut`. -/
def arm (completions : Completions) (timers : Timers) (timed : TimedRuns) (id : UInt64)
    (time : Nat) : BaseIO Unit := do
  let (alarm, wait) ← completions.register
  timed.runs.modify (·.insert id { alarm })
  discard <|
      BaseIO.chainTask wait.result? fun completion => do
        if completion == some .completed then
          if ← timed.expire id then
            (discard <| Ffi.processesCancel id : IO Unit).catchExceptions fun _ => pure ()
            completions.finish id .completed
  timers.start alarm ((← timers.now) + time)

/-- The process port answered by the library's process service. `completions`
is the table its waits are registered in, `refused` where it keeps the
refusals of the requests that never reached the library, `timers` the clock
a run's time limit is measured on and `timed` where it keeps the runs whose
limit is armed. A streaming child is named by its start's wait, and each
read, write and close of it goes to the library with its own wait's id. -/
def realProcesses (completions : Completions) (refused : RefusedRuns) (timers : Timers)
    (timed : TimedRuns) : Processes :=
  { start := fun id request => do
      let started ←
        (match request with
                | .run command limit | .runWithin command limit _ =>
                  let environment := command.environment
                  Ffi.processesRun id command.program command.arguments environment.clear
                    environment.set environment.unset command.directory.toString (word limit)
                | .runInput command input limit _ =>
                  let environment := command.environment
                  Ffi.processesRunInput id command.program command.arguments environment.clear
                    environment.set environment.unset command.directory.toString (word limit) input
                | .runHead command input limit _ =>
                  let environment := command.environment
                  Ffi.processesRunHead id command.program command.arguments environment.clear
                    environment.set environment.unset command.directory.toString (word limit) input
                | .start command streaming =>
                  let environment := command.environment
                  Ffi.processesOpen id streaming.input (streaming.stdout == .bytes)
                    (streaming.stderr == .bytes) command.program command.arguments environment.clear
                    environment.set environment.unset command.directory.toString
                    (word streaming.bound)
                | .read child => Ffi.processesRead (word child.number) id
                | .write child bytes => Ffi.processesWrite (word child.number) id bytes
                | .closeInput child => Ffi.processesCloseInput (word child.number) id :
                IO Bool).catchExceptions
            fun _ => pure false
      if started then
        match request with
        | .runWithin _ _ time | .runInput _ _ _ time | .runHead _ _ _ time =>
          arm completions timers timed id time
        | _ =>
          pure ()
      else
        refused.refused.modify (·.insert id runNotTaken)
        completions.finish id .completed
    take := fun id request =>
      match request with
      | .run .. => takenRun refused id
      | .runWithin _ _ time | .runInput _ _ _ time => do
        match ← timed.take id with
        | some run =>
          disarm completions timers run
          if run.timedOut then
            return .error (.timedOut time)
          else
            takenRun refused id
        | none =>
          takenRun refused id
      | .runHead _ _ _ time => do
        match ← timed.take id with
        | some run =>
          disarm completions timers run
          if run.timedOut then
            return .error (.timedOut time)
          else
            takenHead refused id
        | none =>
          takenHead refused id
      | .start .. => do
        match ← takenStream refused id with
        | .ok .opened =>
          return .ok ⟨id.toNat⟩
        | .ok reply =>
          return .error (streamRefusalOf reply)
        | .error refusal =>
          return .error refusal
      | .read .. => do
        match ← takenStream refused id with
        | .ok (.delivered stdout stderr ended) =>
          return .ok
              { stdout := framesOf stdout, stderr := framesOf stderr, ended := ended.map endOf }
        | .ok reply =>
          return .error (streamRefusalOf reply)
        | .error refusal =>
          return .error refusal
      | .write .. | .closeInput .. => do
        match ← takenStream refused id with
        | .ok .written =>
          return .ok ()
        | .ok reply =>
          return .error (streamRefusalOf reply)
        | .error refusal =>
          return .error refusal
    cancel := fun id => do
      refused.refused.modify (·.erase id)
      if let some run← timed.take id then
        disarm completions timers run
      (discard <| Ffi.processesCancel id : IO Unit).catchExceptions fun _ => pure () }

/-- What the watch service's adapter keeps of its own: the refusals of the
requests that never reached the library, by the id of their wait, until
they are taken or withdrawn; and the path of each watch, by its id, for a
change whose path is not UTF-8. Every change is one atomic step. -/
structure RealWatches where private mk ::
  /-- The refusals, by the id of their wait. -/
  private refused : IO.Ref (Std.HashMap UInt64 FileWatchError)
  /-- Each watch's own path, by its id. -/
  private roots : IO.Ref (Std.HashMap UInt64 System.FilePath)

/-- A table that holds nothing. -/
def RealWatches.new : BaseIO RealWatches :=
  return ⟨← IO.mkRef {}, ← IO.mkRef {}⟩

/-- The port's refusal for the library's. A refusal as shut down is `failed`
with its words: a job sees it only if it watches while the editor quits. -/
def watchErrorOf : Ffi.WatchRefusal → String → FileWatchError
  | .notAbsolute, detail => .notAbsolute detail
  | .notFound, detail => .notFound detail
  | .notADirectory, detail => .notADirectory detail
  | .denied, detail => .denied detail
  | .limit, detail => .limit detail
  | .shutDown, detail => .failed detail
  | .failed, detail => .failed detail

/-- `changes` with `kinds` recorded at `path`: added to its change if it has
one, or a change of its own at the end. -/
def putChange (changes : Array FileWatch.Change) (path : System.FilePath)
    (kinds : FileWatch.Kinds) : Array FileWatch.Change :=
  match changes.findIdx? (·.path == path) with
  | some index =>
    changes.modify index fun change =>
      { change with
        kinds :=
          { created := change.kinds.created || kinds.created
            written := change.kinds.written || kinds.written
            renamed := change.kinds.renamed || kinds.renamed
            removed := change.kinds.removed || kinds.removed
            missed := change.kinds.missed || kinds.missed } }
  | none => changes.push { path, kinds }

/-- The port's changes for a delivery's paths and bits: a path that is not
UTF-8 is a change of `root`, the watch's own path, with `missed`. -/
def changesOf (root : System.FilePath) (raw : Array (ByteArray × UInt64)) :
    Array FileWatch.Change :=
  raw.foldl (init := #[]) fun changes (bytes, bits) =>
    match String.fromUTF8? bytes with
    | some path => putChange changes path (FileWatch.Kinds.ofBits bits.toNat)
    | none => putChange changes root { missed := true }

/-- What a watch request is refused with when the library's service did not
take it. -/
def watchNotTaken : FileWatchError :=
  .failed "the watch service did not take the request"

/-- What a watch request is refused with when the library kept no reply for
it, though its wait completed, or sent one of another request's kind. -/
def watchNoReply : FileWatchError :=
  .failed "the watch service kept no reply for the request"

/-- The library's reply to the wait `id`, which has completed: the refusal
the adapter kept for a request that never reached the library, or else what
the library hands over, once. -/
def takenWatch (state : RealWatches) (id : UInt64) :
    BaseIO (Except FileWatchError Ffi.WatchReply) := do
  let refusal? ← state.refused.modifyGet fun refused => (refused[id]?, refused.erase id)
  if let some refusal := refusal? then
    return .error refusal
  let taken ←
    (return .ok (← Ffi.watchesTake id) :
            IO (Except FileWatchError (Option Ffi.WatchReply))).catchExceptions
        fun error => pure (.error (.failed (toString error)))
  match taken with
  | .error refusal =>
    return .error refusal
  | .ok (some reply) =>
    return .ok reply
  | .ok none =>
    return .error watchNoReply

/-- The file-watch port answered by the library's watch service.
`completions` is the table its waits are registered in, and `state` what it
keeps of its own. A watch is named by its start's wait, and each `next` of
it goes to the library with its own wait's id. -/
def realFileWatches (completions : Completions) (state : RealWatches) : FileWatches :=
  { start := fun id request => do
      let started ←
        (match request with
                | .start target coalescing => do
                  state.roots.modify (·.insert id target.path)
                  let kind : UInt64 :=
                    match target with
                    | .file _ => 0
                    | .directory _ false => 1
                    | .directory _ true => 2
                  Ffi.watchesStart id kind (word coalescing.window) (word coalescing.bound)
                      target.path.toString
                | .next watch => Ffi.watchesNext (word watch.number) id :
                IO Bool).catchExceptions
            fun _ => pure false
      unless started do
        state.refused.modify (·.insert id watchNotTaken)
        completions.finish id .completed
    take := fun id request =>
      match request with
      | .start .. => do
        match ← takenWatch state id with
        | .ok .started =>
          return .ok ⟨id.toNat⟩
        | .ok (.refused refusal detail) =>
          state.roots.modify (·.erase id)
          return .error (watchErrorOf refusal detail)
        | .ok (.changes _) =>
          state.roots.modify (·.erase id)
          return .error watchNoReply
        | .error refusal =>
          state.roots.modify (·.erase id)
          return .error refusal
      | .next watch => do
        match ← takenWatch state id with
        | .ok (.changes raw) =>
          let root := ((← state.roots.get)[(word watch.number)]?).getD "/"
          return .ok (changesOf root raw)
        | .ok _ =>
          return .error watchNoReply
        | .error refusal =>
          return .error refusal
    cancel := fun id => do
      state.refused.modify (·.erase id)
      state.roots.modify (·.erase id)
      (discard <| Ffi.watchesCancel id : IO Unit).catchExceptions fun _ => pure () }

/-- What the grep service's adapter keeps of its own: the refusals of the
requests that never reached the library, by the id of their wait, until
they are taken or withdrawn. Every change is one atomic step. -/
structure RealGreps where private mk ::
  /-- The refusals, by the id of their wait. -/
  private refused : IO.Ref (Std.HashMap UInt64 GrepError)

/-- A table that holds nothing. -/
def RealGreps.new : BaseIO RealGreps :=
  return ⟨← IO.mkRef {}⟩

/-- The port's refusal for the library's. A refusal as shut down is `failed`
with its words: a job sees it only if it searches while the editor quits. -/
def grepErrorOf : Ffi.GrepRefusal → String → GrepError
  | .notAbsolute, detail => .notAbsolute detail
  | .notFound, detail => .notFound detail
  | .notADirectory, detail => .notADirectory detail
  | .denied, detail => .denied detail
  | .invalid, detail => .invalid detail
  | .shutDown, detail => .failed detail
  | .failed, detail => .failed detail

/-- What a search request is refused with when the library kept no reply for
it, though its wait completed, or sent one of another request's kind. -/
def grepNoReply : GrepError :=
  .failed "the grep service kept no reply for the request"

/-- The port's file for the library's: a path that is not UTF-8 is spelled a
character a byte, as no buffer can be named by it. -/
def foundOf (file : Ffi.GrepFile) : Grep.Found :=
  { path :=
      (String.fromUTF8? file.path).getD (String.ofList (file.path.toList.map (Char.ofNat ·.toNat)))
    origin := if file.buffer then .buffer else .disk
    found :=
      file.found.map fun (row, start, stop) =>
        { row := row.toNat, start := start.toNat, stop := stop.toNat } }

/-- The grep port answered by the library's grep service. An overlay's
source is found as a diff's is: in `held` for one the job loaded, and
through the read half of the text store's table (`published`) for one a
command took; the library keeps its own hold on each text. A start whose
overlay names no snapshot, and a request the library's service does not
take, never reach the library: they are completed here, at once, with their
refusal kept in `state` until it is taken. A search is named by its start's
wait, and each `next` of it goes to the library with its own wait's id.
Numbers no word holds are sent as the largest. -/
def realGreps (completions : Completions) (published : SnapshotReader) (held : HeldSnapshots)
    (state : RealGreps) : Greps :=
  { start := fun id request => do
      match request with
      | .start root pattern overlays limits bound =>
        let mut resolved := #[]
        for (path, source) in overlays do
          let found ←
            match source with
            | .snapshot taken =>
              published.find? taken
            | .held loaded =>
              held.find? loaded
          match found with
          | some snapshot =>
            resolved := resolved.push (path.toString, snapshot)
          | none =>
            return ← refuse id .noSuchSnapshot
        let started ←
          (Ffi.grepStart id root.toString pattern (word limits.files) (word limits.found)
                  (word bound) resolved).catchExceptions
              fun _ => pure false
        unless started do
          refuse id (.failed "the grep service did not take the request")
      | .next search =>
        let started ← (Ffi.grepNext (word search.number) id).catchExceptions fun _ => pure false
        unless started do
          refuse id (.failed "the grep service did not take the request")
    take := fun id request =>
      match request with
      | .start .. => do
        match ← taken id with
        | .ok .started =>
          return .ok ⟨id.toNat⟩
        | .ok (.refused refusal detail) =>
          return .error (grepErrorOf refusal detail)
        | .ok (.found ..) =>
          return .error grepNoReply
        | .error refusal =>
          return .error refusal
      | .next _ => do
        match ← taken id with
        | .ok (.found files ending) =>
          let found := files.map foundOf
          match ending with
          | .more =>
            return .ok { found, ended := none }
          | .complete fileCount matchCount =>
            return .ok { found, ended := some (.complete fileCount.toNat matchCount.toNat) }
          | .truncated fileCount matchCount =>
            return .ok { found, ended := some (.truncated fileCount.toNat matchCount.toNat) }
          | .refused refusal detail =>
            return .error (grepErrorOf refusal detail)
        | .ok _ =>
          return .error grepNoReply
        | .error refusal =>
          return .error refusal
    cancel := fun id => do
      state.refused.modify (·.erase id)
      (discard <| Ffi.grepCancel id : IO Unit).catchExceptions fun _ => pure () }
where
  /-- Completes the wait `id` at once, with `refusal` kept as what its take
  answers. -/
  refuse (id : UInt64) (refusal : GrepError) : BaseIO Unit := do
    state.refused.modify (·.insert id refusal)
    completions.finish id .completed
  /-- The library's reply to the wait `id`, which has completed: the refusal
  kept for a request that never reached the library, or else what the
  library hands over, once. -/
  taken (id : UInt64) : BaseIO (Except GrepError Ffi.GrepReply) := do
    let refusal? ← state.refused.modifyGet fun refused => (refused[id]?, refused.erase id)
    if let some refusal := refusal? then
      return .error refusal
    let reply ←
      (return .ok (← Ffi.grepTake id) :
              IO (Except GrepError (Option Ffi.GrepReply))).catchExceptions
          fun error => pure (.error (.failed (toString error)))
    match reply with
    | .error refusal =>
      return .error refusal
    | .ok (some reply) =>
      return .ok reply
    | .ok none =>
      return .error grepNoReply

/-- Runs `command`, the command a finished job ended with or a program that
runs it, against the Rust library on the editor thread, with `display`
answering its display requests and `watch` its watch requests, and then
settles the job: its result, or the refusal it failed with, and the table
after its last request.

The run is handed what the job held: the ids its handle lists, each with the
library's snapshot `held` has for it, so the command can take one into the
store (`JobSnapshotId.adopt`). The job has ended, so nothing else writes its
list. The job is settled whatever the command did, and what the command
adopted outlives that: the store holds the library's object too.

`watch` is what a guard in the program asks. By default nothing is watched
(`Watch.idle`), as for any command run where no loop dispatched it; a host
whose loop delivers the command hands in what its loop watches.

`clipboard` answers the program's clipboard requests. By default there is
none (`Clipboard.unavailable`), as for any command run where no host handed
one in; a host hands in the clipboard its loop's commands reach.

`syntaxTree` answers the program's syntax tree requests. By default there is
none (`SyntaxTree.none`, which has no grammars), as for any command run
where no host handed one in; a host hands in the one its loop's commands
reach, so a job's command that sets a major mode with a syntax attaches and
highlights its text as a key's command does. -/
def finishWith {α : Type} (held : HeldSnapshots) (handle : Handle) (command : EditorM α)
    (texts : RealTexts) (display : DisplayHandler) (watch : WatchHandler := Watch.idle)
    (clipboard : ClipboardHandler := Clipboard.unavailable)
    (syntaxTree : SyntaxTreeHandler := SyntaxTree.none) : IO (Except TextError α × RealTexts) := do
  let arrived ← (← handle.holding).filterMapM fun id => return (← held.find? id).map (id, ·)
  try
    command.runReal texts display arrived watch clipboard syntaxTree
  finally
    handle.settle

/-- The completion pump: pulls the completion queue and ends the wait each
completion names, until the queues are quit. It blocks in the library: run it
on a dedicated task. -/
def pump (completions : Completions) : IO Unit := do
  repeat
    let event ← Ffi.nextEvent .completion
    if event.kind == .quit then
      break
    if event.kind == .completion then
      completions.finish event.code .completed

end Editor.Job
