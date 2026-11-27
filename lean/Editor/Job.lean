import Editor.Command
import Editor.Diff
import Editor.File
import Editor.FileWatch
import Editor.Grep
import Editor.PackageService
import Editor.Process
import Editor.Process.Environment
import Editor.SyntaxTree.Registration
import Editor.UrlOpener

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
`FileRequest` (`Editor/File.lean`): `File.load` loads a file, `File.save`
saves a snapshot as one, `File.stamp` reads a file's stamp (`File.stat`
reads it refused as a load would be), `File.list` lists a directory,
`File.makeDirectory` makes one with its parents, `File.append` adds bytes
to the end of a file and `File.remove` removes one. Each waits, as a wait on the clock does, and
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
`Process.runWithin` does so under a time limit, and `Process.runWithInput`
also feeds the child its standard input, then end of file, as a filter
does (`packages/shell/Shell.lean`); `Process.runHead` keeps only the head of what a
fed child writes, and ends it there. `Process.start` starts a streaming child, which the job then reads
(`Process.read`, a delivery of lines or bytes at a time), writes to
(`Process.write`, `Process.writeLine`) and closes the input of
(`Process.closeInput`). A cancelled job's child is killed, with its process
group, by the library: the runner withdraws the wait, and withdrawing a
process wait cancels the run (`Editor/Job/Runner.lean`, "Cancellation"). A
streaming child does not outlive its job: the runner cancels it when the job
ends, however it ends.

A job reaches changes on disk through one request, `fileWatch`, which
carries a `FileWatchRequest` (`Editor/FileWatch.lean`): `FileWatch.start`
watches a file, a directory's entries or a directory's tree and replies with
the watch, named for the job, or a refusal, an `Except FileWatchError`;
`FileWatch.next` waits for the watch's next delivery, every change recorded
and not yet taken, coalesced over the job's window. A watch does not outlive
its job: the runner ends every watch the job holds when the job ends,
however it ends (`Editor/Job/Runner.lean`, "A watch does not outlive its
job"). It is not the interrupt port `Editor/Watch.lean`.

A job reaches a line diff through one request, `diff`, which carries a
`DiffRequest` (`Editor/Diff.lean`): `Diff.lines` diffs two snapshots, named
as a save names its source, and replies with an edit script or a refusal,
an `Except DiffError`; `Diff.hunks` replies with the hunks of whole lines
instead. It waits, as a load does: the library's diff service
works it on a thread of its own, so a long diff holds neither the editor
thread nor a load. A command applies the script (`TextId.applyScript`).

A job registers a grammar through one request, `grammar`, which carries a
`GrammarRequest` (`Editor/SyntaxTree/Registration.lean`): `Grammar.register`
registers the grammar a native library's symbol hands out and replies with
the name it is registered under, or why not, an `Except GrammarError`. It
waits, as a diff does: the library's syntax worker answers it on its own
thread, before its next round and so behind any parse in progress, and from
the next phase on loading a grammar is file I/O. A command cannot make it,
so no command can block on a registration.

A job reaches the environments its host shares through one request,
`environment`, which carries an `EnvironmentRequest`
(`Editor/Process/Environment.lean`) and is answered at once, as `now` is:
the layers the host installed from the registry (a base, then directory
sources; `EnvironmentApi.lean`),
what each source's executable resolved to (from candidates' stamps, or
from probes run through the process service), and the cached lookups, the
base's and each directory and source's. The process operations ask it
before they start a child, so a child gets its layers' variables under its
command's own (`Process.prepared`).

A job reaches a service a package brings through one request, `package`,
which carries a `PackageRequest` (`Editor/PackageService.lean`): the
service's name, an operation and plain arguments. It waits, as a load
does, and replies with the service's reply, a `Dynamic` the package's typed
wrapper reads back (`PackageService.askAs`), or a refusal, an
`Except PackageError`. A service the runner was not given is answered
`noSuchService` at once. A cancelled job's package wait is withdrawn at the
service, as every wait is.

No request carries a promise or a handle: a request is plain data. How a wait
is completed is the runner's business (`Editor/Job/Runner.lean`), not
something a job names.

## Posting a command

A job hands the editor a command while it runs through one request, `post`,
which carries an `Invocation`: a registered command's name and plain
arguments, as a command starts a job by name (`StateRequest.startJob`). So
the job port still never refers to the editor's. It is answered at once, as
`environment` is: it waits for nothing and moves no clock, so a job that
posts often batches by itself. Its host runs the invocation on the editor
thread, between two events, as a delivery labelled `job <id> <name>`
(`runPosted`, `Editor/Api.lean`), after the job's earlier posts and before
its own command. A cancelled or removed job's posts are dropped: the runner
hands a post over only while the job is not cancelled
(`Editor/Job/Runner.lean`, "Posting a command"), and the host runs one only
while the job is in its table (`Job.Jobs.has`). It is how a compile streams
its output into its buffer (`packages/compile/Compile.lean`).

## Reading a snapshot

A job reads the text of a snapshot a command took through one request,
`snapshot`, which carries the `SnapshotId` (`readSnapshot`). It is answered
at once, as `environment` is, and moves no clock: the text is read from the
published table of snapshots as it is then (`Editor/Text/Real.lean`), a
value that never changes. An id that names no snapshot, or one that was
released, is answered `none`, so a job that reads after the command that
took the snapshot gave it up goes on with nothing. It is how the `words`
source gathers the open buffers' words off the editor thread (the default
package `at-point`'s `packages/at-point/AtPoint/Words.lean`). Its model is the job model's table of
published snapshots (`FileModel.snapshots`), the runner's port is
`Job.Services.snapshots`, and its contract is
`JobContract.snapshotProperties`.

## Asking the matcher

A job asks the fuzzy matcher (`Editor/Fuzzy.lean`) through one request,
`fuzzy`, which carries a `FuzzyRequest`. It is answered at once, as
`environment` is: it waits for nothing and moves no clock, since the
matcher answers in the call. A program over the fuzzy port, a completion
style's (`Editor/Completion/Style.lean`), runs in a job with
`Job.embedFuzzy`, as one runs in a command with `Fuzzy.lift`. It is how the
loop matches a long list off the editor thread (`Editor/Loop.lean`,
"Prompts").

**Its reply is an `Except String`**: the matcher's own port has no error,
but the service that answers it in a runner is `IO` and can throw, and the
runner's answer cannot (`Job.answer`), so what was thrown is answered as
`.error`, `fuzzy: ` and the message. `Job.embedFuzzy` throws it, so a job
that does not catch it fails with it.

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

A post is the fifth kind of request, and answers at once too:
`JobRequest.post`. Its model is `JobModel.posted`, and the runner's port is
what it was spawned with (`Job.spawn`'s `posted`); its contract is a list
of its own, `JobContract.postProperties`, run against the model and the
runner with a host that records what it is handed.

The environments are the fourth, and answer at once: `JobRequest.environment`,
whose requests are `EnvironmentRequest`s, so a new question of the shared
state is a constructor there (`Editor/Process/Environment.lean` says what it
needs) and not here. Its model is `JobModel.environments`, with what it said
in `JobModel.reported`; the runner's port is `Job.Environments`, whose
default answers as the default state does and whose shared form,
`Job.sharedEnvironments`, is that state behind a reference.

The file-watch service is the third, beside it: `JobRequest.fileWatch`,
whose requests are `FileWatchRequest`s, so a `stop` that ends a watch early
is a constructor there and not here (`Editor/FileWatch.lean` says what it
needs). Its model is `Editor/FileWatch/Model.lean`, which the job model
composes with the process model so that a command a job runs changes what
its watches see; its fake is `FakeFileWatches` and its real implementation
`realFileWatches`. Withdrawing a wait tells the watch service too, and
ending a job ends its watches (`Handle.endWatches`).

The diff service is the fourth: `JobRequest.diff`, whose requests are
`DiffRequest`s. Its model is `Editor/Diff/Model.lean`, which the file model
answers it with (`FileModel.diff`), since that holds the snapshots a diff
names; its fake is `FakeFiles.diffs`, over the same model, and its real
implementation `realDiffs`. Withdrawing a wait tells the diff service too.

The grep service is the fifth: `JobRequest.grep`, whose requests are
`GrepRequest`s (`Editor/Grep.lean`). Its model is `Editor/Grep/Model.lean`,
over the files and the snapshots of the file model, with the state of its
searches in `JobModel.greps`; its fake is `FakeFiles.greps`, over the same
model, so a job's loads and its searches see one table; and its real
implementation `realGreps`. A start whose overlay names a snapshot the job
does not hold is `noSuchSnapshot` at once, as a diff's source is.
Withdrawing a wait tells the grep service too, and ending a job cancels its
searches (`Handle.endGreps`).

A package's service is the sixth: `JobRequest.package`, whose requests are
`PackageRequest`s (`Editor/PackageService.lean`), so a package's new
operation is its own and not a constructor anywhere. Its model is
`JobModel.packages`, a `PackageModel`; its fake is `FakePackageService`,
and its real implementations are the packages' own, which a package
registers in its record (`Package.services`) and the program's edge hands
the runner (`Job.Services.packages`). Withdrawing a wait tells every
package service too. Its contract is `JobContract.packageProperties`.

The grammar registrations are the seventh: `JobRequest.grammar`, whose
requests are `GrammarRequest`s (`Editor/SyntaxTree/Registration.lean`). Its
model is the grammar registry (`Editor/SyntaxTree/Registration/Model.lean`),
which the job model answers it with (`JobModel.grammars`); its fake is
`FakeGrammars`, over the same model, and its real implementation
`realGrammars`, over the library's syntax worker. Withdrawing a wait tells
the grammar service too. Its contract is `JobContract.grammarProperties`.

The matcher is the last, and answers at once: `JobRequest.fuzzy`, whose
requests are `FuzzyRequest`s, so a new question of the matcher is a
constructor of the fuzzy port and not of this one. Its model answers with
the fuzzy model (`JobModel.handle`), or with the error a test sets
(`JobModel.fuzzyRefusal`); the runner's service is a `FuzzyHandler`
(`Job.Services.fuzzy`), which is `Fuzzy.absent` unless the runner is given
one: the hosts give the library's binding, `Fuzzy.real`. Its contract is a
list of its own, `JobContract.fuzzyProperties`: the fuzzy port's contract,
asked from inside a job, and that it registers no wait.

The system's URL opener is one more, and is asked from a job alone, since
an open may block until the system has the request:
`JobRequest.urlOpener`, whose requests are `UrlOpenerRequest`s
(`Editor/UrlOpener.lean`), with the operation `Job.openUrl`. Its model is
`JobModel.urlOpener`, a `UrlOpenerModel`, which answers at once and moves
no clock; the runner's service is a `UrlOpenerHandler`
(`Job.Services.urlOpener`), answered on the job's own thread, as the
matcher is, which is `UrlOpener.absent` unless the runner is given one:
the window mode gives the library's binding over the desktop's opener
(`UrlOpener.Real.system`), and the headless mode none. Its contract is
`JobContract.urlOpenerProperties`.

## The pieces

- the port, here: the requests, the reply to each, the operations a job is
  written with, `Timer`, and `Work`, a job as it is spawned;
- the file requests as data, `Editor/File.lean`, and the pure model of the
  files a job reaches, `Editor/File/Model.lean`;
- the process requests as data, `Editor/Process.lean`, and the pure model of
  the processes a job runs, `Editor/Process/Model.lean`;
- the file-watch requests as data, `Editor/FileWatch.lean`, and the pure
  model of what a job's watches see, `Editor/FileWatch/Model.lean`;
- the diff request as data, `Editor/Diff.lean`, the edit script it answers,
  `Editor/Diff/Script.lean`, and the pure model of a line diff,
  `Editor/Diff/Model.lean`;
- the search requests as data, `Editor/Grep.lean`, and the pure model of a
  project search, `Editor/Grep/Model.lean`;
- the grammar registration's data, `Editor/SyntaxTree/Registration.lean`,
  and the pure model of the registry, `Editor/SyntaxTree/Registration/Model.lean`;
- the URL opener's requests as data, `Editor/UrlOpener.lean`, and its pure
  model, `Editor/UrlOpener/Model.lean`;
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
  /-- Watch a file or a directory, or wait for a watch's next delivery
  (`Editor/FileWatch.lean`). -/
  | fileWatch (request : FileWatchRequest)
  /-- Diff two snapshots (`Editor/Diff.lean`), and wait for it. -/
  | diff (request : DiffRequest)
  /-- Search the files under a directory, or wait for a search's next
  delivery (`Editor/Grep.lean`). -/
  | grep (request : GrepRequest)
  /-- Ask the environments the host's jobs share
  (`Editor/Process/Environment.lean`): answered at once. -/
  | environment (request : EnvironmentRequest)
  /-- Hand the editor `invocation`, a command's registered name and plain
  arguments, to run on the editor thread while the job goes on: answered
  at once. -/
  | post (invocation : Invocation)
  /-- Ask the fuzzy matcher (`Editor/Fuzzy.lean`): answered at once, or
  with the error the service that answers it threw. -/
  | fuzzy (request : FuzzyRequest)
  /-- Read the text of the snapshot `id` a command took, as the published
  table holds it now: answered at once, `none` for an id that names no
  snapshot or one that was released. -/
  | snapshot (id : SnapshotId)
  /-- Ask a package's service (`Editor/PackageService.lean`), and wait for
  its reply. -/
  | package (request : PackageRequest)
  /-- Register a grammar with the syntax service
  (`Editor/SyntaxTree/Registration.lean`), and wait for its answer. -/
  | grammar (request : GrammarRequest)
  /-- Ask the system's URL opener (`Editor/UrlOpener.lean`): answered on the
  job's own thread once the system has taken the URL or refused it. -/
  | urlOpener (request : UrlOpenerRequest)
  deriving DecidableEq, Repr

/-- The type of the reply to each request: the clock's reading for `now`,
nothing for a wait, and for a file or a process request its own reply, a
refusal or a result. No reply says a job was cancelled. -/
def JobRequest.Reply : JobRequest → Type
  | .now => Nat
  | .waitUntil _ => Unit
  | .file request => request.Reply
  | .process request => request.Reply
  | .fileWatch request => request.Reply
  | .diff request => request.Reply
  | .grep request => request.Reply
  | .environment request => request.Reply
  | .post _ => Unit
  | .fuzzy request => Except String request.Reply
  | .snapshot _ => Option String
  | .package _ => PackageReply
  | .grammar request => request.Reply
  | .urlOpener request => request.Reply

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

/-- Hands the editor `invocation`, to run on the editor thread as a command
while the job goes on ("Posting a command", in the module docs). It is
answered at once and never waits; a cancelled or removed job's posts are
dropped. -/
def post (invocation : Invocation) : JobM Unit :=
  ExceptT.lift (Program.request (port := jobPort) (.post invocation))

/-- The text of the snapshot `id` a command took, as the published table
holds it now ("Reading a snapshot", in the module docs): `none` for an id
that names no snapshot, or one that was released. It is answered at once
and never waits. -/
def readSnapshot (id : SnapshotId) : JobM (Option String) :=
  ExceptT.lift (Program.request (port := jobPort) (.snapshot id))

/-- Hands `url` to the system's URL opener (`Editor/UrlOpener.lean`):
`.ok` once the system took it, and the reason otherwise. It may block until
the system has the request, which is why it is a job's. -/
def Job.openUrl (url : String) : JobM (Except String Unit) :=
  ExceptT.lift (Program.request (port := jobPort) (.urlOpener (.openUrl url)))

/-- `program`, a program over the fuzzy port, as one over the job port that
ends with its value or with the error a fuzzy request was answered: each
request is the fuzzy constructor's, and an `.error` reply ends it there. -/
def Program.embedFuzzyJob {α : Type} : Program fuzzyPort α → Program jobPort (Except String α)
  | .done value => .done (.ok value)
  | .step request next =>
    .step (.fuzzy request) fun reply =>
      match reply with
      | .ok answer => embedFuzzyJob (next answer)
      | .error message => .done (.error message)

/-- `program`, a program over the fuzzy port, as a job: each request asks
the matcher at once ("Asking the matcher", in the module docs), and an
error the service threw is thrown here, so a job that does not catch it
fails with it. -/
def Job.embedFuzzy {α : Type} (program : Program fuzzyPort α) : JobM α :=
  ExceptT.mk program.embedFuzzyJob

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

/-- The stamp of the file at `path`, or `none` when nothing is there, and
waits for it; nothing of the file is read. A directory is refused as
`notAFile`. The refusal is a value: the job goes on. `Editor/File.lean` has
the rules. -/
def File.stamp (path : System.FilePath) : JobM (Except FileError (Option File.Stamp)) :=
  ExceptT.lift (Program.request (port := jobPort) (.file (.stamp path)))

/-- What the directory at `path` holds, sorted by name, each entry with its
kind, and waits for it. The refusal is a value: the job goes on.
`Editor/File.lean` has the rules. -/
def File.list (path : System.FilePath) : JobM (Except FileError (Array File.Entry)) :=
  ExceptT.lift (Program.request (port := jobPort) (.file (.list path)))

/-- Makes the directory at `path`, and every directory on the way to it, and
waits for it. A directory already there is no error. The refusal is a value:
the job goes on. `Editor/File.lean` has the rules. -/
def File.makeDirectory (path : System.FilePath) : JobM (Except FileError Unit) :=
  ExceptT.lift (Program.request (port := jobPort) (.file (.makeDirectory path)))

/-- Adds `bytes` to the end of the file at `path`, making the file when
nothing is there, and waits for it. The bytes are handed to the system and
not synced. The refusal is a value: the job goes on. `Editor/File.lean` has
the rules. -/
def File.append (path : System.FilePath) (bytes : ByteArray) : JobM (Except FileError Unit) :=
  ExceptT.lift (Program.request (port := jobPort) (.file (.append path bytes)))

/-- Removes the file at `path`, and waits for it. Nothing there is no error.
The refusal is a value: the job goes on. `Editor/File.lean` has the rules. -/
def File.remove (path : System.FilePath) : JobM (Except FileError Unit) :=
  ExceptT.lift (Program.request (port := jobPort) (.file (.remove path)))

/-- Stats the file at `path`, reading nothing, and waits for it: the file's
stamp, or why it was refused, as a load would be. It is a stamp request
(`File.stamp`) with nothing there refused as `notFound`, so the refusals
come in a load's order. `Editor/File.lean` has the rules. -/
def File.stat (path : System.FilePath) : JobM (Except FileError File.Stamp) := do
  match ← File.stamp path with
  | .ok (some stamp) =>
    return .ok stamp
  | .ok none =>
    return .error .notFound
  | .error refusal =>
    return .error refusal

/-- Asks the environments every job of the host shares: the layers, what each
source's executable resolved to, and the cached lookups
(`EnvironmentRequest`). It is answered at once, as `now` is, and never
waits. -/
def Process.askEnvironment (request : EnvironmentRequest) : JobM request.Reply :=
  ExceptT.lift (Program.request (port := jobPort) (.environment request))

/-- Makes the process request `request` as it is, with no lookup: for the
process operations, and for the lookup itself, which so never looks itself
up. -/
def Process.request (request : ProcessRequest) : JobM request.Reply :=
  ExceptT.lift (Program.request (port := jobPort) (.process request))

/-- The output limit of a lookup's run, in bytes: a mebibyte. -/
def Process.lookupOutput : Nat :=
  1024 * 1024

/-- The stamp of the file at `path`, or `none` when there is none or it
cannot be read: what an entry of the cache is kept by. -/
def Process.stampOrNone (path : System.FilePath) : JobM (Option File.Stamp) := do
  match ← File.stamp path with
  | .ok stamp =>
    return stamp
  | .error _ =>
    return none

/-- The first of `candidates` that has a stamp: a file is there. -/
def Process.firstStamped (candidates : Array System.FilePath) : JobM (Option System.FilePath) := do
  for candidate in candidates do
    if (← Process.stampOrNone candidate).isSome then
      return some candidate
  return none

/-- The first absolute path one of `probes` names, each run in order as a
raw process request, so with the editor's own environment and never looked
up, under the time limit `limit` and the output limit of a lookup: a run
that is refused, does not exit 0, or names no absolute path passes to the
next, and nothing is said of it. -/
def Process.firstProbed (probes : Array Process.Probe) (limit : Nat) :
    JobM (Option System.FilePath) := do
  for probe in probes do
    match ← Process.request (.runWithin probe.command Process.lookupOutput limit) with
    | .ok { exit := .code 0, stdout, .. } =>
      if let some path := probe.answer.read stdout then
        return some path
    | _ =>
      pure ()
  return none

/-- What the source `name` resolved to, as the shared state has it: the
answer an earlier job kept (`policy.programs`), else `resolve`'s, which is
then kept for every job until a reload. -/
def Process.resolvedOnce (policy : Process.Policy) (name : String)
    (resolve : JobM (Option System.FilePath)) : JobM (Option System.FilePath) := do
  match policy.programs.find? (·.1 == name) with
  | some (_, found) =>
    return found
  | none =>
    let found ← resolve
    Process.askEnvironment (.resolved name found)
    return found

/-- Where `source`'s executable is, as the shared state has it: its path;
or the first of its candidates, resolved by an earlier job or else from the
candidates' stamps; or the first path its probes name, run under `limit`,
else its fallback; each of the last two kept for every job until a reload.
With none of its candidates there, what the source does then. -/
def Process.programOf (policy : Process.Policy) (source : Process.Source) (limit : Nat) :
    JobM (Except Process.WhenNone System.FilePath) := do
  match source.program with
  | .at path =>
    return .ok path
  | .firstOf candidates whenNone =>
    let found ← Process.resolvedOnce policy source.name (Process.firstStamped candidates)
    return match found with
      | some executable => .ok executable
      | none => .error whenNone
  | .probed probes otherwise =>
    let found ←
      Process.resolvedOnce policy source.name do
          return some ((← Process.firstProbed probes limit).getD otherwise)
    return .ok (found.getD otherwise)

/-- The entry of `slot` for `source` run by `executable` in `directory` over
`below`: the cached one while the stamps of `stampNames` there and in its
ancestors, and `below`, are what they were, and else a new lookup's, run
with the time limit `limit`, which is recorded. The stamps are read before
the lookup runs. The lookup is a raw process request, so it never looks
itself up. -/
def Process.lookedUp (slot : Process.Slot) (source : Process.Source)
    (executable directory : System.FilePath) (stampNames : Array String)
    (below : Array (String × String)) (limit : Nat) : JobM Process.Entry := do
  let stamps ← (Process.stampPaths stampNames directory).mapM Process.stampOrNone
  let cached : Option Process.Entry ← Process.askEnvironment (.cached slot)
  if let some entry := cached then
    if entry.stamps == stamps && entry.below == below then
      return entry
  let ran ←
    Process.request
        (.runWithin (source.command executable directory { set := below }) Process.lookupOutput
          limit)
  let entry : Process.Entry := { stamps, below, found := Process.foundOf source ran }
  Process.askEnvironment (.record slot entry)
  return entry

/-- The variables `source` gives in `slot`, looked up in `directory` over
`below`, its result kept by the stamps of `stampNames`, its lookup and any
probes run under its own time limit, else the shared one: none when it
failed, so it is skipped and the layers below are kept, or when its
executable is at none of its candidates, which is recorded once for the
slot when the source reports it. -/
def Process.sourceVariables (slot : Process.Slot) (source : Process.Source)
    (directory : System.FilePath) (stampNames : Array String) (below : Array (String × String))
    (policy : Process.Policy) : JobM (Array (String × String)) := do
  let limit := source.limit.getD policy.limit
  match ← Process.programOf policy source limit with
  | .error .skip =>
    return #[]
  | .error .report =>
    let candidates :=
      match source.program with
      | .firstOf candidates _ => candidates
      | .at _ | .probed .. => #[]
    let cached : Option Process.Entry ← Process.askEnvironment (.cached slot)
    if cached.isNone then
      Process.askEnvironment
          (.record slot { stamps := #[], found := .failed (.missing candidates) })
    return #[]
  | .ok executable =>
    match (← Process.lookedUp slot source executable directory stampNames below limit).found with
    | .variables variables =>
      return variables
    | .failed _ =>
      return #[]

/-- `command` with the environment its layers give it
(`Editor/Process/Environment.lean`): the base's variables, then each
directory source's for its directory in order, each looked up over the
layers before it, all under its own. It is returned unchanged when the
process service would refuse it, a directory or a program that is not
absolute; when it clears the editor's environment; and when the base is
the inherited one with no directory source. A source whose executable is
probed runs its probes before its first lookup, once until a reload
(`Process.programOf`). A source whose lookup failed is skipped, which the
shared state reports once for its slot. -/
def Process.prepared (command : Process.Command) : JobM Process.Command := do
  if !command.directory.isAbsolute || command.namesRelative || command.environment.clear then
    return command
  let policy : Process.Policy ← Process.askEnvironment .policy
  if policy.sources.base matches .inherited && policy.sources.directories.isEmpty then
    return command
  let mut below : Array (String × String) ←
    match policy.sources.base with
    | .inherited =>
      pure #[]
    | .lookup source directory =>
      Process.sourceVariables (.base source.name) source directory #[] #[] policy
  for source in policy.sources.directories do
    let variables ←
      Process.sourceVariables (.directory command.directory source.name) source command.directory
          source.stampNames below policy
    below := Process.layer below variables
  return { command with environment := Process.Environment.over below command.environment }

/-- Runs `command` to its end and waits for it, collecting each output stream
unless it is longer than `limit` bytes: how the child ended and both its
streams, or why it was refused. The refusal is a value: the job goes on. A
cancelled job's child is killed, with its process group. The child gets the
environment its layers give it (`Process.prepared`).
`Editor/Process.lean` has the rules. -/
def Process.run (command : Process.Command) (limit : Nat) :
    JobM (Except ProcessError Process.Ran) := do
  Process.request (.run (← Process.prepared command) limit)

/-- Runs `command` as `Process.run` does, and kills it, with its process
group, if it has not ended `time` milliseconds after it was started: then the
reply is `timedOut`. The child gets the environment its layers give
it (`Process.prepared`). `Editor/Process.lean` has the rules. -/
def Process.runWithin (command : Process.Command) (limit : Nat) (time : Nat) :
    JobM (Except ProcessError Process.Ran) := do
  Process.request (.runWithin (← Process.prepared command) limit time)

/-- Runs `command` as `Process.runWithin` does, with `input` as its standard
input, followed by end of file: how the child ended and both its streams,
or why it was refused. A child that does not read its input is no refusal.
The child gets the environment its layers give it
(`Process.prepared`). `Editor/Process.lean` has the rules. -/
def Process.runWithInput (command : Process.Command) (input : ByteArray) (limit : Nat)
    (time : Nat) : JobM (Except ProcessError Process.Ran) := do
  Process.request (.runInput (← Process.prepared command) input limit time)

/-- Runs `command` as `Process.runWithInput` does, keeping the head of its
standard output: past `limit` bytes the child is ended and the reply is
`Process.Head.cut` with exactly the first `limit` bytes, instead of a
refusal. `Editor/Process.lean` has the rules. -/
def Process.runHead (command : Process.Command) (input : ByteArray) (limit : Nat) (time : Nat) :
    JobM (Except ProcessError Process.Head) := do
  Process.request (.runHead (← Process.prepared command) input limit time)

/-- Starts `command` as a streaming child, as `streaming` says, and waits for
it to start: the child, named for this job, or why it was refused. The child
does not outlive the job. The child gets the environment its
layers give it (`Process.prepared`). `Editor/Process.lean` has the rules. -/
def Process.start (command : Process.Command) (streaming : Process.Streaming) :
    JobM (Except ProcessError Process.Id) := do
  Process.request (.start (← Process.prepared command) streaming)

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

/-- Watches `target`, coalesced as `coalescing` says: the watch, named for
the job, which does not outlive it. `Editor/FileWatch.lean` has the
rules. -/
def FileWatch.start (target : FileWatch.Target) (coalescing : FileWatch.Coalescing) :
    JobM (Except FileWatchError FileWatch.Id) :=
  ExceptT.lift (Program.request (port := jobPort) (.fileWatch (.start target coalescing)))

/-- Waits for the next delivery of `watch`: every change recorded and not yet
taken, at most one a path, once the window from its first change has
passed. -/
def FileWatch.next (watch : FileWatch.Id) : JobM (Except FileWatchError (Array FileWatch.Change)) :=
  ExceptT.lift (Program.request (port := jobPort) (.fileWatch (.next watch)))

/-- Registers the grammar `source` names with the syntax service, and answers
the name it is registered under (`GrammarSource.name`), or why not: refused
by the service, or failed on the way. It waits: the library answers it on
the syntax worker's thread, before that worker's next round.
`Editor/SyntaxTree/Registration.lean` has the rules. -/
def Grammar.register (source : GrammarSource) : JobM (Except GrammarError String) :=
  ExceptT.lift (Program.request (port := jobPort) (.grammar (.register source)))

/-- The line diff of what `old` and `new` hold, with the engine asked about at
most `limit` lines a side, and waits for it: the edit script that turns the
one into the other, or why it was refused. The diff is worked off the
editor's thread, and only the script comes back. `Editor/Diff.lean` has the
rules. -/
def Diff.lines (old new : File.Source) (limit : Nat) : JobM (Except DiffError Diff.Script) :=
  ExceptT.lift (Program.request (port := jobPort) (.diff (.lines old new limit)))

/-- The hunks of whole lines that turn what `old` holds into what `new` holds,
with the engine asked about at most `limit` lines a side, and waits for them,
or for why they were refused. Worked off the editor's thread, as `Diff.lines`
is. `Editor/Diff.lean` has the rules. -/
def Diff.hunks (old new : File.Source) (limit : Nat) : JobM (Except DiffError Diff.Hunks) :=
  ExceptT.lift (Program.request (port := jobPort) (.diff (.hunks old new limit)))

/-- Searches the files under `root` for `pattern`, with each overlay's
snapshot searched in place of the file at its path, stopping at `limits`,
with at most `bound` matches a delivery: the search, named for the job,
which does not outlive it. `Editor/Grep.lean` has the rules. -/
def Grep.start (root : System.FilePath) (pattern : String)
    (overlays : Array (System.FilePath × File.Source)) (limits : Grep.Limits) (bound : Nat) :
    JobM (Except GrepError Grep.Id) :=
  ExceptT.lift
    (Program.request (port := jobPort) (.grep (.start root pattern overlays limits bound)))

/-- Waits for the next delivery of `search`: the files found and not yet
taken, and, in the last, how it ended. -/
def Grep.next (search : Grep.Id) : JobM (Except GrepError Grep.Delivery) :=
  ExceptT.lift (Program.request (port := jobPort) (.grep (.next search)))

/-- Asks the package service `request` names, and waits for its reply: the
`Dynamic` its binding made, or why it did not answer. A service the runner
was not given is `noSuchService`, at once. A cancelled job's wait is
withdrawn at the service. -/
def PackageService.ask (request : PackageRequest) : JobM PackageReply :=
  ExceptT.lift (Program.request (port := jobPort) (.package request))

/-- Asks as `PackageService.ask` does, and reads the reply back as `α`, the
service's own reply type: a reply of another type, which only a service
that shares another's name gives, is refused, never a crash. -/
def PackageService.askAs (α : Type) [TypeName α] (request : PackageRequest) :
    JobM (Except PackageError α) := do
  match ← PackageService.ask request with
  | .ok reply =>
    match reply.get? α with
    | some value =>
      return .ok value
    | none =>
      return .error
          (.refused s!"the reply of {request.service}'s {request.operation} is of another type")
  | .error refusal =>
    return .error refusal

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
  fail_if_success exact (fun (_ : JobM Unit) => True.intro) (pure () : BaseIO Unit)
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : JobM Unit) => True.intro)
        (do
          (pure () : BaseIO Unit)
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
  fail_if_success exact (fun (_ : TextM Unit) => True.intro) (pure () : BaseIO Unit)
  trivial

example : True := by
  fail_if_success exact (fun (_ : EditorM Unit) => True.intro) (pure () : BaseIO Unit)
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : TextM Unit) => True.intro)
        (do
          (⟨0⟩ : TextId).insert 0 "x"
          (pure () : BaseIO Unit))
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : EditorM Unit) => True.intro)
        (do
          (⟨0⟩ : TextId).insert 0 "x"
          (pure () : BaseIO Unit))
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

/-! A post is a job's, and it is not a command: a command runs another command
inside itself (`runCommand`), and hands one to the editor for later with
`invoke`, but it cannot post. Seen to bite once by hand: offered at
`JobM Unit` inside the first `fail_if_success` check, the module stops
building. -/

example : True :=
  (fun (_ : JobM Unit) => True.intro) (post { command := "x" })

example : True := by
  fail_if_success exact (fun (_ : EditorM Unit) => True.intro) (post { command := "x" })
  trivial

example : True := by
  fail_if_success exact (fun (_ : TextM Unit) => True.intro) (post { command := "x" })
  trivial

/-! A request of a package's service is a job's, and it is not a command: a
command cannot wait on a package's service. Seen to bite once by hand:
offered at `JobM PackageReply` inside the first `fail_if_success` check,
the module stops building. -/

example : True :=
  (fun (_ : JobM PackageReply) => True.intro)
    (PackageService.ask { service := "x", operation := "y" })

example : True := by
  fail_if_success
    exact
      (fun (_ : EditorM PackageReply) => True.intro)
        (PackageService.ask { service := "x", operation := "y" })
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : TextM PackageReply) => True.intro)
        (PackageService.ask { service := "x", operation := "y" })
  trivial

/-! A grammar registration is a job's, and it is not a command: alone, and
after a text request in a `do` block. So a command cannot block on a
registration, which the library answers behind any parse in progress. Seen
to bite once by hand: offered at `JobM (Except GrammarError String)` inside
the first `fail_if_success` check, the module stops building. -/

example : True :=
  (fun (_ : JobM (Except GrammarError String)) => True.intro)
    (Grammar.register { library := "/a.so", symbol := "tree_sitter_a" })

example : True := by
  fail_if_success
    exact
      (fun (_ : EditorM (Except GrammarError String)) => True.intro)
        (Grammar.register { library := "/a.so", symbol := "tree_sitter_a" })
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : TextM (Except GrammarError String)) => True.intro)
        (Grammar.register { library := "/a.so", symbol := "tree_sitter_a" })
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : EditorM Unit) => True.intro)
        (do
          (⟨0⟩ : TextId).insert 0 "x"
          discard <| Grammar.register { library := "/a.so", symbol := "tree_sitter_a" })
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
