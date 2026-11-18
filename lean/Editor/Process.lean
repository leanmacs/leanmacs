/-!
# Processes, as a job asks for them

The data of the process requests a job can make: run a command to its end
and collect what it wrote, or start it as a streaming child, whose output
reaches the job as it comes and whose standard input the job writes to. It is
plain data and imports nothing. The
requests themselves are requests of the job port (`Editor/Job.lean`,
`JobRequest.process`): a command may not wait and a job may, so running a
program is a thing a job does, and the operation a job is written with,
`Process.run`, is there.

Starting, waiting for, killing and reaping a child are the library's
(`crates/editor-process`, its service over the real adapter in
`crates/editor-process-std`). Lean never spawns, signals or reaps a process.

## The rules

- **A command** (`Process.Command`) is a program, its arguments, the
  environment the child gets and the directory it runs in. The program is a
  bare name, looked up on the `PATH` of the environment the child gets, or
  an absolute path. The directory must be absolute, since the editor has no
  working directory: a directory that is not is refused with
  `relativeDirectory`, and a program that names a directory without being
  absolute with `relativeProgram`, before anything is started. Strings are
  UTF-8, as Lean's are.
- **The environment** (`Process.Environment`) is the editor's own, emptied
  first if `clear` is set, then with `unset` removed, then with `set`
  applied.
- **A run** (`ProcessRequest.run`) starts the command with its standard
  input closed, collects both its output streams whole, and waits for it to
  end. It carries a limit, in bytes, for each stream: what the limit is is
  the editor's policy, and there is no default. A stream past it ends the
  run with `outputTooLarge`, and the child's process group is killed: output
  is never cut short, which a parser would misread.
- **A run with a time limit** (`ProcessRequest.runWithin`) is a run whose
  child, with its process group, is killed and reaped if it has not ended
  that many milliseconds after it was started, and which then answers
  `timedOut`. The limit is measured on the job clock. A run that ends just
  as its limit comes may be answered either way.
- **A fed run** (`ProcessRequest.runInput`) is a run with a time limit
  whose child's standard input is a pipe: the library writes the input to
  it, on a thread of its own while it reads the output, and then closes it,
  so the child reads the input and then end of file. Input larger than a
  pipe holds cannot hold a child that writes as it reads. A child that
  does not read its input, or not all of it, is no refusal: the run
  answers what the child did. It is how a filter feeds lines to a command
  (`Editor/Shell.lean`).
- **A run that keeps its head** (`ProcessRequest.runHead`) is a fed run
  whose standard output past its limit is not refused: the library keeps
  exactly its first `limit` bytes, kills the child's group, and the run
  answers `Process.Head.cut` with them and what was read of standard error.
  How the child ended is not said, since the library ended it. Standard
  error past the limit is still `outputTooLarge`, and a run whose output
  stays within the limit answers `Process.Head.whole`. It is how a filter
  that prints every candidate for an empty query is read
  (`Editor/Completion/Filtering.lean`).
- **What a run answers** (`Process.Ran`): how the child ended, by a status
  or a signal, and its standard output and standard error as bytes, kept as
  they were written.
- **A cancelled job's child is killed**, with every process it started that
  is still in its process group. The editor's shutdown kills and reaps every
  child the library started. A descendant that leaves the group (`setsid`,
  a daemon) is not reached: `docs/design/rust-library.md` keeps that limit
  as an open question.
- **A streaming child** (`ProcessRequest.start`) is started with
  `Process.Streaming`: whether its standard input is a pipe, how each output
  stream reaches the job, as lines or as raw bytes (`Process.Framing`), and
  its bound. The reply names the child (`Process.Id`) for the job that
  started it: a read, a write or a close of an id the job does not hold is
  `noSuchProcess` at once, with nothing asked of the library.
- **Lines** split on `\n`. A line excludes its `\n` and keeps a `\r` before
  it; at a stream's end the bytes after its last `\n` are a last line. A job
  that must know whether a stream ended in a line feed asks for bytes, whose
  deliveries end to end are the stream byte for byte.
- **A read** (`ProcessRequest.read`) waits for the next delivery
  (`Process.Delivery`): every frame of both streams read and not yet taken.
  However fast the child writes, the job gets one delivery a read, and one
  a turn of the completion queue: the library completes a read once, never
  once a chunk.
- **The bound** is how many bytes of each stream may have been read from the
  child and not yet taken, a line in progress among them: the editor's
  policy, with no default, and at least one. A child at it is **held**: its
  output is not read, so it waits in its own write until the job reads.
  Nothing is dropped, and no delivery says it was held. A line longer than
  the bound, its line feed counted, can never be delivered whole: it ends
  the child, its group killed, with `lineTooLong`, the frames before it
  intact. A last line exactly the bound long, with no line feed, is
  delivered whole.
- **A child that pauses** between two lines, for however long, has the
  first delivered alone, with no end: a read waits for whatever comes next,
  and gives what there is. So a job sees output before its child ends, which
  is what the compile mode streams (`Editor/Compile.lean`). The model has a
  step for it (`Process.Step.pause`, `Editor/Process/Model.lean`).
- **The last delivery** says how the child ended (`Process.End`): `exited`
  once both streams have ended and every frame is in it. The child is then
  forgotten: a later read of it is `noSuchProcess`.
- **A write** (`ProcessRequest.write`) waits until every byte is in the
  child's standard input, or is `inputClosed`: at once if the child has no
  input or the job closed it, and when the child closed it or ended.
  `closeInput` closes it.
- **A child does not outlive its job.** However the job ends, finished
  included, the runner cancels every child it still holds, which kills the
  child's process group.
- **Errors are values.** A reply is an `Except ProcessError`: a program that
  cannot be started is `notFound` or `denied`, with the platform's words,
  and the job matches on it and goes on, or throws `ProcessError.describe`
  of it, as it chooses. Nothing about a process cancels a job or ends it.

## Adding to this

A new process request (killing a streaming child, or waiting for its exit
alone) is a constructor of `ProcessRequest` with its case in
`ProcessRequest.Reply`, and an operation in `Editor/Job.lean`. It
needs a clause in the model (`ProcessModel.handle`,
`Editor/Process/Model.lean`), in the fake and the real process service of
the job runner (`Editor/Job/Fake.lean`, `Editor/Job/Real.lean`), and a
property in the job port's contract (`JobContract.processProperties`), which
is what pins it for all three. A new refusal is a constructor of
`ProcessError` with its sentence in `ProcessError.describe`.
-/

namespace Editor

namespace Process

/-- The environment a child gets: the editor's own, emptied first if `clear`
is set, then with `unset` removed, then with `set` applied. -/
structure Environment where
  /-- Whether the editor's environment is emptied first. -/
  clear : Bool := false
  /-- Each variable and the value it is given, applied last. -/
  set : Array (String × String) := #[]
  /-- Each variable removed, before `set` is applied. -/
  unset : Array String := #[]
  deriving DecidableEq, Repr

/-- What to start. -/
structure Command where
  /-- A bare name, looked up on the `PATH` the child gets, or an absolute
  path. -/
  program : String
  /-- The arguments, after the program's own name. -/
  arguments : Array String := #[]
  /-- The environment the child gets. -/
  environment : Environment := {}
  /-- The directory the child runs in: an absolute path. -/
  directory : System.FilePath
  deriving DecidableEq, Repr

/-- Whether `command`'s program names a directory without being absolute: a
command every process service refuses with `ProcessError.relativeProgram`
before anything is started. This is the rule, and the model and the editor's
lookup (`Process.prepared`) both ask it. -/
def Command.namesRelative (command : Command) : Bool :=
  command.program.contains '/' && !command.program.startsWith "/"

/-- How a child ended. -/
inductive Exit where
  /-- It exited with this status. -/
  | code (n : Nat)
  /-- It was ended by this signal. -/
  | signal (n : Nat)
  deriving DecidableEq, Repr

/-- One of a child's output streams. -/
inductive Stream where
  /-- Its standard output. -/
  | out
  /-- Its standard error. -/
  | err
  deriving DecidableEq, Repr

/-- A streaming child, as the job that started it names it: the id of the
wait its start was, which is never used again in a process. It is the job's:
another job's requests cannot name it. -/
structure Id where
  /-- The number. -/
  number : Nat
  deriving DecidableEq, Repr, Hashable

/-- How one of a streaming child's output streams reaches its job. -/
inductive Framing where
  /-- As lines, split on `\n`: a line excludes its `\n` and keeps a `\r`
  before it, and at the stream's end the bytes after the last `\n` are a last
  line. -/
  | lines
  /-- As raw bytes, with arbitrary boundaries. -/
  | bytes
  deriving DecidableEq, Repr

/-- How a streaming child is started. -/
structure Streaming where
  /-- Whether its standard input is a pipe the job writes to; closed when it
  is not. -/
  input : Bool := false
  /-- How its standard output reaches the job. -/
  stdout : Framing := .lines
  /-- How its standard error reaches the job. -/
  stderr : Framing := .lines
  /-- How many bytes of each stream may have been read from the child and not
  yet taken by the job, a line in progress among them: the editor's policy,
  with no default. At least one. -/
  bound : Nat
  deriving DecidableEq, Repr

/-- What a delivery holds of one stream. -/
inductive Frames where
  /-- Whole lines, each without its `\n`. -/
  | lines (lines : Array ByteArray)
  /-- Bytes. -/
  | bytes (bytes : ByteArray)
  deriving DecidableEq

/-- How a streaming child ended, as its last delivery says. -/
inductive End where
  /-- Both streams ended, every frame was delivered and the child exited so. -/
  | exited (exit : Exit)
  /-- A line of `stream` was longer than `bound`, so could never be delivered
  whole, and the child's group was killed. -/
  | lineTooLong (stream : Stream) (bound : Nat)
  /-- A read of its streams failed, and its group was killed. -/
  | failed (detail : String)
  deriving DecidableEq, Repr

/-- What a read of a streaming child answers: every frame of both streams
read and not yet taken, and, in the last one, how the child ended. -/
structure Delivery where
  /-- Its standard output's frames. -/
  stdout : Frames
  /-- Its standard error's frames. -/
  stderr : Frames
  /-- How it ended, in its last delivery only. -/
  ended : Option End := none
  deriving DecidableEq

/-- What a run to its end answers. -/
structure Ran where
  /-- How the child ended. -/
  exit : Exit
  /-- What it wrote to its standard output. -/
  stdout : ByteArray
  /-- What it wrote to its standard error. -/
  stderr : ByteArray
  deriving DecidableEq

/-- What a run that keeps its head answers (`ProcessRequest.runHead`). -/
inductive Head where
  /-- The child ended with its output within the limit: what a run answers. -/
  | whole (ran : Ran)
  /-- Standard output went past the limit, and the child's group was killed:
  exactly its first `limit` bytes, and what was read of standard error.
  Output of exactly `limit` bytes is not cut: it answers `whole`. -/
  | cut (stdout stderr : ByteArray)
  deriving DecidableEq

end Process

/-- Why a run was refused, or did not come to an end with its output. -/
inductive ProcessError where
  /-- The directory is not absolute. -/
  | relativeDirectory
  /-- The program names a directory and is not absolute. -/
  | relativeProgram
  /-- The program, or the directory, is not there; `detail` says which
  were asked for. -/
  | notFound (detail : String)
  /-- The platform does not allow it; `detail` is its words. -/
  | denied (detail : String)
  /-- `stream` had more than the run's `limit` of bytes, and the child's
  group was killed. -/
  | outputTooLarge (stream : Process.Stream) (limit : Nat)
  /-- The child's standard input is closed: none was asked for, the job closed
  it, or the child closed it or ended. -/
  | inputClosed (detail : String)
  /-- No streaming child of the job's has this id: another job's, or one whose
  last delivery has been taken. -/
  | noSuchProcess
  /-- The run did not end within its time limit of `limit` milliseconds, and
  the child's group was killed. -/
  | timedOut (limit : Nat)
  /-- Anything else; `detail` says what. -/
  | failed (detail : String)
  deriving DecidableEq, Repr

/-- What a refusal says, as a sentence for a person: for a job that wants to
throw one. -/
def ProcessError.describe : ProcessError → String
  | .relativeDirectory => "the directory is not absolute"
  | .relativeProgram => "the program names a directory and is not absolute"
  | .notFound detail => s!"the program or the directory is not there: {detail}"
  | .denied detail => s!"the system does not allow it: {detail}"
  | .outputTooLarge .out limit => s!"the standard output was over the limit of {limit} bytes"
  | .outputTooLarge .err limit => s!"the standard error was over the limit of {limit} bytes"
  | .inputClosed detail => s!"the child's standard input is closed: {detail}"
  | .noSuchProcess => "the job has no such process"
  | .timedOut limit => s!"the run did not end within {limit} ms and was killed"
  | .failed detail => s!"the process request failed: {detail}"

/-- What a job may ask of processes. A new process request is a constructor
here. -/
inductive ProcessRequest where
  /-- Run `command` to its end, collecting each stream unless it is longer
  than `limit` bytes. -/
  | run (command : Process.Command) (limit : Nat)
  /-- Run `command` as `run` does, but kill it, with its group, if it has not
  ended `time` milliseconds after it was started. -/
  | runWithin (command : Process.Command) (limit : Nat) (time : Nat)
  /-- Run `command` as `runWithin` does, with `input` as its standard input,
  followed by end of file. -/
  | runInput (command : Process.Command) (input : ByteArray) (limit : Nat) (time : Nat)
  /-- Run `command` as `runInput` does, but keep the first `limit` bytes of its
  standard output, and end the child there, instead of refusing it. -/
  | runHead (command : Process.Command) (input : ByteArray) (limit : Nat) (time : Nat)
  /-- Start `command` as a streaming child, as `streaming` says: the child,
  named for the job. -/
  | start (command : Process.Command) (streaming : Process.Streaming)
  /-- Wait for the next delivery of `process`'s output. -/
  | read (process : Process.Id)
  /-- Write `bytes` to `process`'s standard input, and wait until they are in
  its pipe. -/
  | write (process : Process.Id) (bytes : ByteArray)
  /-- Close `process`'s standard input. -/
  | closeInput (process : Process.Id)
  deriving DecidableEq

/-- A request as a test prints it: a write's bytes, and a fed run's input, by
their count, since `ByteArray` has no `Repr`. -/
instance : Repr ProcessRequest where
  reprPrec request _ :=
    match request with
    | .run command limit => "ProcessRequest.run " ++ repr command ++ " " ++ repr limit
    | .runWithin command limit time =>
      "ProcessRequest.runWithin " ++ repr command ++ " " ++ repr limit ++ " " ++ repr time
    | .runInput command input limit time =>
      "ProcessRequest.runInput " ++ repr command ++ s!" ({input.size} bytes) " ++ repr limit ++
        " " ++
        repr time
    | .runHead command input limit time =>
      "ProcessRequest.runHead " ++ repr command ++ s!" ({input.size} bytes) " ++ repr limit ++
        " " ++
        repr time
    | .start command streaming => "ProcessRequest.start " ++ repr command ++ " " ++ repr streaming
    | .read process => "ProcessRequest.read " ++ repr process
    | .write process bytes => "ProcessRequest.write " ++ repr process ++ s!" ({bytes.size} bytes)"
    | .closeInput process => "ProcessRequest.closeInput " ++ repr process

/-- The type of the reply to each process request: a refusal or the result.
A refusal is a value, never a throw. -/
def ProcessRequest.Reply : ProcessRequest → Type
  | .run .. => Except ProcessError Process.Ran
  | .runWithin .. => Except ProcessError Process.Ran
  | .runInput .. => Except ProcessError Process.Ran
  | .runHead .. => Except ProcessError Process.Head
  | .start .. => Except ProcessError Process.Id
  | .read .. => Except ProcessError Process.Delivery
  | .write .. => Except ProcessError Unit
  | .closeInput .. => Except ProcessError Unit

/-- The reply to `request` that refuses it with `error`, whatever the
request: for a service that answers without asking anyone. -/
def ProcessRequest.refused (error : ProcessError) : (request : ProcessRequest) → request.Reply
  | .run .. => .error error
  | .runWithin .. => .error error
  | .runInput .. => .error error
  | .runHead .. => .error error
  | .start .. => .error error
  | .read .. => .error error
  | .write .. => .error error
  | .closeInput .. => .error error

end Editor
