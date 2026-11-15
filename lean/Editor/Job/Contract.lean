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
which is what shows those scripts true.

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
  [roundTrip "LF line endings" lfFile, roundTrip "CRLF line endings" crlfFile,
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
  scripts : System.FilePath → Array Process.Script
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

/-- The properties every implementation of the job port's process requests
has. -/
def processProperties : List ProcessProperty :=
  [{ name :=
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
      scripts := fun root => #[{ command := { program := "/bin/ls", directory := root }, reply := wrote "listed\n" }]
      holds := fun root => do
        return (← ranOk { program := "/bin/ls", directory := root }).stdout == "listed\n".toUTF8 },
    { name :=
        "the environment is the editor's with a variable set, emptied and then set, or with a variable unset"
      scripts := fun root =>
        #[{ command := sh root "printf %s \"$EDITOR_PROCESS_SET\"" setOne, reply := wrote "given" },
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
        let .error (.notFound _) ← Process.run { program := missingProgram, directory := root } roomyOutput
          | return false
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
        return (match directory with | .error .relativeDirectory => true | _ => false) &&
            (match program with | .error .relativeProgram => true | _ => false) &&
            after.exit == .code 0 },
    { name := "output past the limit is refused as too large, with the stream and the limit"
      scripts := fun root =>
        #[{ command := sh root "printf 0123456789"
            reply := wrote "0123456789" }]
      holds := fun root => do
        match ← Process.run (sh root "printf 0123456789") 4 with
        | .error (.outputTooLarge .out 4) =>
          return true
        | _ =>
          return false }]

/-- Runs each of `properties` with `run`, which makes the property's files in a
directory of its own and runs its job there, and returns the names of those
that did not hold, each with how its job ended if it did not finish. -/
def processFailures (run : ProcessProperty → IO (Job.Outcome Bool)) (properties : List ProcessProperty) :
    IO (List String) :=
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
