import Editor.Command
import Editor.File
import Editor.Process

/-!
# Jobs

A job is work that may take as long as it likes: it may block or wait, and it
may not change editor state. A command (`EditorM`, `Editor/Command.lean`) is the
other half: it may change editor state and may not block. They are different
types, so that the type checker keeps each on its side
(`docs/design/concurrency.md`).

`JobM` is the type of programs over the job port, as `EditorM` is of programs
over the editor's port. The two ports share no request, so a text request is
not a job and a job is not a command. A program holds no `IO`, so neither can
smuggle one in.

## The port

A job reaches time through two requests:

- `now` reads the job clock, in milliseconds. The clock only says how far
  apart two readings are: where it starts is the clock's own business.
- `waitUntil deadline` returns once the clock reads `deadline` or later. A
  deadline that has passed returns at once.

`sleep` is written with those two, and so is a `Timer`, which is plain data:
the instant of its next tick and its period. A job may also fail: `JobM` has
an error layer of messages, so a job has `throw`, `try` and `catch`.

A job reaches files through one request, `file`, which carries a
`FileRequest` (`Editor/File.lean`): `File.load` loads a file and `File.save`
saves a snapshot as one. Each waits, as a wait on the clock does, and
replies with a result or a refusal: an `Except FileError`, a value, which
the job matches on. Nothing about a file ends a job or cancels it. A load
replies with the name of a snapshot the job then holds (`JobSnapshotId`):
the job can save it, and the job's command can take it into the text store
(`JobSnapshotId.adopt`), which a job cannot do, since that is a request of
the editor's port. Whatever runs the job releases what it holds once its
command has run, or when it fails or is cancelled.

A job reaches processes through one request, `process`, which carries a
`ProcessRequest` (`Editor/Process.lean`): `Process.run` runs a command to
its end and replies with how it ended and both its output streams, or a
refusal: an `Except ProcessError`, a value, which the job matches on.
`Process.start` starts a streaming child, which the job then reads
(`Process.read`, a delivery of lines or bytes at a time), writes to
(`Process.write`, `Process.writeLine`) and closes the input of
(`Process.closeInput`). A cancelled job's child is killed, with its process
group, by the library: the runner withdraws the wait, and withdrawing a
process wait cancels the run (`Editor/Job/Runner.lean`, "Cancellation"). A
streaming child does not outlive its job: the runner cancels it when the job
ends, however it ends.

No request carries a promise or a handle: a request is plain data. How a wait
is completed is the runner's business (`Editor/Job/Runner.lean`), not
something a job names.

## Cancellation is not a reply

A job is cancelled at a wait, and from outside: no request has a reply that
says "cancelled", and nothing is thrown into the job. A cancelled job's
continuation is never applied again, so a `try`/`catch` around a wait cannot
resume it, and it runs no cleanup of its own. What it ended as is an
`Job.Outcome`, which is the runner's and the model's to say, not the job's.

## Adding to the port

A new service a job can wait on is a constructor of `JobRequest` with its
case in `JobRequest.Reply`, and an operation here that makes the request.
It then needs a clause in the model (`JobModel.handle`,
`Editor/Job/Model.lean`), an answer in the runner, and a property in the
contract, which is what pins it for both. The file service is the example:
`JobRequest.file`, whose requests are their own type so that a new file
request is a constructor of `FileRequest` and not of this port
(`Editor/File.lean` says what it needs). The process service is the second:
`JobRequest.process`, whose requests are `ProcessRequest`s, so a stream read
as it comes is a constructor there and not here (`Editor/Process.lean`
says what it needs). Its model is `Editor/Process/Model.lean`, its fake
`FakeProcesses` and its real implementation `realProcesses`; withdrawing a
wait also tells the process service (`Handle.withdraw`), which is how a
cancelled job's child is killed.

## The pieces

- the port, here: the requests, the reply to each, the operations a job is
  written with, `Timer`, and `Work`, a job as it is spawned;
- the file requests as data, `Editor/File.lean`, and the pure model of the
  files a job reaches, `Editor/File/Model.lean`;
- the process requests as data, `Editor/Process.lean`, and the pure model of
  the processes a job runs, `Editor/Process/Model.lean`;
- its pure model, `Editor/Job/Model.lean`, which tests run against;
- its contract, `Editor/Job/Contract.lean`: three lists of properties, of
  the clock, of the file requests and of the process requests, run against
  the model and against the runner over a fake clock, a fake file service
  and a fake process service by `model-test`, and against the runner over
  the Rust library's services by `contract-test`;
- the runner, `Editor/Job/Runner.lean`, which runs a job on the pool, with
  the fakes of the clock port, of the file port and of the process port
  (`Editor/Job/Fake.lean`)
  and their real implementations (`Editor/Job/Real.lean`, the only job
  module that imports `Editor.Ffi`);
- the job table and the shell the editor thread calls,
  `Editor/Job/Table.lean` and `Editor/Job/Jobs.lean`;
- `Editor/Job/Pool.lean`, which warms the pool at start-up.

Config registers a job in `setup` (`Editor/Setup.lean`), which is why this
module, and not the runner, is what config sees.
-/

namespace Editor

/-- What a job may ask for while it runs. -/
inductive JobRequest where
  /-- The time on the job clock, in milliseconds. -/
  | now
  /-- Wait until the job clock reads `deadline` or later. -/
  | waitUntil (deadline : Nat)
  /-- Load a file or save one (`Editor/File.lean`), and wait for it. -/
  | file (request : FileRequest)
  /-- Run a process (`Editor/Process.lean`), and wait for it. -/
  | process (request : ProcessRequest)
  deriving DecidableEq, Repr

/-- The type of the reply to each request: the clock's reading for `now`,
nothing for a wait, and for a file or a process request its own reply, a
refusal or a result. No reply says a job was cancelled. -/
def JobRequest.Reply : JobRequest → Type
  | .now => Nat
  | .waitUntil _ => Unit
  | .file request => request.Reply
  | .process request => request.Reply

/-- The job port: `JobRequest` and the reply to each request. -/
abbrev jobPort : Port :=
  { Request := JobRequest, Reply := JobRequest.Reply }

/-- A job: a program over the job port that may fail with a message. It may
wait, and it cannot change editor state: the job port has no request that
does, and the editor's requests are not requests of it. -/
abbrev JobM :=
  ExceptT String (Program jobPort)

/-- The time on the job clock, in milliseconds. -/
def now : JobM Nat :=
  ExceptT.lift (Program.request (port := jobPort) .now)

/-- Waits until the job clock reads `deadline` or later. Returns at once if
it already does. -/
def waitUntil (deadline : Nat) : JobM Unit :=
  ExceptT.lift (Program.request (port := jobPort) (.waitUntil deadline))

/-- Waits for `duration` milliseconds on the job clock. -/
def sleep (duration : Nat) : JobM Unit := do
  waitUntil ((← now) + duration)

/-- A timer: plain data over the clock and the wait. It holds the instant of
its next tick, so its ticks are a period apart whatever the job does between
them: a tick waits until that instant, not for a period from now, and so a
timer does not drift with the work between its ticks. -/
structure Timer where
  /-- The instant of the next tick, on the job clock. -/
  next : Nat
  /-- How far apart the ticks are, in milliseconds. -/
  period : Nat
  deriving DecidableEq, Repr

/-- A timer that ticks every `period` milliseconds, the first time one period
from now. -/
def Timer.every (period : Nat) : JobM Timer :=
  return { next := (← now) + period, period }

/-- Waits for the timer's next tick, and returns the timer for the tick after
it. A tick whose instant has passed returns at once. -/
def Timer.tick (timer : Timer) : JobM Timer := do
  waitUntil timer.next
  return { timer with next := timer.next + timer.period }

/-- Loads the file at `path`, unless it is longer than `limit` bytes, and
waits for it: the file's text as a snapshot this job holds, its stamp and
its line endings, or why it was refused. The refusal is a value: the job
goes on. `Editor/File.lean` has the rules. -/
def File.load (path : System.FilePath) (limit : Nat) : JobM (Except FileError File.Loaded) :=
  ExceptT.lift (Program.request (port := jobPort) (.file (.load path limit)))

/-- Saves what `source` holds as the file at `path`, if what is on disk is
what `expect` says, and waits for it: the stamp of the file it wrote, or why
it was refused. The refusal is a value: the job goes on. `Editor/File.lean`
has the rules. -/
def File.save (source : File.Source) (path : System.FilePath) (expect : File.Expect) :
    JobM (Except FileError File.Stamp) :=
  ExceptT.lift (Program.request (port := jobPort) (.file (.save source path expect)))

/-- Runs `command` to its end and waits for it, collecting each output stream
unless it is longer than `limit` bytes: how the child ended and both its
streams, or why it was refused. The refusal is a value: the job goes on. A
cancelled job's child is killed, with its process group.
`Editor/Process.lean` has the rules. -/
def Process.run (command : Process.Command) (limit : Nat) :
    JobM (Except ProcessError Process.Ran) :=
  ExceptT.lift (Program.request (port := jobPort) (.process (.run command limit)))

/-- Starts `command` as a streaming child, as `streaming` says, and waits for
it to start: the child, named for this job, or why it was refused. The child
does not outlive the job. `Editor/Process.lean` has the rules. -/
def Process.start (command : Process.Command) (streaming : Process.Streaming) :
    JobM (Except ProcessError Process.Id) :=
  ExceptT.lift (Program.request (port := jobPort) (.process (.start command streaming)))

/-- Waits for the next delivery of `process`'s output: every frame read and
not yet taken, and in the last one how the child ended. -/
def Process.read (process : Process.Id) : JobM (Except ProcessError Process.Delivery) :=
  ExceptT.lift (Program.request (port := jobPort) (.process (.read process)))

/-- Writes `bytes` to `process`'s standard input, and waits until they are in
its pipe. -/
def Process.write (process : Process.Id) (bytes : ByteArray) : JobM (Except ProcessError Unit) :=
  ExceptT.lift (Program.request (port := jobPort) (.process (.write process bytes)))

/-- Writes `line` and a line feed to `process`'s standard input. -/
def Process.writeLine (process : Process.Id) (line : String) : JobM (Except ProcessError Unit) :=
  Process.write process (line.toUTF8.push 10)

/-- Closes `process`'s standard input: the child reads its end. -/
def Process.closeInput (process : Process.Id) : JobM (Except ProcessError Unit) :=
  ExceptT.lift (Program.request (port := jobPort) (.process (.closeInput process)))

namespace Job

/-- How a job ended. -/
inductive Outcome (α : Type) where
  /-- It ran to its end, with this value. -/
  | finished (value : α)
  /-- It threw this message. -/
  | failed (message : String)
  /-- It was cancelled, at a wait or before a request. Whatever it would have
  returned is lost. -/
  | cancelled
  deriving DecidableEq, Repr

end Job

/-- A job as it is spawned. It finishes with a command: the one that takes
its result to the editor, which the editor thread runs like any command. So
the type of a job's result never leaves the job, and the job port never
refers to the editor's.

It is a function, so that none of the job runs before the task that runs it
exists: the runner applies it on that task (`Job.spawn`,
`Editor/Job/Runner.lean`). -/
abbrev Work :=
  Unit → JobM (EditorM Unit)

/-- `job` as it is spawned, with `handler` making the command that receives
its result. The handler is applied where the job ends, on the job's thread,
which only builds the command: the command runs on the editor thread. -/
def Work.of {α : Type} (job : Unit → JobM α) (handler : α → EditorM Unit) : Work := fun token =>
  handler <$> job token

/-! ## The split, checked when this module is compiled

Each check below is an `example` that builds only while a violation of the
split is a type error. `fail_if_success` succeeds when the term in it fails to
elaborate, for whatever reason, so each check says the type the violation is
offered at, and the examples that come first show that a legal term is
accepted at each of those types, a wait among them. A check that still builds
with a legal term in place of its violation is offered at the wrong type.
Each of the checks of a wait was seen to bite once by hand: offered at
`JobM Unit`, where a wait is legal, the module stops building.

A text operation is a program over the text port (`TextM`), and a command
(`EditorM`) uses it through the lift of the editor's composite port
(`Editor/Command.lean`). So each check of a command is made at both: at
`TextM`, the type the operation has, and at `EditorM`, where the lift
exists. There is no lift from `JobM`. -/

example : True :=
  (fun (_ : JobM Unit) => True.intro) (pure ())

example : True :=
  (fun (_ : TextM Unit) => True.intro) ((⟨0⟩ : TextId).insert 0 "x")

example : True :=
  (fun (_ : EditorM Unit) => True.intro) ((⟨0⟩ : TextId).insert 0 "x")

example : True :=
  (fun (_ : EditorM Unit) => True.intro)
    (do
      (⟨0⟩ : TextId).insert 0 "x"
      Display.publish
          { size := ⟨0, 0⟩, views := #[], focused := none, echo := "", pending := ""
            preedit := none })

example : True :=
  (fun (_ : JobM Unit) => True.intro) (sleep 10)

/-! Taking a job's snapshot into the store (`JobSnapshotId.adopt`) is a
command, and it is not a job. It is the one request that writes the store
from what a job made, so a job cannot write the store with it: only the
job's command can, on the editor thread. Seen to bite once by hand: offered
at `EditorM SnapshotId` inside the second check, the module stops
building. -/

example : True :=
  (fun (_ : TextM SnapshotId) => True.intro) (⟨0⟩ : JobSnapshotId).adopt

example : True :=
  (fun (_ : EditorM SnapshotId) => True.intro) (⟨0⟩ : JobSnapshotId).adopt

example : True := by
  fail_if_success exact (fun (_ : JobM SnapshotId) => True.intro) (⟨0⟩ : JobSnapshotId).adopt
  trivial

/-! A text request is not a job: alone, and inside a `do` block. -/

example : True := by
  fail_if_success exact (fun (_ : JobM Unit) => True.intro) ((⟨0⟩ : TextId).insert 0 "x")
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : JobM Unit) => True.intro)
        (do
          let _ ← (⟨0⟩ : TextId).read
          pure ())
  trivial

/-! An `IO` action is not a job: alone, and inside a `do` block. -/

example : True := by
  fail_if_success exact (fun (_ : JobM Unit) => True.intro) (IO.sleep 10)
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : JobM Unit) => True.intro)
        (do
          IO.sleep 10
          pure ())
  trivial

/-! A display request is not a job either. -/

example : True := by
  fail_if_success
    exact
      (fun (_ : JobM Unit) => True.intro)
        (Display.publish
          { size := ⟨0, 0⟩, views := #[], focused := none, echo := "", pending := ""
            preedit := none })
  trivial

/-! An `IO` action is not a command, nor a program over the text port: alone,
and after a text request in a `do` block. -/

example : True := by
  fail_if_success exact (fun (_ : TextM Unit) => True.intro) (IO.sleep 10)
  trivial

example : True := by
  fail_if_success exact (fun (_ : EditorM Unit) => True.intro) (IO.sleep 10)
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : TextM Unit) => True.intro)
        (do
          (⟨0⟩ : TextId).insert 0 "x"
          IO.sleep 10)
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : EditorM Unit) => True.intro)
        (do
          (⟨0⟩ : TextId).insert 0 "x"
          IO.sleep 10)
  trivial

/-! A job is not a command, nor a program over the text port. -/

example : True := by
  fail_if_success exact (fun (_ : TextM Unit) => True.intro) (pure () : JobM Unit)
  trivial

example : True := by
  fail_if_success exact (fun (_ : EditorM Unit) => True.intro) (pure () : JobM Unit)
  trivial

/-! A file request is a job, and it is not a command: alone, and after a text
request in a `do` block. So a command cannot wait for a file. Seen to bite
once by hand: offered at `JobM (Except FileError File.Loaded)` inside the
first check, the module stops building. -/

example : True :=
  (fun (_ : JobM (Except FileError File.Loaded)) => True.intro) (File.load "/a" 1)

example : True := by
  fail_if_success
    exact (fun (_ : TextM (Except FileError File.Loaded)) => True.intro) (File.load "/a" 1)
  trivial

example : True := by
  fail_if_success
    exact (fun (_ : EditorM (Except FileError File.Loaded)) => True.intro) (File.load "/a" 1)
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : TextM Unit) => True.intro)
        (do
          (⟨0⟩ : TextId).insert 0 "x"
          discard <| File.save (.snapshot ⟨0⟩) "/a" .whatever)
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : EditorM Unit) => True.intro)
        (do
          (⟨0⟩ : TextId).insert 0 "x"
          discard <| File.save (.snapshot ⟨0⟩) "/a" .whatever)
  trivial

/-! A process request is a job, and it is not a command: alone, and after a
text request in a `do` block. So a command cannot run a program. Seen to
bite once by hand: offered at `JobM (Except ProcessError Process.Ran)`
inside the first `fail_if_success` check, the module stops building. -/

example : True :=
  (fun (_ : JobM (Except ProcessError Process.Ran)) => True.intro)
    (Process.run { program := "/bin/sh", directory := "/" } 1)

example : True := by
  fail_if_success
    exact
      (fun (_ : TextM (Except ProcessError Process.Ran)) => True.intro)
        (Process.run { program := "/bin/sh", directory := "/" } 1)
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : EditorM (Except ProcessError Process.Ran)) => True.intro)
        (Process.run { program := "/bin/sh", directory := "/" } 1)
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : TextM Unit) => True.intro)
        (do
          (⟨0⟩ : TextId).insert 0 "x"
          discard <| Process.run { program := "/bin/sh", directory := "/" } 1)
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : EditorM Unit) => True.intro)
        (do
          (⟨0⟩ : TextId).insert 0 "x"
          discard <| Process.run { program := "/bin/sh", directory := "/" } 1)
  trivial

/-! A streaming child's requests are a job's, and none is a command: a command
cannot start a child, read it or write to it. Seen to bite once by hand:
offered at `JobM (Except ProcessError Process.Id)` inside the first
`fail_if_success` check, the module stops building. -/

example : True :=
  (fun (_ : JobM (Except ProcessError Process.Id)) => True.intro)
    (Process.start { program := "/bin/sh", directory := "/" } { bound := 1 })

example : True := by
  fail_if_success
    exact
      (fun (_ : TextM (Except ProcessError Process.Id)) => True.intro)
        (Process.start { program := "/bin/sh", directory := "/" } { bound := 1 })
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : EditorM (Except ProcessError Process.Id)) => True.intro)
        (Process.start { program := "/bin/sh", directory := "/" } { bound := 1 })
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : EditorM (Except ProcessError Process.Delivery)) => True.intro) (Process.read ⟨1⟩)
  trivial

example : True := by
  fail_if_success
    exact (fun (_ : EditorM (Except ProcessError Unit)) => True.intro) (Process.writeLine ⟨1⟩ "x")
  trivial

example : True := by
  fail_if_success
    exact (fun (_ : TextM (Except ProcessError Unit)) => True.intro) (Process.closeInput ⟨1⟩)
  trivial

/-! A wait is not a command: alone, and after a text request in a `do` block.
So "a command may not block" is pinned beyond `IO`: the one way a program can
wait is a request of the job port, and a command cannot make it. -/

example : True := by
  fail_if_success exact (fun (_ : TextM Unit) => True.intro) (sleep 10)
  trivial

example : True := by
  fail_if_success exact (fun (_ : EditorM Unit) => True.intro) (sleep 10)
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : TextM Unit) => True.intro)
        (do
          (⟨0⟩ : TextId).insert 0 "x"
          sleep 10)
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : EditorM Unit) => True.intro)
        (do
          (⟨0⟩ : TextId).insert 0 "x"
          sleep 10)
  trivial

end Editor
