import Editor.Text

/-!
# Files, as a job asks for them

The data of the file requests a job can make: load a file, save a snapshot
as a file, read a file's stamp, list a directory, make one, append to a
file and remove one. It is plain data, and it imports only the text port, for
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
- **A stamp request** (`FileRequest.stamp`) answers the stamp of the file at
  a path, or `none` when nothing is there, and reads nothing of the file. A
  directory, or anything else that is not a file, is refused with
  `notAFile`. It is how a job tells whether a file changed without loading
  it.
- **A listing** (`FileRequest.list`) answers what the directory at a path
  holds, one `File.Entry` per name with its kind (`File.Kind`: a file, a
  directory, or anything else), links followed. It is refused in the order
  `relativePath`, `notFound`, `notADirectory` (what is there is not a
  directory), `denied`. The entries are sorted by name in byte order, which
  is the library's order and the model's. A name that is not UTF-8 is left
  out, since a path here is a Lean string.
- **A directory made** (`FileRequest.makeDirectory`) makes the directory at
  a path and every directory on the way to it; one already there is no
  error. It is refused in the order `relativePath`, `notADirectory` (a file,
  or anything else that is not a directory, at the path or on the way to
  it). A save makes no directory, so a job that saves where one may be
  missing makes it first.
- **An append** (`FileRequest.append`) adds bytes to the end of the file at
  a path, and makes the file when nothing is there. It is refused in the
  order `relativePath`, `notAFile` (a directory at the path, or a file on
  the way to it), `notFound` (the directory it is in is not there). The
  bytes are handed to the system before it answers and are not synced: they
  outlive the process, not a power loss. It is what a journal is written
  with (`Editor/Restore.lean`).
- **A remove** (`FileRequest.remove`) removes the file at a path. Nothing
  there is no error. It is refused with `relativePath`, and as the system
  refuses it otherwise.
- **A stamp** (`File.Stamp`) is when a file was last modified and how long it
  is. Two stamps are compared for equality and never ordered: a file put
  back from a backup has changed.
- **A save says what it expects to find** (`File.Expect`): the file with the
  stamp a load or the last save answered, no file, or whatever is there. A
  save that finds something else is refused with `changed` and what is there
  now, and writes nothing over the file. The caller may ask again with
  `whatever`, which is the override, or load again.
- **A stat** (`File.stat`, `Editor/Job.lean`) is a stamp request read as a
  load would be: what a check for a change on disk compares with the stamp
  a buffer recorded. Nothing there is refused with `notFound`, so it is
  refused as a load is, in the same order: `relativePath`, `notFound`,
  `notAFile` for a directory. A stat after a load answers the load's stamp,
  and after a save the save's.
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

**The store's byte escape rule** is here, pure, for whatever must turn
bytes that are not a text into one, or a text back into bytes, as the
library does: the file model (`Editor/File/Model.lean`) and the shell's
output and filters (`packages/shell/Shell.lean`). `File.decodeBytes` keeps each
valid character as it is, each byte that starts none as its escape
(`File.escape`, the character `U+10DC00` plus the byte) and a valid
character that is itself an escape as the escapes of its bytes, so the way
back, `File.encodeText`, is one-to-one.

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

/-- The escape of `byte`: the character the text store keeps a byte that is
not valid UTF-8 as, `U+10DC00` plus the byte. -/
def escape (byte : UInt8) : Char :=
  Char.ofNat (0x10DC00 + byte.toNat)

/-- The byte `character` is the escape of, if it is one: the escapes are the
128 characters from `U+10DC80` to `U+10DCFF`. -/
def escaped? (character : Char) : Option UInt8 :=
  if 0x10DC80 ≤ character.toNat ∧ character.toNat ≤ 0x10DCFF then
    some (character.toNat - 0x10DC00).toUInt8
  else none

/-- The text the store keeps `bytes` as: each valid character as it is,
each byte that starts none as its escape, and a valid character that is
itself an escape as the escapes of its four bytes.

It walks the bytes a character at a time. Each step takes at least one byte,
so the walk is over in at most as many steps as there are bytes. -/
def decodeBytes (bytes : ByteArray) : String :=
  Id.run do
    let mut text := ""
    let mut index := 0
    for _ in [0:bytes.size] do
      if index ≥ bytes.size then
        break
      match bytes.utf8DecodeChar? index with
      | some character =>
        if (escaped? character).isSome then
          for offset in [0:character.utf8Size] do
            text := text.push (escape (bytes.get! (index + offset)))
        else
          text := text.push character
        index := index + character.utf8Size
      | none =>
        text := text.push (escape (bytes.get! index))
        index := index + 1
    return text

/-- The bytes of `text` as a save writes them: an escape as the one byte it
stands for, and every other character as its UTF-8. -/
def encodeText (text : String) : ByteArray :=
  text.foldl
    (fun bytes character =>
      match escaped? character with
      | some byte => bytes.push byte
      | none => bytes ++ (String.singleton character).toUTF8)
    ByteArray.empty

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

/-- What kind of thing a directory's entry is, links followed. -/
inductive Kind where
  /-- A file. -/
  | file
  /-- A directory. -/
  | directory
  /-- Anything else: a pipe, a socket, a device, or a link to nothing. -/
  | other
  deriving DecidableEq, Repr

/-- One thing a directory holds: its name in the directory and its kind. -/
structure Entry where
  /-- Its name in the directory. -/
  name : String
  /-- What kind of thing it is. -/
  kind : Kind
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
  /-- What is at the path, or on the way to it, is not a directory: a
  listing's refusal, and a directory made's. -/
  | notADirectory
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
  | .notADirectory => "what is at the path is not a directory"
  | .denied => "the file system does not allow it"
  | .binary offset => s!"the file is binary: it has a NUL byte at offset {offset}"
  | .tooLarge size limit => s!"the file is {size} bytes long, over the limit of {limit}"
  | .changed none => "the file on disk is not the one that was expected: there is no file now"
  | .changed (some stamp) =>
    s!"the file on disk is not the one that was expected: it is {stamp.size} bytes long and was modified at {stamp.seconds} s and {stamp.nanoseconds} ns"
  | .noSuchSnapshot => "the save names no snapshot"
  | .noTemporaryName => "no name was free for the save's temporary file"
  | .failed detail => s!"the file request failed: {detail}"

/-- Bytes an append carries, as a request is shown: the list of their values.
Private, for the request's `Repr` alone. -/
private instance : Repr ByteArray :=
  ⟨fun bytes precedence => reprPrec bytes.toList precedence⟩

/-- What a job may ask of files. A new file request is a constructor here. -/
inductive FileRequest where
  /-- Load the file at `path`, unless it is longer than `limit` bytes. -/
  | load (path : System.FilePath) (limit : Nat)
  /-- Save what `source` holds as the file at `path`, if what is there is
  what `expect` says. -/
  | save (source : File.Source) (path : System.FilePath) (expect : File.Expect)
  /-- The stamp of the file at `path`, or `none` when nothing is there. -/
  | stamp (path : System.FilePath)
  /-- What the directory at `path` holds, sorted by name. -/
  | list (path : System.FilePath)
  /-- Make the directory at `path`, and every directory on the way to it. -/
  | makeDirectory (path : System.FilePath)
  /-- Add `bytes` to the end of the file at `path`, making the file when
  nothing is there. -/
  | append (path : System.FilePath) (bytes : ByteArray)
  /-- Remove the file at `path`; nothing there is no error. -/
  | remove (path : System.FilePath)
  deriving DecidableEq, Repr

/-- The type of the reply to each file request: a refusal or the result. A
refusal is a value, never a throw. -/
def FileRequest.Reply : FileRequest → Type
  | .load .. => Except FileError File.Loaded
  | .save .. => Except FileError File.Stamp
  | .stamp _ => Except FileError (Option File.Stamp)
  | .list _ => Except FileError (Array File.Entry)
  | .makeDirectory _ => Except FileError Unit
  | .append .. => Except FileError Unit
  | .remove _ => Except FileError Unit

/-- The refusal a reply to `request` holds; `none` for a result. -/
def FileRequest.refusal : (request : FileRequest) → request.Reply → Option FileError
  | .load .., reply =>
    match (reply : Except FileError File.Loaded) with
    | .error error => some error
    | .ok _ => none
  | .save .., reply =>
    match (reply : Except FileError File.Stamp) with
    | .error error => some error
    | .ok _ => none
  | .stamp _, reply =>
    match (reply : Except FileError (Option File.Stamp)) with
    | .error error => some error
    | .ok _ => none
  | .list _, reply =>
    match (reply : Except FileError (Array File.Entry)) with
    | .error error => some error
    | .ok _ => none
  | .makeDirectory _, reply =>
    match (reply : Except FileError Unit) with
    | .error error => some error
    | .ok _ => none
  | .append .., reply =>
    match (reply : Except FileError Unit) with
    | .error error => some error
    | .ok _ => none
  | .remove _, reply =>
    match (reply : Except FileError Unit) with
    | .error error => some error
    | .ok _ => none

end Editor
