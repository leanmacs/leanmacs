import Editor.Command.Real
import Editor.Ffi
import Editor.Job.Runner
import Editor.Text.Real

/-!
# The job runner's real services

The clock port and the file port (`Job.Timers`, `Job.Files`,
`Editor/Job/Runner.lean`) answered by the Rust library's timer service and
its file service, and the completion pump. This is the only job module that
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
- **Numbers are machine words there.** A limit or a size no 64-bit word
  holds is sent as the largest, never wrapped.
- **Cancelling** a wait cancels the request at the library: one still
  waiting is never worked, a save being worked does not replace its file,
  and a result already kept is dropped.

`finishWith` is how a finished job's command is run: it hands the run what
the job held, then settles the job. The program it is handed is the
caller's: the headless host hands it the command loop's delivery of the
job's command (`Loop.deliver`, `Editor/Headless.lean`), with what its loop
watches, so the command is guarded against the library's interrupt flag as
a key's is.

## The pump

`pump` is the one place completions come back in: a loop that pulls the
completion queue and, for each completion, ends the wait whose id it
carries (`Completions.finish`). It blocks in the library, so it runs on a
dedicated task, never one of the pool's, and there is one for the process's
one table of waits. Quitting the queues ends it. A completion carries an id
whichever service queued it, so the pump serves the timers and the files
alike.

A completion for an id that is no longer waiting, because its job was
cancelled meanwhile, is dropped by the table.

## Tests

`contract-test` (`ContractTest.lean`), in the gate: the job port's contract
over these services, its file properties on real files in temporary
directories, and what only the real services can show. `config-test`
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

/-- The reply to `request`, which was started as the wait `id` and has
completed. -/
def taken (held : HeldSnapshots) (id : UInt64) : (request : FileRequest) → BaseIO request.Reply
  | .load .. => takenLoad held id
  | .save .. => takenSave held id

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
whose loop delivers the command hands in what its loop watches. -/
def finishWith {α : Type} (held : HeldSnapshots) (handle : Handle) (command : EditorM α)
    (texts : RealTexts) (display : DisplayHandler) (watch : WatchHandler := Watch.idle) :
    IO (Except TextError α × RealTexts) := do
  let arrived ← (← handle.holding).filterMapM fun id => return (← held.find? id).map (id, ·)
  try
    command.runReal texts display arrived watch
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
