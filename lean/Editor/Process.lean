/-!
# Processes, as a job asks for them

The data of the process requests a job can make: run a command to its end
and collect what it wrote. It is plain data and imports nothing. The
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
- **What a run answers** (`Process.Ran`): how the child ended, by a status
  or a signal, and its standard output and standard error as bytes, kept as
  they were written.
- **A cancelled job's child is killed**, with every process it started that
  is still in its process group. The editor's shutdown kills and reaps every
  child the library started. A descendant that leaves the group (`setsid`,
  a daemon) is not reached: `docs/design/rust-library.md` keeps that limit
  as an open question.
- **Errors are values.** A reply is an `Except ProcessError`: a program that
  cannot be started is `notFound` or `denied`, with the platform's words,
  and the job matches on it and goes on, or throws `ProcessError.describe`
  of it, as it chooses. Nothing about a process cancels a job or ends it.

## Adding to this

A new process request (a child with a stream that is read as it comes, or
with its standard input open) is a constructor of `ProcessRequest` with its
case in `ProcessRequest.Reply`, and an operation in `Editor/Job.lean`. It
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

/-- What a run to its end answers. -/
structure Ran where
  /-- How the child ended. -/
  exit : Exit
  /-- What it wrote to its standard output. -/
  stdout : ByteArray
  /-- What it wrote to its standard error. -/
  stderr : ByteArray
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
  | .failed detail => s!"the process request failed: {detail}"

/-- What a job may ask of processes. A new process request is a constructor
here. -/
inductive ProcessRequest where
  /-- Run `command` to its end, collecting each stream unless it is longer
  than `limit` bytes. -/
  | run (command : Process.Command) (limit : Nat)
  deriving DecidableEq, Repr

/-- The type of the reply to each process request: a refusal or the result.
A refusal is a value, never a throw. -/
def ProcessRequest.Reply : ProcessRequest → Type
  | .run .. => Except ProcessError Process.Ran

end Editor
