import Editor.Command.Real
import Editor.Ffi
import Editor.Job.Runner
import Editor.Text.Real

/-!
# The job runner's real services

The clock port, the file port and the process port (`Job.Timers`,
`Job.Files`, `Job.Processes`, `Editor/Job/Runner.lean`) answered by the Rust
library's timer service, its file service and its process service, and the
completion pump. This is the only job module that
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
- **A streaming child** goes to the library as an open under its start's
  wait's id, which names it from then on; a read, a write and a close each go
  with their own wait's id, and each reply is taken once
  (`Ffi.processesTakeStream`): a delivery's frames, written, or input closed.
  A request the library does not take is refused at once as `failed`, as a
  run is. Cancelling the child's id kills it; cancelling a read's or a
  write's withdraws that wait alone.

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
whichever service queued it, so the pump serves the timers, the files and
the processes alike.

A completion for an id that is no longer waiting, because its job was
cancelled meanwhile, is dropped by the table.

## Tests

`contract-test` (`ContractTest.lean`), in the gate: the job port's contract
over these services, its file properties on real files in temporary
directories, its process properties on real processes in temporary
directories, and what only the real services can show, a cancelled job's
child reaped among them. `config-test`
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
runs a program while the editor is quitting. -/
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

/-- The process port answered by the library's process service. `completions`
is the table its waits are registered in, and `refused` where it keeps the
refusals of the requests that never reached the library. A streaming child
is named by its start's wait, and each read, write and close of it goes to
the library with its own wait's id. -/
def realProcesses (completions : Completions) (refused : RefusedRuns) : Processes :=
  { start := fun id request => do
      let started ←
        (match request with
                | .run command limit =>
                  let environment := command.environment
                  Ffi.processesRun id command.program command.arguments environment.clear
                    environment.set environment.unset command.directory.toString (word limit)
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
      unless started do
        refused.refused.modify (·.insert id runNotTaken)
        completions.finish id .completed
    take := fun id request =>
      match request with
      | .run .. => takenRun refused id
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
      (discard <| Ffi.processesCancel id : IO Unit).catchExceptions fun _ => pure () }

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
one in; a host hands in the clipboard its loop's commands reach. -/
def finishWith {α : Type} (held : HeldSnapshots) (handle : Handle) (command : EditorM α)
    (texts : RealTexts) (display : DisplayHandler) (watch : WatchHandler := Watch.idle)
    (clipboard : ClipboardHandler := Clipboard.unavailable) : IO (Except TextError α × RealTexts) :=
  do
  let arrived ← (← handle.holding).filterMapM fun id => return (← held.find? id).map (id, ·)
  try
    command.runReal texts display arrived watch clipboard
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
