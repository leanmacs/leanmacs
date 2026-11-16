import Editor.Text

/-!
# Files, as a job asks for them

The data of the three file requests a job can make: load a file, save a
snapshot as a file, and stat a file. It is plain data, and it imports only the text port, for
the two kinds of id a save names its source by. The requests themselves are
requests of the job port (`Editor/Job.lean`, `JobRequest.file`): a command
may not wait and a job may, so loading and saving are things a job does, and
the operations a job is written with, `File.load` and `File.save`, are
there.

Loading a file into a text and saving a text are the library's
(`crates/editor-text`, `file`), so a file's bytes never pass through a Lean
string: a load answers with the name of a snapshot the job holds, and a save
names a snapshot.

## The rules

- **A path is a `System.FilePath`**, a Lean string, and must be absolute: a
  path that is not is refused with `relativePath`, since the editor has no
  working directory. A file whose name is not UTF-8 cannot be named.
- **A load** (`FileRequest.load`) reads the file at a path unless it is
  longer than a limit, in bytes, that the request carries: what the limit is
  is the editor's policy, and there is no default. It is refused with
  `notFound` when nothing is at the path, with `notAFile` for a directory,
  with `tooLarge` and both numbers for a file over the limit, and with
  `binary` and the offset for a file with a NUL byte among its first 8,000
  bytes. A byte that is not valid UTF-8 is kept, as its escape
  (`Editor/Text.lean`), so a file in another encoding loads.
- **What a load answers** (`File.Loaded`): the snapshot, as a
  `JobSnapshotId`; the file's stamp; and its line endings, counted, with
  nothing changed.
- **A snapshot a load made is the job's.** It is named by a `JobSnapshotId`
  for the job that loaded it and for that job's command, and for nothing
  else. The job can save it. The job's command can take it into the text
  store (`JobSnapshotId.adopt`, `JobSnapshotId.toText`). Whatever runs the
  job releases it once the job's command has run, or when the job fails or
  is cancelled.
- **A save** (`FileRequest.save`) writes what a snapshot holds as the file
  at a path, and answers with the stamp of the file it wrote. Its source
  (`File.Source`) is a snapshot a command took, by its `SnapshotId`, or one
  this job loaded, by its `JobSnapshotId`. A source that names no snapshot
  is refused with `noSuchSnapshot` before the path is looked at: a snapshot
  a command released, and a `JobSnapshotId` this job does not hold, another
  job's included. Nothing is translated on the way out: the bytes of a file
  loaded and saved without an edit are the bytes it had.
- **A stamp** (`File.Stamp`) is when a file was last modified and how long it
  is. Two stamps are compared for equality and never ordered: a file put
  back from a backup has changed.
- **A save says what it expects to find** (`File.Expect`): the file with the
  stamp a load or the last save answered, no file, or whatever is there. A
  save that finds something else is refused with `changed` and what is there
  now, and writes nothing over the file. The caller may ask again with
  `whatever`, which is the override, or load again.
- **A stat** (`FileRequest.stat`) answers the stamp of the file at a path
  from one stat, reading nothing: what a check for a change on disk compares
  with the stamp a buffer recorded. It is refused as a load is, in the same
  order: `relativePath`, `notFound` for nothing there, `notAFile` for a
  directory. A stat after a load answers the load's stamp, and after a save
  the save's.
- **What notices a change.** A save notices one when it is asked for, and
  the staleness check, one stat a file buffer, when the loop asks for one:
  as the frame gains the focus, as a buffer is switched to, and at a
  buffer's first edit (`Editor/Loop.lean`, "Files that changed on disk").
  Nothing watches a file unless auto-reload is on, which is off by default
  (`Editor/Loop.lean`, "Auto-reload"). A rewrite within the file system's timestamp
  granularity that keeps the size is seen by neither: that is the
  library's limit, pinned there (`crates/editor-text`, `file`).
- **A save never leaves a half-written file**: the library writes a
  temporary file beside the file and renames it. A save into a directory
  that is not there is refused with `notFound`.
- **Errors are values.** A reply is an `Except FileError`: a job matches on
  it and goes on, or throws `FileError.describe` of it, as it chooses.
  Nothing about a file cancels a job or ends it.

Which line ending a new line gets is the editor's policy, so the library
sends the counts and `File.LineEndings.dominant` decides. The buffer keeps
the answer (`Buffer.lineEnding`, `Editor/State.lean`), and the one
operation that breaks a line inserts its text (`File.LineEnding.text`,
`Target.insertLineBreak` in `Editor/Api.lean`).

## Adding to this

A new file request is a constructor of `FileRequest` with its case in
`FileRequest.Reply`, and an operation in `Editor/Job.lean`. It needs a clause
in the model (`FileModel.handle`, `Editor/File/Model.lean`), in the fake and
the real file service of the job runner (`Editor/Job/Fake.lean`,
`Editor/Job/Real.lean`), and a property in the job port's contract
(`JobContract.fileProperties`), which is what pins it for all three. A new
refusal is a constructor of `FileError` with its sentence in
`FileError.describe`.
-/

namespace Editor

namespace File

/-- What is compared to tell whether a file changed: when it was last
modified and how long it is. Two stamps are compared with `==` and never
ordered. -/
structure Stamp where
  /-- Whole seconds since the Unix epoch; negative before 1970. -/
  seconds : Int
  /-- The nanoseconds beyond `seconds`. -/
  nanoseconds : Nat
  /-- The file's length in bytes: not the length of its text, where they
  differ. -/
  size : Nat
  deriving DecidableEq, Repr

/-- One way a line ends. -/
inductive LineEnding where
  /-- A line feed. -/
  | lf
  /-- A carriage return and a line feed. -/
  | crlf
  deriving DecidableEq, Repr

/-- What a line ending is, as text: a line feed, or a carriage return and a
line feed. It is what a command inserts to break a line. -/
def LineEnding.text : LineEnding → String
  | .lf => "\n"
  | .crlf => "\r\n"

/-- The line endings of a file, counted on its bytes. A carriage return
alone is neither. -/
structure LineEndings where
  /-- How many line feeds stand alone. -/
  lf : Nat
  /-- How many line feeds follow a carriage return. -/
  crlf : Nat
  deriving DecidableEq, Repr

/-- The ending most of a file's lines have: CRLF when there are more of those
than of line feeds alone, and LF otherwise when the file has a line break at
all. `none` for a file with no line break: the editor's default decides
then. -/
def LineEndings.dominant (endings : LineEndings) : Option LineEnding :=
  if endings.crlf > endings.lf then some .crlf else if endings.lf > 0 then some .lf else none

/-- What a save expects to find at its path. -/
inductive Expect where
  /-- The file with this stamp: the one a load or the last save answered. -/
  | unchanged (stamp : Stamp)
  /-- No file: one that has appeared is a change. -/
  | absent
  /-- Anything, or nothing: the save checks nothing. This is the override. -/
  | whatever
  deriving DecidableEq, Repr

/-- What a load answers. -/
structure Loaded where
  /-- The file's text: a snapshot the job holds. -/
  snapshot : JobSnapshotId
  /-- What a save is to expect on disk if the file has not changed. -/
  stamp : Stamp
  /-- The file's line endings. -/
  endings : LineEndings
  deriving DecidableEq, Repr

/-- What a save writes: a snapshot, named one of two ways. -/
inductive Source where
  /-- A snapshot of the text store, which a command took or adopted. -/
  | snapshot (id : SnapshotId)
  /-- A snapshot this job holds: one of its own loads made it. -/
  | held (id : JobSnapshotId)
  deriving DecidableEq, Repr

end File

/-- Why a load or a save was refused. -/
inductive FileError where
  /-- The path is not absolute. -/
  | relativePath
  /-- Nothing is at the path, or at a directory on the way to it. -/
  | notFound
  /-- What is at the path is not a file. -/
  | notAFile
  /-- The file system does not allow it. -/
  | denied
  /-- The file is binary: its first NUL byte is at `offset`, among its first
  8,000 bytes. -/
  | binary (offset : Nat)
  /-- The file is `size` bytes long, over the `limit` the load was given. -/
  | tooLarge (size limit : Nat)
  /-- The file on disk is not the one the save expected: `found` is its
  stamp now, or `none` when there is no file. -/
  | changed (found : Option File.Stamp)
  /-- The save's source names no snapshot: a snapshot a command released or
  never took, or one this job does not hold. -/
  | noSuchSnapshot
  /-- No name was free for the save's temporary file. -/
  | noTemporaryName
  /-- Anything else; `detail` says what. -/
  | failed (detail : String)
  deriving DecidableEq, Repr

/-- What a refusal says, as a sentence for a person: for a job that wants to
throw one. -/
def FileError.describe : FileError → String
  | .relativePath => "the path is not absolute"
  | .notFound => "nothing is at the path"
  | .notAFile => "what is at the path is not a file"
  | .denied => "the file system does not allow it"
  | .binary offset => s!"the file is binary: it has a NUL byte at offset {offset}"
  | .tooLarge size limit => s!"the file is {size} bytes long, over the limit of {limit}"
  | .changed none => "the file on disk is not the one that was expected: there is no file now"
  | .changed (some stamp) =>
    s!"the file on disk is not the one that was expected: it is {stamp.size} bytes long and was modified at {stamp.seconds} s and {stamp.nanoseconds} ns"
  | .noSuchSnapshot => "the save names no snapshot"
  | .noTemporaryName => "no name was free for the save's temporary file"
  | .failed detail => s!"the file request failed: {detail}"

/-- What a job may ask of files. A new file request is a constructor here. -/
inductive FileRequest where
  /-- Load the file at `path`, unless it is longer than `limit` bytes. -/
  | load (path : System.FilePath) (limit : Nat)
  /-- Save what `source` holds as the file at `path`, if what is there is
  what `expect` says. -/
  | save (source : File.Source) (path : System.FilePath) (expect : File.Expect)
  /-- Stat the file at `path`, reading nothing. -/
  | stat (path : System.FilePath)
  deriving DecidableEq, Repr

/-- The type of the reply to each file request: a refusal or the result. A
refusal is a value, never a throw. -/
def FileRequest.Reply : FileRequest → Type
  | .load .. => Except FileError File.Loaded
  | .save .. => Except FileError File.Stamp
  | .stat _ => Except FileError File.Stamp

end Editor
