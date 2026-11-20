import Editor.Diff
import Editor.Diff.Model
import Editor.File
import Editor.Text.Model

/-!
# The pure model of the files a job reaches

The files a job's requests reach, as a value: the directories there are, the
files with their bytes and their stamps, and the snapshots a request may
name. `FileModel.handle` answers each file request (`Editor/File.lean`) as a
pure function, with no disk and no library, so the logic above the job port
is tested by `lake test` alone. The job port's model hands its file requests
to it (`JobModel.files`, `Editor/Job/Model.lean`), and the fake of the job
runner's file service is this model behind a reference
(`Editor/Job/Fake.lean`).

## What it holds

- **The directories and the files**, by path. A path names a file only by
  being the same string: the model has no links, no working directory and no
  permissions.
- **A count of writes, which stands for the clock.** Every write gets the
  next instant as the seconds of its stamp, so in the model every write
  changes a file's stamp. A real file system's clock has a granularity, and
  a write inside it that keeps the size is not seen; that limit is the
  library's, pinned there (`crates/editor-text`, `file`).
- **Two tables of snapshots**, each a text's content. `snapshots` is what
  the editor has published, in the shape of `TextModel.snapshots`, where a
  `SnapshotId` is an index: a request reads it and never changes it. `held`
  is what the job's loads made, where a `JobSnapshotId` is an index. Handing
  a job a snapshot is handing it the value, in both directions: whoever
  plays a command, then a job, then the job's command starts the job's
  model with the text model's `snapshots`, and hands the job's command what
  the job's model `held` (`TextModel.arrived`).

## How it answers

It answers by the library's rules and by its own route.

- **The text of a file** is found by decoding its bytes a character at a
  time (`FileModel.decode`, which is the store's rule, `File.decodeBytes`,
  in `Editor/File.lean`): a byte that starts no valid character becomes
  its escape, the character `U+10DC00` plus the byte, and a character that
  is validly encoded but is itself one of the escapes becomes the escapes of
  its four bytes, so that the way back is one-to-one. What a save writes is
  the reverse (`FileModel.encode`, `File.encodeText`). The library finds
  the valid stretches of the bytes and builds a rope; that the two agree is
  what the job port's contract checks.
- **A load is refused in this order**: a path that is not absolute; nothing
  there, or a directory; a file over the limit; a NUL byte among the first
  8,000 bytes.
- **A save is refused in this order**: a source that names no snapshot; a
  path that is not absolute; a directory at the path; a file that is not
  what the save expects; a directory that is not there.
- **A stamp request is refused in this order**: a path that is not absolute;
  a directory. Nothing there is `none`.
- **A listing is refused in this order**: a path that is not absolute;
  nothing there (`notFound`); a file (`notADirectory`); a directory named in
  `unreadable` (`denied`). It answers the directories and files whose parent
  is the path, by file name, sorted. Each list request's directory, past
  the relative check, is recorded in `listed`, refused or not: a test counts
  the reads with it.
- **A directory made is refused in this order**: a path that is not
  absolute; a file at the path or on the way to it (`notADirectory`).
  Otherwise the path and every path on the way to it are directories after
  it, the root included; one already there is no error.
- **An append is refused in this order**: a path that is not absolute; a
  directory at the path, or a file on the way to it (`notAFile`); a
  directory it is in that is not there (`notFound`). Otherwise the file
  holds what it held, or nothing, and then the bytes, written now.
- **A remove is refused in this order**: a path that is not absolute; a
  directory at the path (`notAFile`). Nothing there is no error.
- It has no temporary file, no link and no permissions: how a save reaches
  the disk is the library's, pinned in Rust on the file port's fake.

The contract (`JobContract.fileProperties`, `Editor/Job/Contract.lean`) is
what says the model, the fake and the library agree. A clause added to
`FileModel.handle` needs its property there.
-/

namespace Editor

/-- One file of the model. -/
structure FileModel.File where
  /-- Where it is. -/
  path : System.FilePath
  /-- What it holds. -/
  bytes : ByteArray
  /-- Its stamp: the instant of the write that made it, and its length. -/
  stamp : File.Stamp
  deriving DecidableEq

/-- The model of the files a job reaches. -/
structure FileModel where
  /-- The directories there are. -/
  directories : Array System.FilePath := #[]
  /-- The files there are. -/
  files : Array FileModel.File := #[]
  /-- How many writes there have been: the model's clock. -/
  writes : Nat := 0
  /-- What the editor has published: the snapshots of the text store, where
  a `SnapshotId` is an index. A request reads it and never changes it. -/
  snapshots : Array (Option TextContent) := #[]
  /-- What the job's loads made, where a `JobSnapshotId` is an index. A slot
  is `none` once its snapshot has been released. -/
  held : Array (Option TextContent) := #[]
  /-- The directories a listing refuses with `denied`: a knob a test sets, as
  it sets the files. -/
  unreadable : Array System.FilePath := #[]
  /-- Each directory a list request named, past the relative check, oldest
  first, whether it was refused or not: the reads a test counts. -/
  listed : Array System.FilePath := #[]
  deriving DecidableEq

namespace FileModel

/-- How many of a file's first bytes are looked at for a NUL byte. -/
def binaryWindow : Nat :=
  8000

/-- The escape of `byte` (`File.escape`). -/
def escape (byte : UInt8) : Char :=
  File.escape byte

/-- The byte `character` is the escape of, if it is one (`File.escaped?`). -/
def escaped? (character : Char) : Option UInt8 :=
  File.escaped? character

/-- The text the library keeps `bytes` as (`File.decodeBytes`). -/
def decode (bytes : ByteArray) : String :=
  File.decodeBytes bytes

/-- The bytes of `text` as a save writes them (`File.encodeText`). -/
def encode (text : String) : ByteArray :=
  File.encodeText text

/-- The line endings of `bytes`: the line feeds that stand alone, and those
that follow a carriage return. -/
def lineEndings (bytes : ByteArray) : File.LineEndings :=
  Id.run do
    let mut endings : File.LineEndings := ⟨0, 0⟩
    for index in [0:bytes.size] do
      if bytes.get! index == 0x0A then
        if index > 0 && bytes.get! (index - 1) == 0x0D then
          endings := { endings with crlf := endings.crlf + 1 }
        else
          endings := { endings with lf := endings.lf + 1 }
    return endings

/-- The offset of the first NUL byte among the first `binaryWindow` bytes of
`bytes`, if there is one: what makes a file binary. -/
def firstNul? (bytes : ByteArray) : Option Nat :=
  (List.range (min binaryWindow bytes.size)).find? (bytes.get! · == 0)

/-- The model with the directory `path`. -/
def withDirectory (model : FileModel) (path : System.FilePath) : FileModel :=
  { model with directories := model.directories.push path }

/-- The model after `bytes` are written as the file at `path`, in place of
any file there, and the stamp the file then has: the next instant, and the
length of `bytes`. -/
def written (model : FileModel) (path : System.FilePath) (bytes : ByteArray) :
    File.Stamp × FileModel :=
  let stamp : File.Stamp := { seconds := model.writes + 1, nanoseconds := 0, size := bytes.size }
  (stamp,
    { model with
      files := (model.files.filter (·.path != path)).push { path, bytes, stamp }
      writes := model.writes + 1 })

/-- The model with the file `path` holding `bytes`, written now. -/
def withFile (model : FileModel) (path : System.FilePath) (bytes : ByteArray) : FileModel :=
  (model.written path bytes).2

/-- The file at `path`, if there is one. -/
def file? (model : FileModel) (path : System.FilePath) : Option File :=
  model.files.find? (·.path == path)

/-- Every file there is, as its path and its bytes, in the order they were
last written. This is what a test compares with the files it expects. -/
def contents (model : FileModel) : Array (System.FilePath × ByteArray) :=
  model.files.map fun file => (file.path, file.bytes)

/-- The content `source` names: a snapshot the editor published, or one the
job's loads made. `none` when it names nothing, or something released. -/
def source? (model : FileModel) : File.Source → Option TextContent
  | .snapshot id => (model.snapshots[id.index]?).join
  | .held id => (model.held[id.number]?).join

/-- The model after the job's snapshot `id` is released: its slot is emptied
and stays, so later ids are what they would have been. -/
def released (model : FileModel) (id : JobSnapshotId) : FileModel :=
  { model with held := model.held.setIfInBounds id.number none }

/-- The model's answer to a load of the file at `path` with the limit
`limit`, and the model after it: a load that succeeds adds the file's text
to what the job holds, under the next `JobSnapshotId`. A refused load leaves
the model as it was. -/
def load (model : FileModel) (path : System.FilePath) (limit : Nat) :
    Except FileError File.Loaded × FileModel :=
  if !path.isAbsolute then (.error .relativePath, model)
  else
    if model.directories.contains path then (.error .notAFile, model)
    else
      match model.file? path with
      | none => (.error .notFound, model)
      | some file =>
        if file.bytes.size > limit then (.error (.tooLarge file.bytes.size limit), model)
        else
          match firstNul? file.bytes with
          | some offset => (.error (.binary offset), model)
          | none =>
            (.ok {
                  snapshot := ⟨model.held.size⟩, stamp := file.stamp
                  endings := lineEndings file.bytes },
              { model with held := model.held.push (some { contents := decode file.bytes }) })

/-- Whether `found`, the stamp of the file at a path or `none` for no file,
is what `expect` says a save is to find. Stamps are compared for equality. -/
def asExpected (found : Option File.Stamp) : File.Expect → Bool
  | .unchanged stamp => found == some stamp
  | .absent => found.isNone
  | .whatever => true

/-- The model's answer to a save of `source` as the file at `path`, expecting
`expect`, and the model after it. A refused save leaves the model as it
was. -/
def save (model : FileModel) (source : File.Source) (path : System.FilePath)
    (expect : File.Expect) : Except FileError File.Stamp × FileModel :=
  match model.source? source with
  | none => (.error .noSuchSnapshot, model)
  | some content =>
    if !path.isAbsolute then (.error .relativePath, model)
    else
      if model.directories.contains path then (.error .notAFile, model)
      else
        let found := (model.file? path).map (·.stamp)
        if !asExpected found expect then (.error (.changed found), model)
        else
          if !path.parent.any model.directories.contains then (.error .notFound, model)
          else
            let (stamp, model) := model.written path (encode content.contents)
            (.ok stamp, model)

/-- The model's answer to a stamp request for `path`: the stamp of the file
there, `none` for nothing. A path that is not absolute and a directory are
refused. -/
def stamp (model : FileModel) (path : System.FilePath) : Except FileError (Option File.Stamp) :=
  if !path.isAbsolute then .error .relativePath
  else
    if model.directories.contains path then .error .notAFile
    else .ok ((model.file? path).map (·.stamp))

/-- The model's answer to a listing of `path`, and the model after it, which
records the read in `listed` once the path is absolute. The entries are the
directories and the files whose parent is `path`, by file name, sorted. -/
def list (model : FileModel) (path : System.FilePath) :
    Except FileError (Array File.Entry) × FileModel :=
  if !path.isAbsolute then (.error .relativePath, model)
  else
    let model := { model with listed := model.listed.push path }
    if (model.file? path).isSome then (.error .notADirectory, model)
    else
      if !model.directories.contains path then (.error .notFound, model)
      else
        if model.unreadable.contains path then (.error .denied, model)
        else
          let named (child : System.FilePath) (kind : File.Kind) : Option File.Entry :=
            if child.parent == some path then (child.fileName.map fun name => { name, kind })
            else none
          let entries :=
            model.directories.filterMap (named · .directory) ++
              model.files.filterMap fun file => named file.path .file
          (.ok (entries.qsort (·.name < ·.name)), model)

/-- The model's answer to making the directory at `path`, and the model
after it: the path and every path on the way to it are directories. A
refused request leaves the model as it was. -/
def makeDirectory (model : FileModel) (path : System.FilePath) :
    Except FileError Unit × FileModel :=
  if !path.isAbsolute then (.error .relativePath, model)
  else
    let rec onTheWay (fuel : Nat) (here : System.FilePath) (found : Array System.FilePath) :
      Array System.FilePath :=
      match fuel, here.parent with
      | fuel + 1, some parent =>
        if parent == here then found.push here else onTheWay fuel parent (found.push here)
      | _, _ => found.push here
    let paths := onTheWay path.components.length path #[]
    if paths.any (model.file? · |>.isSome) then (.error .notADirectory, model)
    else
      let model :=
        paths.foldl (init := model) fun model here =>
          if model.directories.contains here then model else model.withDirectory here
      (.ok (), model)

/-- The paths on the way to `path`, nearest first, the root included, and
not `path` itself. -/
def onTheWay (path : System.FilePath) : Array System.FilePath :=
  let rec walk (fuel : Nat) (here : System.FilePath) (found : Array System.FilePath) :
    Array System.FilePath :=
    match fuel, here.parent with
    | fuel + 1, some parent =>
      if parent == here then found else walk fuel parent (found.push parent)
    | _, _ => found
  walk path.components.length path #[]

/-- The model's answer to appending `bytes` to the file at `path`, and the
model after it: the file holds what it held, or nothing when there was no
file, and then `bytes`, written now. A refused append leaves the model as it
was. -/
def append (model : FileModel) (path : System.FilePath) (bytes : ByteArray) :
    Except FileError Unit × FileModel :=
  if !path.isAbsolute then (.error .relativePath, model)
  else
    if model.directories.contains path || (onTheWay path).any (model.file? · |>.isSome) then
      (.error .notAFile, model)
    else
      if !path.parent.any model.directories.contains then (.error .notFound, model)
      else
        let held := ((model.file? path).map (·.bytes)).getD ByteArray.empty
        (.ok (), (model.written path (held ++ bytes)).2)

/-- The model's answer to removing the file at `path`, and the model after
it: no file there. Nothing there is no error; a directory is refused. -/
def remove (model : FileModel) (path : System.FilePath) : Except FileError Unit × FileModel :=
  if !path.isAbsolute then (.error .relativePath, model)
  else
    if model.directories.contains path then (.error .notAFile, model)
    else (.ok (), { model with files := model.files.filter (·.path != path) })

/-- The model's answer to each file request, and the model after it. -/
def handle : (request : FileRequest) → FileModel → request.Reply × FileModel
  | .load path limit, model => model.load path limit
  | .save source path expect, model => model.save source path expect
  | .stamp path, model => (model.stamp path, model)
  | .list path, model => model.list path
  | .makeDirectory path, model => model.makeDirectory path
  | .append path bytes, model => model.append path bytes
  | .remove path, model => model.remove path

/-- The model's answer to a diff request (`Editor/Diff.lean`), over the
snapshots it holds: the script or the hunks of the model of a line diff
(`DiffModel.script`, `DiffModel.hunks`), or `noSuchSnapshot` for a source that names nothing. It
changes nothing, so it hands back no model. -/
def diff (model : FileModel) : (request : DiffRequest) → request.Reply
  | .lines old new limit =>
    match model.source? old, model.source? new with
    | some old, some new => .ok (DiffModel.script old.contents new.contents limit)
    | _, _ => .error .noSuchSnapshot
  | .hunks old new limit =>
    match model.source? old, model.source? new with
    | some old, some new => .ok (DiffModel.hunks old.contents new.contents limit)
    | _, _ => .error .noSuchSnapshot

end FileModel

end Editor
