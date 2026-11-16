import Editor.File.Model
import Editor.Job
import Editor.Process.Model

/-!
# The contract of the job port

What every implementation of the job port (`Editor/Job.lean`) does, as one
list of properties. A property is a job that returns whether it held, so the
same list runs three ways:

- against the pure model (`Editor/Job/Model.lean`), by `model-test`;
- against the runner over the fake clock (`Editor/Job/Runner.lean`,
  `Editor/Job/Fake.lean`), by `model-test`;
- against the runner over the Rust library's timer service
  (`Editor/Job/Real.lean`), by `contract-test`.

That is what keeps the model, the fake clock and the library from drifting
apart.

The file requests have a list of their own, `fileProperties`, further down,
run the same three ways: against the model, against the runner over the
fake of the file service, and against the runner over the library's file
service on real files in a temporary directory. So do the process requests,
`processProperties`, at the end: against the model and the fake, which a
property's scripts tell what each command does, and against the library's
process service on real processes, each property in a temporary directory,
which is what shows those scripts true. And so do the watch requests,
`fileWatchProperties`, last: against the model and the fake, which each
property's scripts tell what each command changes on disk, and against the
library's watch service on real files, each property in a temporary
directory.

Every property is an inequality. A real clock only promises "not before": a
wait may return late, and time passes between two requests. So nothing here
says a clock reads exactly some instant, and durations are 0 to 3 ms, so the
run against the real clock takes milliseconds. What needs equality (that a
timer does not drift) is checked against the model alone, where the clock is
exact (`ModelTest.jobModelChecks`).

This module imports only the port. The list is plain data, jobs that have
not run, so it is a constant: nothing in it calls the library when the module
is initialised.
-/

namespace Editor.JobContract

/-- One property of the job port: a job that observes it. -/
structure Property where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the property; `true` when it holds. A job that fails or is
  cancelled has not held. -/
  holds : JobM Bool

/-- The properties every implementation of the job port has. -/
def properties : List Property :=
  [{ name := "the clock does not go back across a wait",
     holds := do
       let before ← now
       sleep 1
       let between ← now
       waitUntil (between + 1)
       return before ≤ between && between ≤ (← now) },
    { name := "after a sleep the clock has moved by at least its duration, and a sleep of 0 returns"
      holds := do
        let before ← now
        sleep 3
        let after ← now
        sleep 0
        return before + 3 ≤ after && after ≤ (← now) },
    { name := "waitUntil an instant that has passed returns, and does not move the clock back"
      holds := do
        sleep 2
        let before ← now
        waitUntil 0
        waitUntil (before - 1)
        return before ≤ (← now) },
    { name := "after waitUntil the clock reads at least its deadline"
      holds := do
        let deadline := (← now) + 3
        waitUntil deadline
        return deadline ≤ (← now) },
    { name :=
        "a timer's third tick is not before its start plus three periods, with work between the ticks"
      holds := do
        let start ← now
        let timer ← Timer.every 2
        let timer ← timer.tick
        sleep 1
        let timer ← timer.tick
        sleep 1
        discard timer.tick
        return start + 6 ≤ (← now) },
    { name :=
        "a throw after a wait is caught by the job's own handler, with its message, and the job goes on to wait again"
      holds := do
        let caught ←
          try
            sleep 1
            throw "no thanks"
          catch message =>
            pure (message == "no thanks")
        sleep 1
        return caught }]

/-- Runs each of `properties` with `run` and returns the names of those that
did not hold. A property whose job failed or was cancelled has not held, and
is named with how it ended. -/
def failures (run : JobM Bool → IO (Job.Outcome Bool)) (properties : List Property) :
    IO (List String) :=
  properties.filterMapM fun property => do
    match ← run property.holds with
    | .finished true =>
      return none
    | .finished false =>
      return some property.name
    | .failed message =>
      return some s!"{property.name} (the job failed with `{message}`)"
    | .cancelled =>
      return some s!"{property.name} (the job was cancelled)"

/-! ## The file requests

A property of the file requests (`Editor/File.lean`) is the files there are
to start with, a job that is given the directory they are in and returns
whether it held, and every file that must be in that directory afterwards:
so a file that should not have been written, a temporary file left behind
among them, fails the property. Whoever runs the list makes the directory:
the model and the fake of the file service are given a made-up absolute
path, and the library's service a temporary directory.

A stamp is never compared with a literal: what a file's modification time
reads is the file system's. A property compares a stamp with another the
same run got, and a size with the file's length. No property needs two
writes of one length to have different stamps: a file system's clock has a
granularity, and inside it they do not. -/

/-- One property of the job port's file requests. -/
structure FileProperty where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- The files there are to start with, each a name in the directory and
  its bytes. -/
  files : Array (String × ByteArray)
  /-- Observes the property, given the directory, an absolute path; `true`
  when it holds. A job that fails or is cancelled has not held. -/
  holds : System.FilePath → JobM Bool
  /-- Every file that must be in the directory afterwards, each a name and
  its bytes, in any order. -/
  after : Array (String × ByteArray)

/-- A file with LF line endings: two- and four-byte characters. -/
def lfFile : ByteArray :=
  "héllo\nwörld\n😀\n".toUTF8

/-- The same lines with CRLF line endings. -/
def crlfFile : ByteArray :=
  "héllo\r\nwörld\r\n😀\r\n".toUTF8

/-- A file that is not UTF-8, with mixed endings: "a", a carriage return and
a line feed, "b", a line feed, the bytes `E9` and `FF`, the reserved code
point `U+10DC80` validly encoded, "😀", a carriage return alone, and "z",
with no final newline. Seventeen bytes. -/
def rawFile : ByteArray :=
  ⟨#[0x61, 0x0D, 0x0A, 0x62, 0x0A, 0xE9, 0xFF, 0xF4, 0x8D, 0xB2, 0x80, 0xF0, 0x9F, 0x98, 0x80, 0x0D,
      0x7A]⟩

/-- Another file, of another length: "wörld😀", a line feed and the byte
`FE`. Twelve bytes. -/
def otherFile : ByteArray :=
  ⟨#[0x77, 0xC3, 0xB6, 0x72, 0x6C, 0x64, 0xF0, 0x9F, 0x98, 0x80, 0x0A, 0xFE]⟩

/-- A file of `size` bytes, each "a" but for a NUL byte at `nul`. -/
def withNul (size nul : Nat) : ByteArray :=
  ⟨(Array.replicate size (0x61 : UInt8)).setIfInBounds nul 0⟩

/-- A limit no file here is over, for a load whose limit is not what its
property is about. -/
def roomy : Nat :=
  1000000

/-- Loads the file at `path`; a refusal fails the job, saying which. -/
def loaded (path : System.FilePath) (limit : Nat := roomy) : JobM File.Loaded := do
  match ← File.load path limit with
  | .ok file =>
    return file
  | .error error =>
    throw s!"the load of {path} was refused: {error.describe}"

/-- Saves `source` to `path`; a refusal fails the job, saying which. -/
def saved (source : File.Source) (path : System.FilePath) (expect : File.Expect) :
    JobM File.Stamp := do
  match ← File.save source path expect with
  | .ok stamp =>
    return stamp
  | .error error =>
    throw s!"the save to {path} was refused: {error.describe}"

/-- Whether a load of `path` under `limit` is refused with `error`. -/
def loadRefusedAs (error : FileError) (path : System.FilePath) (limit : Nat := roomy) : JobM Bool :=
  do
  match ← File.load path limit with
  | .ok _ =>
    return false
  | .error refusal =>
    return refusal == error

/-- Whether a save of `source` to `path` expecting `expect` is refused with
`error`. -/
def saveRefusedAs (error : FileError) (source : File.Source) (path : System.FilePath)
    (expect : File.Expect) : JobM Bool := do
  match ← File.save source path expect with
  | .ok _ =>
    return false
  | .error refusal =>
    return refusal == error

/-- Whether the stat `reply` is `expected`: the same stamp, or the same
refusal. -/
def statIs (reply expected : Except FileError File.Stamp) : Bool :=
  match reply, expected with
  | .ok stamp, .ok other => stamp == other
  | .error error, .error other => error == other
  | _, _ => false

/-- The round trip of a file holding `bytes`: loaded, saved to a second path
and saved over itself, with no edit between, it is byte for byte what it
was in both places. -/
def roundTrip (what : String) (bytes : ByteArray) : FileProperty where
  name :=
    s!"a file loaded and saved without edits is byte for byte what it was, saved to a second path and over itself: {what}"
  files := #[("a.txt", bytes)]
  holds root := do
    let file ← loaded (root / "a.txt")
    let copy ← saved (.held file.snapshot) (root / "b.txt") .absent
    let over ← saved (.held file.snapshot) (root / "a.txt") (.unchanged file.stamp)
    return file.stamp.size == bytes.size && copy.size == bytes.size && over.size == bytes.size
  after := #[("a.txt", bytes), ("b.txt", bytes)]

/-- The properties every implementation of the job port's file requests
has. -/
def fileProperties : List FileProperty :=
  [{  name :=
        "a stat answers a load's stamp, and after a save a stamp that differs and that the next save expects; nothing there is notFound, a directory notAFile and a relative path relativePath"
      files := #[("a.txt", rawFile), ("b.txt", otherFile)]
      holds := fun root => do
        let file ← loaded (root / "a.txt")
        let other ← loaded (root / "b.txt")
        let atLoad ← File.stat (root / "a.txt")
        let written ← saved (.held other.snapshot) (root / "a.txt") (.unchanged file.stamp)
        let afterSave ← File.stat (root / "a.txt")
        let again ←
          match afterSave with
          | .ok stamp =>
            saved (.held other.snapshot) (root / "a.txt") (.unchanged stamp)
          | .error error =>
            throw s!"the stat after the save was refused: {error.describe}"
        let missing ← File.stat (root / "none.txt")
        let directory ← File.stat root
        let relative ← File.stat "a.txt"
        return statIs atLoad (.ok file.stamp) && statIs afterSave (.ok written) &&
            written != file.stamp &&
            again.size == otherFile.size &&
            statIs missing (.error .notFound) &&
            statIs directory (.error .notAFile) &&
            statIs relative (.error .relativePath)
      after := #[("a.txt", otherFile), ("b.txt", otherFile)] }, roundTrip "LF line endings" lfFile,
    roundTrip "CRLF line endings" crlfFile,
    roundTrip
      "bytes that are not UTF-8, with mixed endings, a reserved code point, a four-byte character and no final newline"
      rawFile,
    { name :=
        "a load counts the file's line endings and changes none: line feeds alone, line feeds after a carriage return, both, and a carriage return alone as neither"
      files :=
        #[("lf.txt", lfFile), ("crlf.txt", crlfFile), ("mixed.txt", rawFile),
          ("cr.txt", "é\rb".toUTF8)]
      holds := fun root => do
        return (← loaded (root / "lf.txt")).endings == ⟨3, 0⟩ &&
            (← loaded (root / "crlf.txt")).endings == ⟨0, 3⟩ &&
            (← loaded (root / "mixed.txt")).endings == ⟨1, 1⟩ &&
            (← loaded (root / "cr.txt")).endings == ⟨0, 0⟩
      after :=
        #[("lf.txt", lfFile), ("crlf.txt", crlfFile), ("mixed.txt", rawFile),
          ("cr.txt", "é\rb".toUTF8)] },
    { name :=
        "a loaded stamp's size is the file's length in bytes, not its text's: three bytes, two of them not UTF-8, are three"
      files := #[("raw.txt", ⟨#[0x61, 0xFF, 0xE9]⟩)]
      holds := fun root => do
        return (← loaded (root / "raw.txt")).stamp.size == 3
      after := #[("raw.txt", ⟨#[0x61, 0xFF, 0xE9]⟩)] },
    { name :=
        "a file with a NUL byte at offset 7,999 is refused as binary, with the offset, and a file whose first NUL byte is at offset 8,000 loads"
      files := #[("early", withNul 8001 7999), ("late", withNul 8001 8000)]
      holds := fun root => do
        let early ← loadRefusedAs (.binary 7999) (root / "early")
        return early && (← loaded (root / "late")).stamp.size == 8001
      after := #[("early", withNul 8001 7999), ("late", withNul 8001 8000)] },
    { name :=
        "a file one byte over the limit is refused as too large, with its size and the limit, and at the limit it loads"
      files := #[("a.txt", rawFile)]
      holds := fun root => do
        let over ← loadRefusedAs (.tooLarge 17 16) (root / "a.txt") 16
        return over && (← loaded (root / "a.txt") 17).stamp.size == 17
      after := #[("a.txt", rawFile)] },
    { name :=
        "nothing at the path is not found, a directory is not a file, and a path that is not absolute is refused, for a load and for a save"
      files := #[("a.txt", rawFile)]
      holds := fun root => do
        let file ← loaded (root / "a.txt")
        let missing ← loadRefusedAs .notFound (root / "missing.txt")
        let directory ← loadRefusedAs .notAFile root
        let relative ← loadRefusedAs .relativePath "relative.txt"
        let saveRelative ←
          saveRefusedAs .relativePath (.held file.snapshot) "relative.txt" .whatever
        let saveDirectory ← saveRefusedAs .notAFile (.held file.snapshot) root .whatever
        return missing && directory && relative && saveRelative && saveDirectory
      after := #[("a.txt", rawFile)] },
    { name :=
        "a save that expects no file makes one, and one that expects none where there is one is refused as changed, with the stamp of the file there, which is as it was"
      files := #[("a.txt", rawFile), ("b.txt", otherFile)]
      holds := fun root => do
        let file ← loaded (root / "a.txt")
        let there ← loaded (root / "b.txt")
        let made ← saved (.held file.snapshot) (root / "new.txt") .absent
        let refused ←
          saveRefusedAs (.changed (some there.stamp)) (.held file.snapshot) (root / "b.txt") .absent
        return made.size == 17 && refused
      after := #[("a.txt", rawFile), ("b.txt", otherFile), ("new.txt", rawFile)] },
    { name :=
        "a file changed since it was loaded is not overwritten: a save with the stamp it was loaded with is refused as changed, with the stamp now on disk, and the file holds what changed it; saved again whatever is there, it holds what was loaded"
      files := #[("a.txt", rawFile), ("b.txt", otherFile)]
      holds := fun root => do
        let file ← loaded (root / "a.txt")
        let other ← loaded (root / "b.txt")
        let changed ← saved (.held other.snapshot) (root / "a.txt") .whatever
        let refused ←
          saveRefusedAs (.changed (some changed)) (.held file.snapshot) (root / "a.txt")
              (.unchanged file.stamp)
        -- The file is the other's still: twelve bytes, with its endings.
        let between ← loaded (root / "a.txt")
        let forced ← saved (.held file.snapshot) (root / "a.txt") .whatever
        return changed.size == 12 && refused && between.stamp == changed &&
            between.endings == ⟨1, 0⟩ &&
            forced.size == 17
      after := #[("a.txt", rawFile), ("b.txt", otherFile)] },
    { name :=
        "the stamp a save returns is accepted by the next save, and the stamp that one returns by the one after"
      files := #[("a.txt", rawFile)]
      holds := fun root => do
        let file ← loaded (root / "a.txt")
        let first ← saved (.held file.snapshot) (root / "c.txt") .absent
        let second ← saved (.held file.snapshot) (root / "c.txt") (.unchanged first)
        let third ← saved (.held file.snapshot) (root / "c.txt") (.unchanged second)
        return [first, second, third].all (·.size == 17)
      after := #[("a.txt", rawFile), ("c.txt", rawFile)] },
    { name :=
        "a save of a source that names no snapshot is refused before its path is looked at, and writes nothing: a snapshot the job never loaded, and one nothing published"
      files := #[("a.txt", rawFile)]
      holds := fun root => do
        let file ← loaded (root / "a.txt")
        let never : JobSnapshotId := ⟨file.snapshot.number + 1⟩
        -- The path is not absolute, which would be refused as that.
        let held ← saveRefusedAs .noSuchSnapshot (.held never) "relative.txt" .whatever
        let published ← saveRefusedAs .noSuchSnapshot (.snapshot ⟨0⟩) "relative.txt" .whatever
        let nothing ← saveRefusedAs .noSuchSnapshot (.held never) (root / "new.txt") .absent
        let unpublished ← saveRefusedAs .noSuchSnapshot (.snapshot ⟨0⟩) (root / "new.txt") .absent
        return held && published && nothing && unpublished
      after := #[("a.txt", rawFile)] },
    { name :=
        "a save into a directory that is not there is not found, once what it expects is met: expecting a file's stamp there is refused first, as changed with no file found"
      files := #[("a.txt", rawFile)]
      holds := fun root => do
        let file ← loaded (root / "a.txt")
        let absent ← saveRefusedAs .notFound (.held file.snapshot) (root / "none" / "a.txt") .absent
        let whatever ←
          saveRefusedAs .notFound (.held file.snapshot) (root / "none" / "a.txt") .whatever
        let expected ←
          saveRefusedAs (.changed none) (.held file.snapshot) (root / "none" / "a.txt")
              (.unchanged file.stamp)
        return absent && whatever && expected
      after := #[("a.txt", rawFile)] },
    { name :=
        "errors are values: after a load and a save are refused the job goes on, makes further requests, catches an error it threw itself from a refusal's description, and finishes"
      files := #[("a.txt", rawFile)]
      holds := fun root => do
        let .error missing ← File.load (root / "missing.txt") roomy | return false
        let file ← loaded (root / "a.txt")
        let .error taken ← File.save (.held file.snapshot) (root / "a.txt") .absent | return false
        let caught ←
          try
            throw missing.describe
          catch message =>
            pure (message == FileError.notFound.describe)
        let made ← saved (.held file.snapshot) (root / "b.txt") .absent
        sleep 1
        return missing == .notFound && taken == .changed (some file.stamp) && caught &&
            made.size == 17
      after := #[("a.txt", rawFile), ("b.txt", rawFile)] },
    { name :=
        "the stamp of a file is the stamp a load of it answers; of nothing it is none; a directory is refused as notAFile and a relative path as relativePath"
      files := #[("a.txt", rawFile)]
      holds := fun root => do
        let file ← loaded (root / "a.txt")
        let stamp ← File.stamp (root / "a.txt")
        let missing ← File.stamp (root / "missing.txt")
        let directory ← File.stamp root
        let relative ← File.stamp "relative.txt"
        return (match stamp with
            | .ok (some stamp) => stamp == file.stamp
            | _ => false) &&
            (match missing with
            | .ok none => true
            | _ => false) &&
            (match directory with
            | .error .notAFile => true
            | _ => false) &&
            match relative with
            | .error .relativePath => true
            | _ => false
      after := #[("a.txt", rawFile)] },
    { name :=
        "a limit no machine word holds is not cut down: under a limit of 2^64 + 1, which cut down to a 64-bit word is 1, a file of seventeen bytes loads"
      files := #[("a.txt", rawFile)]
      holds := fun root => do
        return (← loaded (root / "a.txt") (2 ^ 64 + 1)).stamp.size == 17
      after := #[("a.txt", rawFile)] },
    { name :=
        "a stamp with a number no machine word holds is no file's stamp: a save that expects the file's stamp with 2^64 added to its size, 2^32 to its nanoseconds or 2^64 to its seconds is refused as changed, with the file's stamp, and the file is as it was"
      files := #[("a.txt", rawFile), ("b.txt", otherFile)]
      holds := fun root => do
        let file ← loaded (root / "a.txt")
        let other ← loaded (root / "b.txt")
        let refusedFor (stamp : File.Stamp) : JobM Bool :=
          saveRefusedAs (.changed (some file.stamp)) (.held other.snapshot) (root / "a.txt")
            (.unchanged stamp)
        let size ← refusedFor { file.stamp with size := file.stamp.size + 2 ^ 64 }
        let nanoseconds ←
          refusedFor { file.stamp with nanoseconds := file.stamp.nanoseconds + 2 ^ 32 }
        let seconds ← refusedFor { file.stamp with seconds := file.stamp.seconds + 2 ^ 64 }
        return size && nanoseconds && seconds
      after := #[("a.txt", rawFile), ("b.txt", otherFile)] }]

/-- `files` in the order of their names, to compare two sets of files. -/
def byName (files : Array (String × ByteArray)) : Array (String × ByteArray) :=
  files.qsort (·.1 < ·.1)

/-- Runs each of `properties` with `run`, which makes the property's files in
a directory of its own, runs the job with that directory and returns how the
job ended and the files then in the directory. Returns the names of those
that did not hold: a job that did not finish with `true`, and a directory
that does not hold exactly the files the property says, are named with what
was wrong. -/
def fileFailures (run : FileProperty → IO (Job.Outcome Bool × Array (String × ByteArray)))
    (properties : List FileProperty) : IO (List String) :=
  properties.filterMapM fun property => do
    let (outcome, files) ← run property
    match outcome with
    | .finished true =>
      if byName files == byName property.after then
        return none
      return some
          s!"{property.name} (the files afterwards are {(byName files).map (·.1)}, of {(byName files).map (·.2.size)} bytes)"
    | .finished false =>
      return some property.name
    | .failed message =>
      return some s!"{property.name} (the job failed with `{message}`)"
    | .cancelled =>
      return some s!"{property.name} (the job was cancelled)"

/-! ## The diff request

A property of the diff request (`Editor/Diff.lean`) is a file property: its
texts are files the job loads, so both sources are snapshots the job holds,
and the same three runs reach them (the model, the fake of the file service,
whose model answers a diff, and the library's file and diff services on real
files). A text is written as a string: a file holds its bytes as a save
writes them (`FileModel.encode`), so an escape in a text is the one byte it
stands for in the file, and loads back as the escape.

The exact hunks an engine picks may differ between the model (an LCS) and
the library (imara-diff's histogram), so the properties are relational,
as the Rust contract's are (`crates/editor-diff/src/contract.rs`): what a
script gives, what it must keep, and where its steps may start and stop. -/

/-- Pairs of an old and a new text, among them a character that differs only
in its trailing byte (`é` to `è`, `C3 A9` to `C3 A8`), two CJK characters
that share their first two bytes, and an escape of a byte that is not UTF-8
changed to another. -/
def diffPairs : List (String × String) :=
  [("", ""), ("", "a\n"), ("a\n", ""), ("a\nb\nc\n", "a\nX\nc\n"), ("a\nc\n", "a\nb\nc\n"),
    ("a\nb", "a\nb\n"), ("one\ntwo\nthree\n", "one\ntwo and more\nthree\n"),
    ("x\r\ny\r\n", "x\r\nz\r\n"), ("café\n", "cafè\n"), ("日日\n", "日时\n"),
    (("a".push (Char.ofNat 0x10DC80)).push 'b', ("a".push (Char.ofNat 0x10DC81)).push 'b'),
    ("p\nq\nr\ns\nt\n", "t\ns\nr\nq\np\n")]

/-- Kept-block cases: an old text and a new one, and the bytes of the block
`K` in the old text, as a start and a stop. `K` shares no line with the hunks,
and the hunks share no line across it. -/
def keptCases : List (String × String × Nat × Nat) :=
  [("one\nkeep\nthis\ntwo\n", "uno\nkeep\nthis\ndos\n", 4, 14),
    ("a\nb\nK1\nK2\nc\n", "x\nK1\nK2\ny\nz\n", 4, 10), ("é\nkept\nx\n", "è\nkept\ny\n", 3, 8)]

/-- The files of `pairs`, the old text of the `i`th as `o{i}` and its new one
as `n{i}`, each as a save writes it. -/
def pairFiles (pairs : List (String × String)) : Array (String × ByteArray) :=
  (pairs.zipIdx.map fun ((old, new), index) =>
      #[(s!"o{index}", FileModel.encode old), (s!"n{index}", FileModel.encode new)]).toArray.flatten

/-- The script of the diff of the files `o{index}` and `n{index}` in `root`,
under `limit`; a refusal fails the job, saying which. -/
def diffed (root : System.FilePath) (index : Nat) (limit : Nat := roomy) : JobM Diff.Script := do
  let old ← loaded (root / s!"o{index}")
  let new ← loaded (root / s!"n{index}")
  match ← Diff.lines (.held old.snapshot) (.held new.snapshot) limit with
  | .ok script =>
    return script
  | .error error =>
    throw s!"the diff of pair {index} was refused: {error.describe}"

/-- Whether every step of `script` starts and stops at a character boundary of
both texts. -/
def onBoundaries (old new : String) (script : Diff.Script) : Bool :=
  let (oldBytes, newBytes) := (old.toUTF8, new.toUTF8)
  (script.foldl
        (fun (atOld, atNew, holds) step =>
          let (atOld, atNew) :=
            match step with
            | .retain count => (atOld + count, atNew + count)
            | .delete count => (atOld + count, atNew)
            | .insert _ count => (atOld, atNew + count)
          (atOld, atNew, holds && Diff.boundary oldBytes atOld && Diff.boundary newBytes atNew))
        (0, 0, true)).2.2

/-- Whether every byte of the old text from `start` up to `stop` is under one
of the ranges `script` retains. -/
def covered (script : Diff.Script) (start stop : Nat) : Bool :=
  start == stop || script.retained.any fun (from_, to) => from_ ≤ start && stop ≤ to

/-- The longest common prefix of `old` and `new` that ends on a character
boundary of both, and then the longest common suffix of what it leaves that
does: their lengths in bytes. -/
def affixes (old new : String) : Nat × Nat :=
  Id.run do
    let (a, b) := (old.toUTF8, new.toUTF8)
    let shorter := min a.size b.size
    let mut lead := 0
    while lead < shorter && a.get! lead == b.get! lead do
      lead := lead + 1
    while lead > 0 && !(Diff.boundary a lead && Diff.boundary b lead) do
      lead := lead - 1
    let mut trail := 0
    while trail < shorter - lead && a.get! (a.size - 1 - trail) == b.get! (b.size - 1 - trail) do
      trail := trail + 1
    while trail > 0 && !(Diff.boundary a (a.size - trail) && Diff.boundary b (b.size - trail)) do
      trail := trail - 1
    return (lead, trail)

/-- The diff property that `check` holds of the script of every pair of
`pairs`. -/
def everyPair (name : String) (pairs : List (String × String))
    (check : String → String → Diff.Script → Bool) : FileProperty
    where
  name
  files := pairFiles pairs
  holds root := do
    let mut every := true
    for ((old, new), index) in pairs.zipIdx do
      every := every && check old new (← diffed root index)
    return every
  after := pairFiles pairs

/-- The properties every implementation of the job port's diff request has. -/
def diffProperties : List FileProperty :=
  [everyPair "a diff's script applied to the old text gives the new text" diffPairs
      fun old new script => Diff.Script.run old new script == some new,
    everyPair "a diff of equal texts is one retain of the whole"
      [("", ""), ("a\n", "a\n"), ("a\nb\nc\n", "a\nb\nc\n"), ("é\n日\n", "é\n日\n")]
      fun old _ script => script == #[.retain old.utf8ByteSize],
    everyPair
      "every step of a diff's script starts and stops at a character boundary of both texts: a character that differs only in its trailing byte, and an escape, are replaced whole"
      diffPairs onBoundaries,
    everyPair "a diff retains the longest common prefix and suffix that end on a character boundary"
      diffPairs fun old new script =>
      let (lead, trail) := affixes old new
      covered script 0 lead && covered script (old.utf8ByteSize - trail) old.utf8ByteSize,
    { name :=
        "a block both texts keep, sharing no line with the hunks, is under a retain of the diff's script"
      files := pairFiles (keptCases.map fun (old, new, _) => (old, new))
      holds := fun root => do
        let mut kept := true
        for ((_, _, start, stop), index) in keptCases.zipIdx do
          kept := kept && covered (← diffed root index) start stop
        return kept
      after := pairFiles (keptCases.map fun (old, new, _) => (old, new)) },
    { name := "over the line limit a diff's middle is one hunk, and its script still applies"
      files := pairFiles [("h\na\nk\nb\nt\n", "h\nA\nk\nB\nt\n")]
      holds := fun root => do
        let over ← diffed root 0 2
        let within ← diffed root 0 3
        return Diff.Script.run "h\na\nk\nb\nt\n" "h\nA\nk\nB\nt\n" over == some "h\nA\nk\nB\nt\n" &&
            over.changedRuns == 1 &&
            within.changedRuns == 2
      after := pairFiles [("h\na\nk\nb\nt\n", "h\nA\nk\nB\nt\n")] },
    { name :=
        "a diff whose source names no snapshot, one the store never published or one the job does not hold, is refused with noSuchSnapshot"
      files := pairFiles [("a\n", "b\n")]
      holds := fun root => do
        let old ← loaded (root / "o0")
        let published ← Diff.lines (.snapshot ⟨1000⟩) (.held old.snapshot) roomy
        let notHeld ← Diff.lines (.held old.snapshot) (.held ⟨1000000⟩) roomy
        return noSnapshot published && noSnapshot notHeld
      after := pairFiles [("a\n", "b\n")] }]
where
  /-- Whether `reply` is the refusal `noSuchSnapshot`. -/
  noSnapshot : Except DiffError Diff.Script → Bool
    | .error .noSuchSnapshot => true
    | _ => false

/-! ## The process requests

A property of the process requests (`Editor/Process.lean`) is the files there
are to start with, the scripts of every command it runs, and a job that is
given the directory the files are in and returns whether it held. Whoever
runs the list makes the directory: the model and the fake of the process
service are given a made-up absolute path and the scripts, and the
library's service a temporary directory, where the commands really run.

Every program is `/bin/sh`, `/bin/ls`, `/usr/bin/env` or a bare `sh` on a
`PATH` the property gives, and every command runs in the property's
directory. So `scripts` is a claim about each command, which the model and
the fake take as true and the library's run puts to the test. -/

/-- One property of the job port's process requests. -/
structure ProcessProperty where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- The files there are to start with, each a name in the directory and
  its bytes. -/
  files : Array (String × ByteArray) := #[]
  /-- What each command the property runs in the directory does. -/
  scripts : System.FilePath → Array Process.Script := fun _ => #[]
  /-- What each command the property starts as a streaming child in the
  directory does. -/
  streams : System.FilePath → Array Process.StreamScript := fun _ => #[]
  /-- Observes the property, given the directory, an absolute path; `true`
  when it holds. A job that fails or is cancelled has not held. -/
  holds : System.FilePath → JobM Bool

/-- `/bin/sh -c script` in `directory`, with `environment`. -/
def sh (directory : System.FilePath) (script : String) (environment : Process.Environment := {}) :
    Process.Command :=
  { program := "/bin/sh", arguments := #["-c", script], environment, directory }

/-- A limit no output of a property is over, but the one whose limit is what
it is about. -/
def roomyOutput : Nat :=
  1000000

/-- A run of a command that ends with the status 0 and writes `stdout` and
nothing else. -/
def wrote (stdout : String) : Except ProcessError Process.Ran :=
  .ok { exit := .code 0, stdout := stdout.toUTF8, stderr := .empty }

/-- Runs `command`; a refusal fails the job, saying which. -/
def ranOk (command : Process.Command) (limit : Nat := roomyOutput) : JobM Process.Ran := do
  match ← Process.run command limit with
  | .ok ran =>
    return ran
  | .error error =>
    throw s!"the run of {command.program} was refused: {error.describe}"

/-- What the first property's command writes to its standard error: `err` and the byte
`FF`, which is not UTF-8. -/
def errBytes : ByteArray :=
  "err".toUTF8.push 0xFF

/-- The script that writes `out` and a line feed, `err` and the byte `FF`, and
ends with the status 3. -/
def runScript : String :=
  "printf 'out\\n'; printf 'err\\377' >&2; exit 3"

/-- The environment that sets one variable. -/
def setOne : Process.Environment :=
  { set := #[("EDITOR_PROCESS_SET", "given")] }

/-- The environment that has only one variable. -/
def onlyOne : Process.Environment :=
  { clear := true, set := #[("ONLY", "x")] }

/-- The environment that removes `PATH`. -/
def noPath : Process.Environment :=
  { unset := #["PATH"] }

/-- `/usr/bin/env`, which writes the environment it was given, in
`directory`, with `environment`. -/
def env (directory : System.FilePath) (environment : Process.Environment) : Process.Command :=
  { program := "/usr/bin/env", environment, directory }

/-- A bare `sh` that writes `found`, on the `PATH` `path`. -/
def bareSh (directory : System.FilePath) (path : String) : Process.Command :=
  { program := "sh", arguments := #["-c", "printf found"]
    environment := { set := #[("PATH", path)] }, directory }

/-- A program that is not there. -/
def missingProgram : String :=
  "/nonexistent/editor-process-contract"

/-- Lines framing on both streams, with `bound`, and the input piped if
`input`. -/
def lines (bound : Nat) (input : Bool := false) : Process.Streaming :=
  { input, bound }

/-- Starts `command` as a streaming child; a refusal fails the job, saying
which. -/
def started (command : Process.Command) (streaming : Process.Streaming) : JobM Process.Id := do
  match ← Process.start command streaming with
  | .ok process =>
    return process
  | .error error =>
    throw s!"the start of {command.program} was refused: {error.describe}"

/-- The next delivery of `process`; a refusal fails the job. -/
def delivered (process : Process.Id) : JobM Process.Delivery := do
  match ← Process.read process with
  | .ok delivery =>
    return delivery
  | .error error =>
    throw s!"a read was refused: {error.describe}"

/-- Every delivery of `process` to its last; a refusal fails the job, and
so does a child that has not ended in `reads` reads. -/
def toTheEnd (process : Process.Id) (reads : Nat := 1000000) : JobM (Array Process.Delivery) := do
  let mut all := #[]
  for _ in [0:reads] do
    let delivery ← delivered process
    all := all.push delivery
    if delivery.ended.isSome then
      return all
  throw s!"the child did not end within {reads} reads"

/-- The frames of `stream` in `delivery`. -/
def framesOf (delivery : Process.Delivery) : Process.Stream → Process.Frames
  | .out => delivery.stdout
  | .err => delivery.stderr

/-- Every line of `stream` in `deliveries`, in order. -/
def linesOf (deliveries : Array Process.Delivery) (stream : Process.Stream) : Array ByteArray :=
  deliveries.foldl (init := #[]) fun all delivery =>
    match framesOf delivery stream with
    | .lines lines => all ++ lines
    | .bytes _ => all

/-- How many bytes `frames` stand for, a line feed counted for each line. -/
def frameBytes : Process.Frames → Nat
  | .lines lines => lines.foldl (fun total line => total + line.size + 1) 0
  | .bytes bytes => bytes.size

/-- The bytes of `stream` in `deliveries`, end to end, a line feed after each
line. -/
def bytesOf (deliveries : Array Process.Delivery) (stream : Process.Stream) : ByteArray :=
  deliveries.foldl (init := .empty) fun all delivery =>
    match framesOf delivery stream with
    | .bytes bytes => all ++ bytes
    | .lines lines => lines.foldl (fun all line => (all ++ line).push 10) all

/-- `text` as lines, for comparing with what a delivery holds. -/
def linesFrom (text : List String) : Array ByteArray :=
  text.toArray.map String.toUTF8

/-- How the last of `deliveries` says the child ended. -/
def endOf (deliveries : Array Process.Delivery) : Option Process.End :=
  deliveries.back?.bind (·.ended)

/-- The script that writes the numbers from 0 below `count`, a line each. -/
def countingScript (count : Nat) : String :=
  s!"i=0; while [ $i -lt {count} ]; do echo $i; i=$((i+1)); done"

/-- What `countingScript count` writes. -/
def counted (count : Nat) : ByteArray :=
  (List.range count).foldl (fun all n => all ++ s!"{n}\n".toUTF8) .empty

/-- The script of the streaming child whose lines arrive as it writes them:
`one`, then the line it reads echoed, then `err` on its standard error, then
it waits for its input to end and exits with the status 4. -/
def linesScript : String :=
  "echo one; read x; echo \"$x\"; echo err >&2; read y; exit 4"

/-- What `linesScript` does, as the model's script. -/
def linesStream (root : System.FilePath) : Process.StreamScript :=
  { command := sh root linesScript
    steps := #[.write .out "one\n".toUTF8, .echoLine .out, .write .err "err\n".toUTF8, .awaitClosed]
    exit := .code 4 }

/-- What a script that writes `bytes` and exits does, as the model's script. -/
def writes (command : Process.Command) (bytes : ByteArray) : Process.StreamScript :=
  { command, steps := #[.write .out bytes] }

/-- The line `printf '%5000s' x` writes: 4999 spaces and `x`, with no line
feed. -/
def longLine : ByteArray :=
  (String.ofList (List.replicate 4999 ' ')).toUTF8 ++ "x".toUTF8

/-- The properties every implementation of the job port's streaming process
requests has. -/
def streamProperties : List ProcessProperty :=
  [{  name := "a job that asked for lines receives each line as the child writes it"
      streams := fun root => #[linesStream root]
      holds := fun root => do
        let child ← started (sh root linesScript) (lines roomyOutput true)
        -- The child waits for its input here: `one` reaches the job first.
        let first ← delivered child
        return first.stdout == .lines (linesFrom ["one"]) && first.stderr == .lines #[] &&
            first.ended.isNone },
    { name :=
        "a line a job writes reaches the child's standard input, a close ends its input, and a write after the close is refused as input closed"
      streams := fun root => #[linesStream root]
      holds := fun root => do
        let child ← started (sh root linesScript) (lines roomyOutput true)
        let first ← delivered child
        let .ok () ← Process.writeLine child "two" | return false
        let mut echoed := #[]
        for _ in [0:10] do
          echoed := echoed.push (← delivered child)
          if
              linesOf echoed .out == linesFrom ["two"] &&
                linesOf echoed .err == linesFrom ["err"] then
            break
        let .ok () ← Process.closeInput child | return false
        let late ← Process.write child "late".toUTF8
        let rest ← toTheEnd child
        return first.stdout == .lines (linesFrom ["one"]) &&
            linesOf echoed .out == linesFrom ["two"] &&
            linesOf echoed .err == linesFrom ["err"] &&
            (match late with
            | .error (.inputClosed _) => true
            | _ => false) &&
            endOf rest == some (.exited (.code 4)) },
    { name :=
        "output from a child faster than the job drains it arrives complete and in order, no delivery over the bound"
      streams := fun root => #[writes (sh root (countingScript 5000)) (counted 5000)]
      holds := fun root => do
        let child ← started (sh root (countingScript 5000)) (lines 64)
        let all ← toTheEnd child
        return bytesOf all .out == counted 5000 && all.all (frameBytes ·.stdout ≤ 64) &&
            endOf all == some (.exited (.code 0)) },
    { name := "a child at the bound is held and continues, with nothing of its output lost"
      streams := fun root => #[writes (sh root (countingScript 20000)) (counted 20000)]
      holds := fun root => do
        let child ← started (sh root (countingScript 20000)) (lines 128)
        let all ← toTheEnd child
        return bytesOf all .out == counted 20000 && endOf all == some (.exited (.code 0)) },
    { name := "bytes are delivered byte for byte, a byte that is not UTF-8 among them"
      streams := fun root =>
        #[writes (sh root "printf 'a\\377b'") ("a".toUTF8.push 0xFF |>.push 98)]
      holds := fun root => do
        let child ←
          started (sh root "printf 'a\\377b'") { stdout := .bytes, stderr := .bytes, bound := 64 }
        let all ← toTheEnd child
        return bytesOf all .out == ("a".toUTF8.push 0xFF |>.push 98) &&
            endOf all == some (.exited (.code 0)) },
    { name := "a line longer than the bound ends the child as lineTooLong"
      streams := fun root => #[writes (sh root "printf '%5000s' x") longLine]
      holds := fun root => do
        let child ← started (sh root "printf '%5000s' x") (lines 1024)
        return endOf (← toTheEnd child) == some (.lineTooLong .out 1024) },
    -- Seen to bite once by hand, on 2026-11-15: over the model as it was,
    -- changed to write a line feed past the bound and to judge a line not
    -- too long when only its line feed is left to write, the case of the
    -- line and its line feed fails on the model and on the fake.
    { name :=
        "a last line exactly the bound long, with no line feed, is delivered whole, and one a byte longer ends the child as lineTooLong, as does one the bound long and its line feed, which counts against the bound"
      streams := fun root =>
        #[writes (sh root "printf abcd") "abcd".toUTF8,
          writes (sh root "printf abcde") "abcde".toUTF8,
          writes (sh root "printf 'abcd\\n'") "abcd\n".toUTF8]
      holds := fun root => do
        let atBound ← toTheEnd (← started (sh root "printf abcd") (lines 4))
        let over ← toTheEnd (← started (sh root "printf abcde") (lines 4))
        let terminated ← toTheEnd (← started (sh root "printf 'abcd\\n'") (lines 4))
        return linesOf atBound .out == linesFrom ["abcd"] &&
            endOf atBound == some (.exited (.code 0)) &&
            linesOf over .out == #[] &&
            endOf over == some (.lineTooLong .out 4) &&
            linesOf terminated .out == #[] &&
            endOf terminated == some (.lineTooLong .out 4) },
    { name := "a process the job does not hold is noSuchProcess, answered without a request"
      holds := fun _ => do
        match ← Process.read ⟨999999⟩ with
        | .error .noSuchProcess =>
          return true
        | _ =>
          return false },
    { name := "a job that ends with its child running leaves no child"
      streams := fun root => #[{ command := sh root "/bin/sleep 600", steps := #[.awaitClosed] }]
      holds := fun root => do
        discard <| started (sh root "/bin/sleep 600") (lines 64 true)
        return true }]

/-- The properties every implementation of the job port's process requests
has. -/
def processProperties : List ProcessProperty :=
  [{    name :=
          "a run to its end replies with its exit status 3 and both streams byte for byte, a byte that is not UTF-8 among them"
        scripts := fun root =>
          #[{ command := sh root runScript
              reply := .ok { exit := .code 3, stdout := "out\n".toUTF8, stderr := errBytes } }]
        holds := fun root => do
          let ran ← ranOk (sh root runScript)
          return ran.exit == .code 3 && ran.stdout == "out\n".toUTF8 && ran.stderr == errBytes },
      { name := "a child ended by a signal replies with the signal"
        scripts := fun root =>
          #[{ command := sh root "kill -9 $$"
              reply := .ok { exit := .signal 9, stdout := .empty, stderr := .empty } }]
        holds := fun root => do
          return (← ranOk (sh root "kill -9 $$")).exit == .signal 9 },
      { name := "the child runs in the command's directory: `ls` there lists the property's file"
        files := #[("listed", .empty)]
        scripts := fun root =>
          #[{ command := { program := "/bin/ls", directory := root }, reply := wrote "listed\n" }]
        holds := fun root => do
          return (← ranOk { program := "/bin/ls", directory := root }).stdout ==
              "listed\n".toUTF8 },
      { name :=
          "the environment is the editor's with a variable set, emptied and then set, or with a variable unset"
        scripts := fun root =>
          #[{ command := sh root "printf %s \"$EDITOR_PROCESS_SET\"" setOne,
              reply := wrote "given" },
            { command := env root onlyOne, reply := wrote "ONLY=x\n" },
            { command := env root noPath, reply := wrote "" }]
        holds := fun root => do
          let set ← ranOk (sh root "printf %s \"$EDITOR_PROCESS_SET\"" setOne)
          let only ← ranOk (env root onlyOne)
          let unset ← ranOk (env root noPath)
          let lines := (String.fromUTF8? unset.stdout).getD "PATH=" |>.splitOn "\n"
          return set.stdout == "given".toUTF8 && only.stdout == "ONLY=x\n".toUTF8 &&
              !lines.any (·.startsWith "PATH=") },
      { name := "a bare program name is found on the PATH the child is given"
        scripts := fun root => #[{ command := bareSh root "/bin:/usr/bin", reply := wrote "found" }]
        holds := fun root => do
          return (← ranOk (bareSh root "/bin:/usr/bin")).stdout == "found".toUTF8 },
      { name :=
          "a program that is not there is refused as not found, as a value, and the job goes on to a run that ends"
        scripts := fun root =>
          #[{ command := sh root "exit 0"
              reply := .ok { exit := .code 0, stdout := .empty, stderr := .empty } }]
        holds := fun root => do
          let .error (.notFound _) ←
            Process.run { program := missingProgram, directory := root } roomyOutput | return false
          return (← ranOk (sh root "exit 0")).exit == .code 0 },
      { name :=
          "a directory that is not absolute and a program that names a directory without being absolute are refused before anything is started, and the job goes on"
        scripts := fun root =>
          #[{ command := sh "relative" "exit 0"
              reply := .ok { exit := .code 0, stdout := .empty, stderr := .empty } },
            { command := { program := "bin/sh", directory := root }
              reply := .ok { exit := .code 0, stdout := .empty, stderr := .empty } },
            { command := sh root "exit 0"
              reply := .ok { exit := .code 0, stdout := .empty, stderr := .empty } }]
        holds := fun root => do
          let directory ← Process.run (sh "relative" "exit 0") roomyOutput
          let program ← Process.run { program := "bin/sh", directory := root } roomyOutput
          let after ← ranOk (sh root "exit 0")
          return (match directory with
              | .error .relativeDirectory => true
              | _ => false) &&
              (match program with
              | .error .relativeProgram => true
              | _ => false) &&
              after.exit == .code 0 },
      { name :=
          "a run that outlives its time limit is refused as timedOut, and a run within its limit answers as a run does"
        scripts := fun root =>
          #[{ command := sh root "/bin/sleep 600"
              reply := .ok { exit := .code 0, stdout := .empty, stderr := .empty }
              takes := 600000 },
            { command := sh root "exit 0"
              reply := .ok { exit := .code 0, stdout := .empty, stderr := .empty } }]
        holds := fun root => do
          let late ← Process.runWithin (sh root "/bin/sleep 600") roomyOutput 50
          let within ← Process.runWithin (sh root "exit 0") roomyOutput 10000
          return (match late with
              | .error (.timedOut 50) => true
              | _ => false) &&
              match within with
              | .ok ran => ran.exit == .code 0
              | .error _ => false },
      { name := "output past the limit is refused as too large, with the stream and the limit"
        scripts := fun root =>
          #[{ command := sh root "printf 0123456789"
              reply := wrote "0123456789" }]
        holds := fun root => do
          match ← Process.run (sh root "printf 0123456789") 4 with
          | .error (.outputTooLarge .out 4) =>
            return true
          | _ =>
            return false }] ++
    streamProperties

/-- Runs each of `properties` with `run`, which makes the property's files in a
directory of its own and runs its job there, and returns the names of those
that did not hold, each with how its job ended if it did not finish. -/
def processFailures (run : ProcessProperty → IO (Job.Outcome Bool))
    (properties : List ProcessProperty) : IO (List String) :=
  properties.filterMapM fun property => do
    match ← run property with
    | .finished true =>
      return none
    | .finished false =>
      return some property.name
    | .failed message =>
      return some s!"{property.name} (the job failed with `{message}`)"
    | .cancelled =>
      return some s!"{property.name} (the job was cancelled)"

/-! ## The watch requests

A property of the watch requests (`Editor/FileWatch.lean`) is the
directories and the files there are to start with, the `sh` scripts it runs
in its directory to change them, with what each changes for the model, and a
job that is given the directory and returns whether it held. Whoever runs
the list makes the directory: the model and the fake are given a made-up
absolute path, its directories and what each script touches, and the
library's service a temporary directory, where the scripts really run and
the platform really reports what they did.

On the library a property checks that a kind is *present* in a change, and
reads until the change it looks for arrives, at most `watchReads`
deliveries for each change it looks for: a platform can carry an earlier
change's kind, and can split what one script did across deliveries. On the
model the first delivery is the one, and a second read finds nothing to
answer it and fails the job. The coalescing property is the one exception
to "read until": the five writes must be in the first delivery, and in no
delivery twice; that they all arrive in that one delivery on a real
platform is the library's contract's (`editor_watch::contract::COALESCED`),
which runs on the real adapter in Rust, and the exact window is the
model's (`ModelTest.fileWatchModelChecks`). -/

/-- A script a watch property runs in its directory, and what it changes
there, for the model: each name, relative to the directory, and the kind of
its change, in order. -/
structure FileWatchScript where
  /-- The script, run by `/bin/sh -c` in the directory. -/
  script : String
  /-- What it changes, for the model and the fake. -/
  touches : Array (String × FileWatch.Kind) := #[]

/-- One property of the job port's watch requests. -/
structure FileWatchProperty where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- The subdirectories there are to start with, each a name relative to the
  directory, parents first. -/
  directories : Array String := #[]
  /-- The files there are to start with, each a name in the directory and its
  bytes. -/
  files : Array (String × ByteArray) := #[]
  /-- The scripts it runs. -/
  scripts : Array FileWatchScript := #[]
  /-- Observes the property, given the directory, an absolute path; `true`
  when it holds. A job that fails or is cancelled has not held. -/
  holds : System.FilePath → JobM Bool

/-- How many deliveries a watch property reads for each change it looks for,
at most. -/
def watchReads : Nat :=
  4

/-- The coalescing of every watch property but the coalescing one: a short
window, and room for every path a property changes. -/
def watchCoalescing : FileWatch.Coalescing :=
  { window := 50, bound := 64 }

/-- Runs `script` in `root`; a refusal or a status other than 0 fails the
job, saying which. -/
def changes (root : System.FilePath) (script : String) : JobM Unit := do
  let ran ← ranOk (sh root script)
  unless ran.exit == .code 0 do
    throw s!"`{script}` ended with {repr ran.exit}"

/-- Starts a watch on `target`; a refusal fails the job, saying which. -/
def watching (target : FileWatch.Target) (coalescing : FileWatch.Coalescing := watchCoalescing) :
    JobM FileWatch.Id := do
  match ← FileWatch.start target coalescing with
  | .ok watch =>
    return watch
  | .error error =>
    throw s!"the watch of {target.path} was refused: {error.describe}"

/-- Whether `delivery` has a change of `path` with `kind` among its kinds. -/
def told (delivery : Array FileWatch.Change) (path : System.FilePath) (kind : FileWatch.Kind) :
    Bool :=
  delivery.any fun change => change.path == path && change.kinds.has kind

/-- How many changes of `path` `delivery` holds. -/
def timesIn (delivery : Array FileWatch.Change) (path : System.FilePath) : Nat :=
  (delivery.filter (·.path == path)).size

/-- Reads deliveries of `watch`, up to `watchReads` for each of `wanted`
changes, until `done` holds of every delivery so far: those deliveries, or
`none` if it never did. A refusal fails the job. -/
def readAll (watch : FileWatch.Id) (done : Array (Array FileWatch.Change) → Bool)
    (wanted : Nat := 1) : JobM (Option (Array (Array FileWatch.Change))) := do
  let mut deliveries := #[]
  for _ in [0:watchReads * wanted] do
    match ← FileWatch.next watch with
    | .ok delivery =>
      deliveries := deliveries.push delivery
      if done deliveries then
        return some deliveries
    | .error error =>
      throw s!"a read of the watch was refused: {error.describe}"
  return none

/-- Whether reading `watch` as `readAll` does comes to deliveries of which
`done` holds. -/
def readUntil (watch : FileWatch.Id) (done : Array (Array FileWatch.Change) → Bool)
    (wanted : Nat := 1) : JobM Bool :=
  return (← readAll watch done wanted).isSome

/-- Whether some delivery of `deliveries` has a change of `path` with
`kind`. -/
def toldIn (deliveries : Array (Array FileWatch.Change)) (path : System.FilePath)
    (kind : FileWatch.Kind) : Bool :=
  deliveries.any (told · path kind)

/-- The properties every implementation of the job port's watch requests
has. -/
def fileWatchProperties : List FileWatchProperty :=
  [{  name := "a job watching a file is told when the file is written"
      files := #[("f", "a".toUTF8)]
      scripts := #[{ script := "printf x >> f", touches := #[("f", .written)] }]
      holds := fun root => do
        let watch ← watching (.file (root / "f"))
        changes root "printf x >> f"
        readUntil watch (toldIn · (root / "f") .written) },
    { name := "a job watching a file is told when another file is renamed over it"
      files := #[("f", "a".toUTF8)]
      scripts :=
        #[{ script := "printf y > g && mv g f"
            touches := #[("g", .created), ("g", .written), ("g", .renamed), ("f", .renamed)] }]
      holds := fun root => do
        let watch ← watching (.file (root / "f"))
        changes root "printf y > g && mv g f"
        readUntil watch (toldIn · (root / "f") .renamed) },
    { name := "a job watching a file is told when the file is removed"
      files := #[("f", "a".toUTF8)]
      scripts := #[{ script := "rm f", touches := #[("f", .removed)] }]
      holds := fun root => do
        let watch ← watching (.file (root / "f"))
        changes root "rm f"
        readUntil watch (toldIn · (root / "f") .removed) },
    { name :=
        "a job watching a directory is told the path of each entry created, written, renamed and removed directly inside it"
      files := #[("w", "w".toUTF8), ("a", "a".toUTF8), ("r", "r".toUTF8)]
      scripts :=
        #[{ script := "printf n > n && printf x >> w && mv a b && rm r"
            touches :=
              #[("n", .created), ("n", .written), ("w", .written), ("a", .renamed), ("b", .renamed),
                ("r", .removed)] }]
      holds := fun root => do
        let watch ← watching (.directory root false)
        changes root "printf n > n && printf x >> w && mv a b && rm r"
        let wanted :=
          #[(root / "n", FileWatch.Kind.created), (root / "w", .written), (root / "a", .renamed),
            (root / "b", .renamed), (root / "r", .removed)]
        readUntil (wanted := wanted.size) watch fun deliveries =>
            wanted.all fun (path, kind) => toldIn deliveries path kind },
    { name :=
        "a job with a recursive directory watch is told the path of an entry changed two levels down"
      directories := #["x", "x/y"]
      files := #[("x/y/f", "a".toUTF8)]
      scripts := #[{ script := "printf x >> x/y/f", touches := #[("x/y/f", .written)] }]
      holds := fun root => do
        let watch ← watching (.directory root true)
        changes root "printf x >> x/y/f"
        readUntil watch (toldIn · (root / "x" / "y" / "f") .written) },
    { name :=
        "five writes to one path within the window are in the first delivery, once, and in no delivery twice, and a later write is told"
      files := #[("f", "a".toUTF8)]
      scripts :=
        #[{ script := "for i in 1 2 3 4 5; do printf x >> f; done"
            touches :=
              #[("f", .written), ("f", .written), ("f", .written), ("f", .written),
                ("f", .written)] },
          { script := "printf x > g", touches := #[("g", .created), ("g", .written)] }]
      holds := fun root => do
        let watch ← watching (.directory root false) { window := 300, bound := 64 }
        changes root "for i in 1 2 3 4 5; do printf x >> f; done"
        let .ok first ← FileWatch.next watch | return false
        changes root "printf x > g"
        let some later ← readAll watch (toldIn · (root / "g") .written) | return false
        return timesIn first (root / "f") == 1 && told first (root / "f") .written &&
            later.all (timesIn · (root / "f") ≤ 1) },
    { name :=
        "a job watching a file that is not there yet is told of its creation, and of a write after a rename over it"
      scripts :=
        #[{ script := "printf x > f", touches := #[("f", .created), ("f", .written)] },
          { script := "printf y > g && mv g f"
            touches := #[("g", .created), ("g", .written), ("g", .renamed), ("f", .renamed)] },
          { script := "printf z >> f", touches := #[("f", .written)] }]
      holds := fun root => do
        let watch ← watching (.file (root / "f"))
        changes root "printf x > f"
        let made ← readUntil watch (toldIn · (root / "f") .created)
        changes root "printf y > g && mv g f"
        let saved ← readUntil watch (toldIn · (root / "f") .renamed)
        changes root "printf z >> f"
        let written ← readUntil watch (toldIn · (root / "f") .written)
        return made && saved && written },
    { name :=
        "a watch of a directory that is not there is refused as not found, a relative path as not absolute, and the job goes on"
      holds := fun root => do
        let missing ← FileWatch.start (.directory (root / "missing") false) watchCoalescing
        let relative ← FileWatch.start (.file "relative/f") watchCoalescing
        let after ← FileWatch.start (.file (root / "f")) watchCoalescing
        return (match missing with
            | .error (.notFound _) => true
            | _ => false) &&
            (match relative with
            | .error (.notAbsolute _) => true
            | _ => false) &&
            (match after with
            | .ok _ => true
            | .error _ => false) }]

/-- Runs each of `properties` with `run`, which makes the property's
directories and files in a directory of its own and runs its job there, and
returns the names of those that did not hold, each with how its job ended if
it did not finish. -/
def fileWatchFailures (run : FileWatchProperty → IO (Job.Outcome Bool))
    (properties : List FileWatchProperty) : IO (List String) :=
  properties.filterMapM fun property => do
    match ← run property with
    | .finished true =>
      return none
    | .finished false =>
      return some property.name
    | .failed message =>
      return some s!"{property.name} (the job failed with `{message}`)"
    | .cancelled =>
      return some s!"{property.name} (the job was cancelled)"

end Editor.JobContract
