/-!
# File watches, as a job asks for them

The data of the watch requests a job can make: be told when a file, a
directory's entries or a directory's whole tree changes on disk. It is plain
data and imports nothing, as `Editor/Process.lean` is. The requests
themselves are requests of the job port (`Editor/Job.lean`,
`JobRequest.fileWatch`): waiting for a change is a thing a job does, and the
operations a job is written with, `FileWatch.start` and `FileWatch.next`,
are there.

This is not `Editor/Watch.lean`, the port of the interrupt flag and the job
clock that the command loop checks while a command runs: that one is
`Watch`, this one `FileWatch`.

Registering a watch with the platform, coalescing what it reports and
delivering it are the library's (`crates/editor-watch`, its service over
the adapter in `crates/editor-watch-notify`). Lean never asks the platform
for a change.

## The rules

- **A start** (`FileWatchRequest.start`) names a target (`FileWatch.Target`):
  a file, a directory's entries, or a directory and everything under it
  (`recursive`). The reply names the watch (`FileWatch.Id`) for the job that
  started it: a `next` of an id the job does not hold is `noSuchWatch` at
  once, with nothing asked of the library.
- **A file is watched through the directory it is in.** So a write, a rename
  over the file and a remove followed by a new file are each told under the
  file's name, and a file that is not there yet can be watched: its creation
  is told. Its directory must be there; one that is not is `notFound`.
- **A path that is not absolute, or has a `..` component, is refused** with
  `notAbsolute` before anything is watched: the editor has no working
  directory, and paths are compared as they are spelled.
- **A read** (`FileWatchRequest.next`) waits for the next delivery: every
  change recorded and not yet taken, at most one change a path
  (`FileWatch.Change`), in the order of each path's first change. A change
  names an absolute path, spelled under the target as the job spelled it,
  and the kinds of change seen there (`FileWatch.Kinds`): created, written,
  renamed (under its old path and its new one), removed, or missed. A
  platform can carry an earlier change's kind, so a job looks for a kind
  being there, never for a set exactly.
- **The coalescing** (`FileWatch.Coalescing`) is the job's policy, with no
  default. The window is a fixed window from a delivery's first change: a
  read is answered once `window` milliseconds have passed since then, so
  several writes to one path inside it arrive as one change, and a file
  written without pause is delivered once a window, never held back for
  good. The bound is how many distinct paths a delivery may hold: past it,
  the delivery is one change, `missed`, of the watch's own path, and the
  job knows something changed it cannot name. A platform's own overflow,
  and a path that is not UTF-8, are told the same way.
- **What is not told**: a change of metadata alone, and a read. Ignore rules
  are not the watch's: whoever asks filters.
- **A watch does not outlive its job.** However the job ends, the runner
  ends every watch the job still holds. Config's jobs are cancelled when a
  reload installs, so config's watches are replaced, never piled up.
- **Errors are values.** A reply is an `Except FileWatchError`, which the
  job matches on, or throws `FileWatchError.describe` of.
- **Its first compiled user is auto-reload**, which is off by default: the
  job `follow-file` (`Files.followWork`, `Editor/Files.lean`) watches one
  file buffer's file while the mode is on, and the loop ends it, by its
  key, when the mode is turned off or the buffer closed
  (`Editor/Loop.lean`, "Auto-reload"). With the mode off compiled code
  opens no watch; a config's own job may still start one.

## Where an addition goes

| Addition | Where | Pinned by |
|---|---|---|
| A request (a `stop` that ends a watch before its job ends, which is not built) | A constructor of `FileWatchRequest` with its case in `FileWatchRequest.Reply`, and an operation in `Editor/Job.lean` | A clause of `FileWatchModel.handle` (`Editor/FileWatch/Model.lean`), the fake and the real service of the runner (`Editor/Job/Fake.lean`, `Editor/Job/Real.lean`), and a property of `JobContract.fileWatchProperties` |
| A kind of change | A field of `FileWatch.Kinds` and a constructor of `FileWatch.Kind`, with its bit in `Kinds.ofBits` | The model's checks (`ModelTest.fileWatchModelChecks`) and a property of the contract |
| A refusal | A constructor of `FileWatchError` with its sentence in `FileWatchError.describe` | The property that asks for it |
-/

namespace Editor

namespace FileWatch

/-- What a watch is on. -/
inductive Target where
  /-- A file, which need not be there yet; its directory must be. -/
  | file (path : System.FilePath)
  /-- A directory: what is directly inside it, or, `recursive`, everything
  under it. -/
  | directory (path : System.FilePath) (recursive : Bool)
  deriving DecidableEq, Repr

/-- The path a watch is of: the file's or the directory's. -/
def Target.path : Target → System.FilePath
  | .file path => path
  | .directory path _ => path

/-- How a watch's changes are coalesced: the job's policy, with no
default. -/
structure Coalescing where
  /-- How long after a delivery's first change it is answered, in
  milliseconds on the job clock. -/
  window : Nat
  /-- How many distinct paths a delivery may hold. At least one. -/
  bound : Nat
  deriving DecidableEq, Repr

/-- A watch, as the job that started it names it: the id of the wait its
start was, which is never used again in a process. It is the job's: another
job's requests cannot name it. -/
structure Id where
  /-- The number. -/
  number : Nat
  deriving DecidableEq, Repr, Hashable

/-- One kind of change. -/
inductive Kind where
  /-- The path was made. -/
  | created
  /-- Its content was written. -/
  | written
  /-- It was renamed, from or to it. -/
  | renamed
  /-- It was removed. -/
  | removed
  /-- Changes were lost, and the path is the watch's own. -/
  | missed
  deriving DecidableEq, Repr

/-- The kinds of change seen at a path. -/
structure Kinds where
  /-- It was made. -/
  created : Bool := false
  /-- Its content was written. -/
  written : Bool := false
  /-- It was renamed, from or to it. -/
  renamed : Bool := false
  /-- It was removed. -/
  removed : Bool := false
  /-- Changes were lost. -/
  missed : Bool := false
  deriving DecidableEq, Repr

/-- Whether `kind` is among `kinds`. -/
def Kinds.has (kinds : Kinds) : Kind → Bool
  | .created => kinds.created
  | .written => kinds.written
  | .renamed => kinds.renamed
  | .removed => kinds.removed
  | .missed => kinds.missed

/-- `kinds` with `kind` added. -/
def Kinds.add (kinds : Kinds) : Kind → Kinds
  | .created => { kinds with created := true }
  | .written => { kinds with written := true }
  | .renamed => { kinds with renamed := true }
  | .removed => { kinds with removed := true }
  | .missed => { kinds with missed := true }

/-- The kinds the library's bits say: created 1, written 2, renamed 4,
removed 8, missed 16. -/
def Kinds.ofBits (bits : Nat) : Kinds :=
  { created := bits &&& 1 != 0, written := bits &&& 2 != 0, renamed := bits &&& 4 != 0
    removed := bits &&& 8 != 0, missed := bits &&& 16 != 0 }

/-- What a delivery holds of one path. -/
structure Change where
  /-- The path, absolute, spelled under the watch's target as the job spelled
  it. -/
  path : System.FilePath
  /-- Every kind of change seen there since the last delivery. -/
  kinds : Kinds
  deriving DecidableEq, Repr

end FileWatch

/-- Why a watch was refused, or a read of one. -/
inductive FileWatchError where
  /-- The path is not absolute, or has a `..` component; `detail` says
  which. -/
  | notAbsolute (detail : String)
  /-- The directory, or a file's directory, is not there. -/
  | notFound (detail : String)
  /-- A directory's path names something that is not a directory. -/
  | notADirectory (detail : String)
  /-- The platform does not allow it; `detail` is its words. -/
  | denied (detail : String)
  /-- The system's limit on watches is reached. -/
  | limit (detail : String)
  /-- No watch of the job's has this id: another job's. -/
  | noSuchWatch
  /-- Anything else; `detail` says what. -/
  | failed (detail : String)
  deriving DecidableEq, Repr

/-- What a refusal says, as a sentence for a person: for a job that wants to
throw one. -/
def FileWatchError.describe : FileWatchError → String
  | .notAbsolute detail => s!"the path is not absolute: {detail}"
  | .notFound detail => s!"the directory is not there: {detail}"
  | .notADirectory detail => s!"the path is not a directory: {detail}"
  | .denied detail => s!"the system does not allow it: {detail}"
  | .limit detail => s!"the system's limit on watches is reached: {detail}"
  | .noSuchWatch => "the job has no such watch"
  | .failed detail => s!"the watch request failed: {detail}"

/-- What a job may ask of file watches. A new watch request is a constructor
here. -/
inductive FileWatchRequest where
  /-- Watch `target`, coalesced as `coalescing` says: the watch, named for
  the job. -/
  | start (target : FileWatch.Target) (coalescing : FileWatch.Coalescing)
  /-- Wait for the next delivery of `watch`'s changes. -/
  | next (watch : FileWatch.Id)
  deriving DecidableEq, Repr

/-- The type of the reply to each watch request: a refusal or the result. A
refusal is a value, never a throw. -/
def FileWatchRequest.Reply : FileWatchRequest → Type
  | .start .. => Except FileWatchError FileWatch.Id
  | .next .. => Except FileWatchError (Array FileWatch.Change)

/-- The reply to `request` that refuses it with `error`, whatever the
request: for a service that answers without asking anyone. -/
def FileWatchRequest.refused (error : FileWatchError) : (request : FileWatchRequest) → request.Reply
  | .start .. => .error error
  | .next .. => .error error

end Editor
