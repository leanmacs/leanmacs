import Editor.Command.Real
import Editor.Display.Real
import Editor.Event.Queue
import Editor.Ffi
import Editor.InputScheme.Test
import Editor.InputScheme.Vim
import Editor.Themes.Compiled
import Editor.Themes.FairyFloss
import Editor.Themes.Solarized
import Editor.Window.Real
import Editor.WindowCheck.Real
import Lean.Environment
import Lean.Util.Path

/-!
# Checks of the boundary with the Rust library

The `ffi-test` executable is linked exactly like `editor`: the same glue
object, Rust archive and entry point. With no arguments it runs every check in
`checks`, names the ones that failed, and exits non-zero if any did.

Some behaviour needs a process of its own, so it is a scenario chosen by an
argument (see `main`): `exit <code>` for the exit status, `shutdown` and
`exit-while-blocked` because quitting the queues is for good, and `overflow`
because it ends in an abort. `theme-pictures <dir> <font>` compares the
shipped themes' pictures of a fixture file with their reference
images (`themePicturesScenario`), and with `--write` makes them again. `mise run ffi-test` runs the checks and every
scenario but `overflow`, under a time limit, and is part of the gate.
`mise run ffi-overflow` runs `overflow`, on demand only: on macOS every abort
leaves a crash report on the machine.

Each check pins what the C glue and the entry point do, as Lean sees it. What
the Rust functions themselves compute is pinned by `editor-ffi`'s own tests.

A check never waits without a bound: a pull runs on a dedicated task that the
check polls (`pull`, `eventually`), so broken code fails a check within
seconds instead of hanging the executable.
-/

namespace FfiTest

/-- One behaviour of the boundary, and how to observe it. -/
structure Check where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the behaviour; `true` when it holds. -/
  run : IO Bool

/-- The least stack, in bytes, the thread that runs Lean's generated `main`
must have: 64 MiB, the size the entry point asks for. Module initialisers run
on it, and a thread's default stack is 512 KiB. -/
def entryStackSize : USize :=
  64 * 1024 * 1024

/-- Whether `size`, in bytes, is the stack the entry point gives every thread
Lean creates: 64 MiB, to which Lean adds 128 KiB. Lean's own default is a
gigabyte, and a thread's default is 512 KiB. -/
def isEditorStack (size : USize) : Bool :=
  size >= 64 * 1024 * 1024 && size < 65 * 1024 * 1024

/-- The checks of the entry point and of a plain call.

This and the lists after it are functions, not constants, because Lean
evaluates a module's constants in its initialiser, and an initialiser must not
call the Rust library (`docs/design/lean-runtime.md`). -/
def entryChecks (_ : Unit) : List Check :=
  [{ name := "a Rust function's result crosses into Lean", run := pure (Editor.Ffi.add 2 3 == 5) },
    { name := "Lean code does not run on the process's main thread",
      run := return !(← Editor.Ffi.isMainThread) },
    { name := "work handed to the main-thread service runs on the process's main thread",
      run := Editor.Ffi.mainThreadProbe },
    { name := "Lean's generated main runs on a thread with a large stack",
      run := return (← Editor.Ffi.entryStackSize) >= entryStackSize },
    { name :=
        "every thread Lean creates has the editor's stack: Lean's main thread, a dedicated task and a pool task"
      run := do
        let onMain ← Editor.Ffi.threadStackSize
        let dedicated ← IO.asTask (prio := .dedicated) Editor.Ffi.threadStackSize
        let pool ← IO.asTask Editor.Ffi.threadStackSize
        let onDedicated ← IO.ofExcept (← IO.wait dedicated)
        let onPool ← IO.ofExcept (← IO.wait pool)
        return isEditorStack onMain && isEditorStack onDedicated && isEditorStack onPool }]

/-- Makes a counter starting at `start`, increments it twice and drops it. Only
plain data leaves: the second count. -/
def useCounter (start : UInt64) : IO UInt64 := do
  let counter ← Editor.Ffi.Counter.new start
  discard counter.increment
  counter.increment

/-- The checks of a handle: a Rust object held by Lean as an external object
(`Editor.Ffi.Counter`). -/
def handleChecks (_ : Unit) : List Check :=
  [{ name := "a counter keeps its count in Rust", run := return (← useCounter 40) == 42 },
    { name := "a counter is freed when Lean drops the last reference"
      run := do
        let before ← Editor.Ffi.Counter.live
        discard <| useCounter 0
        return (← Editor.Ffi.Counter.live) == before },
    { name := "a counter stays alive while any reference is held, on any thread"
      run := do
        let before ← Editor.Ffi.Counter.live
        let counter ← Editor.Ffi.Counter.new 0
        let task ← IO.asTask (prio := .dedicated) counter.increment
        let fromTask ← IO.ofExcept (← IO.wait task)
        let live ← Editor.Ffi.Counter.live
        let fromMain ← counter.increment
        return fromTask == 1 && live == before + 1 && fromMain == 2 },
    { name := "a counter whose last reference is dropped on another thread is freed"
      run := do
        let before ← Editor.Ffi.Counter.live
        let counter ← Editor.Ffi.Counter.new 5
        -- The task's closure is the only holder from here on.
        let task ← IO.asTask (prio := .dedicated) counter.increment
        let fromTask ← IO.ofExcept (← IO.wait task)
        return fromTask == 6 && (← Editor.Ffi.Counter.live) == before }]

/-- Text whose byte offsets and character counts differ: "é" and "ö" are two
bytes each. -/
def haystack : String :=
  "héllo wörld, hello"

/-- How many times a check polls, a millisecond apart, for something that
should happen at once: about five seconds. Only broken code takes this long,
and the check then fails instead of hanging. -/
def patience : Nat :=
  5000

/-- Polls `condition` until it holds; `false` if it still does not after
`patience` polls. -/
def eventually (condition : IO Bool) : IO Bool := do
  for _ in [0:patience] do
    if ← condition then
      return true
    IO.sleep 1
  return false

/-- One event pulled from `queue`, or `none` if the pull does not return in
time. The pull runs on a dedicated task, so one that never returns fails its
check instead of hanging the executable. -/
def pull (queue : Editor.Ffi.Queue) : IO (Option Editor.Ffi.Event) := do
  let task ← IO.asTask (prio := .dedicated) (Editor.Ffi.nextEvent queue)
  unless ← eventually (IO.hasFinished task) do
    return none
  return some (← IO.ofExcept task.get)

/-- The message `postEvent` queues for the Lean source `sourceId`. It has no
stamp: only a window says when its events happened. -/
def message (sourceId code : UInt64) (text : String) : Editor.Ffi.Event :=
  { source := { kind := .lean, id := sourceId }, kind := .message, code, text, stamp := 0 }

/-- Posts a message to the editor queue and pulls it back; `true` when what
comes back is that message, from the Lean source `sourceId`. -/
def roundTrips (sourceId code : UInt64) (text : String) : IO Bool := do
  unless ← Editor.Ffi.postEvent .editor sourceId code text do
    return false
  return (← pull .editor) == some (message sourceId code text)

/-- The checks of plain data: an option and a byte range (`Editor.Ffi.find`),
and a string, enums and a small structure (an event), in both directions. -/
def dataChecks (_ : Unit) : List Check :=
  [{ name := "find returns the byte range of the first match",
     run := pure (Editor.Ffi.find haystack "llo" == some { start := 3, stop := 6 }) },
    { name := "find starts looking at the start offset it is given"
      run := pure (Editor.Ffi.find haystack "llo" (some 4) == some { start := 17, stop := 20 }) },
    { name := "find returns none when there is no match from a usable start"
      run :=
        pure
          (Editor.Ffi.find haystack "zzz" == none &&
            Editor.Ffi.find haystack "llo" (some 2) == none &&
            Editor.Ffi.find haystack "llo" (some 21) == none) },
    { name := "an event posted to a queue is pulled back whole"
      run := roundTrips 7 42 "héllo wörld" },
    { name := "an event's text keeps an embedded NUL byte"
      run := roundTrips 8 43 "before\x00after" },
    { name := "an event with empty text and the largest code crosses"
      run := roundTrips 9 0xFFFFFFFFFFFFFFFF "" },
    { name := "a message posted from Lean has no stamp"
      run := do
        unless ← Editor.Ffi.postEvent .editor 10 1 "" do
          return false
        return ((← pull .editor).map (·.stamp)) == some 0 },
    { name := "the tag of a completion is known"
      run := pure (Editor.Ffi.EventKind.ofTag? 2 == some .completion) },
    { name := "the tags of a window's events and of the window source are known"
      run :=
        pure
          ((([3, 4, 5, 6, 7, 8, 9, 10] : List UInt64).map Editor.Ffi.EventKind.ofTag?) ==
              [some .windowOpened, some .windowFocus, some .key, some .composition, some .pointer,
                some .closeRequested, some .resize, some .openFiles] &&
            Editor.Ffi.SourceKind.ofTag? 3 == some .window) },
    { name := "a tag the bindings do not know is refused"
      run :=
        pure ((Editor.Ffi.EventKind.ofTag? 11).isNone && (Editor.Ffi.SourceKind.ofTag? 4).isNone) }]

/-- An hour, in milliseconds: a deadline no check reaches. -/
def hour : UInt64 :=
  3600000

/-- The checks of the timer service's bindings: a request with an id goes
in, and its completion comes back as an event on the completion queue. -/
def timerChecks (_ : Unit) : List Check :=
  [{
      name :=
        "a timer request that is due comes back as a completion on the completion queue, from the library, with the request's id as its code",
      run := do
        let accepted ← Editor.Ffi.timersStart 7 (← Editor.Ffi.timersNow)
        let some event ← pull .completion | return false
        return accepted && event.source.kind == .library && event.kind == .completion &&
            event.code == 7 &&
            event.text == "" },
    { name :=
        "a timer request an hour away waits until it is cancelled: an id that is waiting is refused, and a cancel says whether the request was waiting"
      run := do
        let before ← Editor.Ffi.timersPending
        let accepted ← Editor.Ffi.timersStart 8 ((← Editor.Ffi.timersNow) + hour)
        let again ← Editor.Ffi.timersStart 8 0
        let waiting ← Editor.Ffi.timersPending
        let cancelled ← Editor.Ffi.timersCancel 8
        let twice ← Editor.Ffi.timersCancel 8
        let never ← Editor.Ffi.timersCancel 99
        return accepted && !again && waiting == before + 1 && cancelled && !twice && !never &&
            (← Editor.Ffi.timersPending) == before },
    { name := "the timer clock does not go back"
      run := do
        let first ← Editor.Ffi.timersNow
        return first <= (← Editor.Ffi.timersNow) }]

/-- The id of the library's file service as an event's source (`SERVICE` in
`crates/editor-ffi/src/files.rs`). -/
def fileService : UInt64 :=
  2

/-- Runs `body` on a new, empty directory this check owns, and removes the
directory afterwards, whatever `body` did. Every file a check touches is in
such a directory, and every path is passed explicitly. -/
def inOwnDirectory (body : System.FilePath → IO Bool) : IO Bool := do
  let directory ← IO.FS.createTempDir
  try
    body directory
  finally
    IO.FS.removeDirAll directory

/-- A file's bytes: a carriage return and a line feed, a four-byte character,
two bytes that are not UTF-8 (`E9` starts a character it does not finish, and
`FF` is never valid) and a line feed alone. Ten bytes. -/
def mixedBytes : ByteArray :=
  "h\r\n😀".toUTF8 ++ ⟨#[0xE9, 0xFF, 0x0A]⟩

/-- The text `mixedBytes` loads as, written out by hand: each invalid byte is
its escape, the character `U+10DC00` plus the byte, which is four bytes of
text. Sixteen bytes, in three rows. -/
def mixedText : String :=
  "h\r\n😀" ++ String.singleton (Char.ofNat (0x10DC00 + 0xE9)) ++
    String.singleton (Char.ofNat (0x10DC00 + 0xFF)) ++
    "\n"

/-- Pulls one event from the completion queue; `true` when it is the
completion of the file request `id`, from the library's file service. -/
def fileCompleted (id : UInt64) : IO Bool := do
  let some event ← pull .completion | return false
  return event.source == { kind := .library, id := fileService } && event.kind == .completion &&
      event.code == id

/-- Starts a load of `path` as the request `id`, waits for its completion and
takes its result. `none` when the request was refused, was not completed in
time, or left no result. -/
def loadResult (id : UInt64) (path : System.FilePath) (limit : UInt64) :
    IO (Option Editor.Ffi.FileResult) := do
  unless ← Editor.Ffi.filesLoad id path.toString limit do
    return none
  unless ← fileCompleted id do
    return none
  Editor.Ffi.filesTake id

/-- Starts a save of `snapshot` to `path` as the request `id`, waits for its
completion and takes its result. `none` as `loadResult`. -/
def saveResult (id : UInt64) (snapshot : Editor.Ffi.Snapshot) (path : System.FilePath)
    (expect : Editor.Ffi.FileExpect) : IO (Option Editor.Ffi.FileResult) := do
  unless ← Editor.Ffi.filesSave id snapshot path.toString expect do
    return none
  unless ← fileCompleted id do
    return none
  Editor.Ffi.filesTake id

/-- The refusal a file result is, if it is one. -/
def refusalOf : Editor.Ffi.FileResult → Option Editor.Ffi.FileRefusal
  | .refused refusal => some refusal
  | _ => none

/-- The stamp of a file result that is a save. -/
def savedStamp : Editor.Ffi.FileResult → Option Editor.Ffi.FileStamp
  | .saved stamp => some stamp
  | _ => none

/-- `values` as words: eight bytes each, least significant first. -/
def wordBytes (values : List UInt64) : ByteArray :=
  values.foldl
    (fun bytes word =>
      (List.range 8).foldl (fun bytes byte => bytes.push (word >>> (8 * byte).toUInt64).toUInt8)
        bytes)
    ByteArray.empty

/-- What `Editor.Ffi.FileResult.decode` makes of a status, words and a
detail, with no snapshot: a save's stamp, a refusal, or neither. -/
def decodedFile (status : UInt64) (values : List UInt64) (detail : String := "") :
    Option Editor.Ffi.FileStamp × Option Editor.Ffi.FileRefusal :=
  let result := (Editor.Ffi.FileResult.decode status none (wordBytes values) detail).toOption
  (result.bind savedStamp, result.bind refusalOf)

/-- Makes a document from `snapshot`, edits it and drops it. Only plain data
leaves: the text it then held. -/
def useCopy (snapshot : Editor.Ffi.Snapshot) : IO String := do
  let copy ← Editor.Ffi.Document.ofSnapshot snapshot
  discard <| copy.replace 0 1 "J"
  copy.read

/-- The checks of the file service's bindings and of a document made from a
snapshot. A load or a save goes in with an id, its completion comes back on
the completion queue, and its result is taken by the id. What a load and a
save do is the library's rule; these pin that the requests, their arguments
and every kind of result cross. Each check that touches a file does so in a
directory of its own (`inOwnDirectory`), and each request has an id no other
check uses. -/
def fileChecks (_ : Unit) : List Check :=
  [{
      name :=
        "a file is loaded through the file service: its completion comes back on the completion queue with the request's id, and its result, taken once, is a snapshot of the file's text, the file's stamp and its line endings",
      run :=
        inOwnDirectory fun directory => do
          let path := directory / "mixed.txt"
          IO.FS.writeBinFile path mixedBytes
          let modified := (← path.metadata).modified
          let before ← Editor.Ffi.Snapshot.live
          -- A request that was refused has no completion to wait for.
          unless ← Editor.Ffi.filesLoad 1001 path.toString 10 do
            return false
          let completed ← fileCompleted 1001
          let some (.loaded snapshot stamp lineFeeds crlfs) ←
            Editor.Ffi.filesTake 1001 | return false
          let again ← Editor.Ffi.filesTake 1001
          -- The snapshot is used below, so it is alive here.
          let whileHeld ← Editor.Ffi.Snapshot.live
          return completed && whileHeld == before + 1 && (← snapshot.read) == mixedText &&
              (← snapshot.info) == { revision := 0, byteLength := 16, rowCount := 3 } &&
              stamp ==
                { seconds := modified.sec, nanoseconds := modified.nsec.toUInt64, size := 10 } &&
              lineFeeds == 1 &&
              crlfs == 1 &&
              again.isNone },
    { name :=
        "a loaded snapshot saved to a second path writes the bytes the file had, and a save's expectation crosses whole: no file, whatever is there, and each number of a stamp"
      run :=
        inOwnDirectory fun directory => do
          let source := directory / "mixed.txt"
          let target := directory / "copy.txt"
          IO.FS.writeBinFile source mixedBytes
          let some (.loaded snapshot loaded _ _) ← loadResult 1010 source 1000 | return false
          let some first := (← saveResult 1011 snapshot target .absent).bind savedStamp
            | return false
          let written ← IO.FS.readBinFile target
          -- Each of these expects something the file is not, by one number.
          let refused ←
            [(1012, Editor.Ffi.FileExpect.absent),
                    (1013, .unchanged { first with seconds := first.seconds + 1 }),
                    (1014,
                      .unchanged
                        { first with nanoseconds := (first.nanoseconds + 1) % 1000000000 }),
                    (1015, .unchanged { first with size := first.size + 1 })].mapM
                fun (id, expect) => do
                return (← saveResult id snapshot target expect).bind refusalOf
          let nothingThere :=
            (← saveResult 1016 snapshot (directory / "none.txt") (.unchanged first)).bind refusalOf
          let some second := (← saveResult 1017 snapshot target (.unchanged first)).bind savedStamp
            | return false
          let whatever := (← saveResult 1018 snapshot target .whatever).bind savedStamp
          let over := (← saveResult 1019 snapshot source (.unchanged loaded)).bind savedStamp
          return written == mixedBytes && first.size == 10 &&
              refused.all (· == some (.changed (some first))) &&
              nothingThere == some (.changed none) &&
              second.size == 10 &&
              whatever.isSome &&
              over.isSome &&
              (← IO.FS.readBinFile source) == mixedBytes &&
              (← IO.FS.readBinFile target) == mixedBytes &&
              !(← (directory / "none.txt").pathExists) },
    { name :=
        "each refusal of a load crosses as itself, with its numbers: nothing there, a directory, a path that is not absolute, a NUL byte, and a file one byte over the limit, which loads at the limit"
      run :=
        inOwnDirectory fun directory => do
          let binary := directory / "binary"
          let long := directory / "long.txt"
          IO.FS.writeBinFile binary ⟨#[0x61, 0x62, 0x63, 0x00, 0x64]⟩
          IO.FS.writeBinFile long mixedBytes
          let notFound := (← loadResult 1020 (directory / "missing.txt") 1000).bind refusalOf
          let notAFile := (← loadResult 1021 directory 1000).bind refusalOf
          let relative := (← loadResult 1022 "relative.txt" 1000).bind refusalOf
          let isBinary := (← loadResult 1023 binary 1000).bind refusalOf
          let tooLarge := (← loadResult 1024 long 9).bind refusalOf
          let atLimit ← loadResult 1025 long 10
          return notFound == some .notFound && notAFile == some .notAFile &&
              relative == some .relativePath &&
              isBinary == some (.binary 3) &&
              tooLarge == some (.tooLarge 10 9) &&
              atLimit matches some (.loaded ..) },
    { name := "the file service has no result for an id that was a timer's"
      run := do
        let accepted ← Editor.Ffi.timersStart 1030 (← Editor.Ffi.timersNow)
        let some event ← pull .completion | return false
        return accepted && event.code == 1030 && (← Editor.Ffi.filesTake 1030).isNone },
    { name :=
        "a finished file request is pending until its result is taken or cancelled: its id is refused meanwhile, a cancel says whether there was anything to cancel, and a cancelled result is gone"
      run :=
        inOwnDirectory fun directory => do
          let path := directory / "held.txt"
          IO.FS.writeBinFile path mixedBytes
          let before ← Editor.Ffi.filesPending
          unless ← Editor.Ffi.filesLoad 1040 path.toString 1000 do
            return false
          let completed ← fileCompleted 1040
          let kept ← Editor.Ffi.filesPending
          let again ← Editor.Ffi.filesLoad 1040 path.toString 1000
          let cancelled ← Editor.Ffi.filesCancel 1040
          let twice ← Editor.Ffi.filesCancel 1040
          let never ← Editor.Ffi.filesCancel 1041
          return completed && kept == before + 1 && !again && cancelled && !twice && !never &&
              (← Editor.Ffi.filesTake 1040).isNone &&
              (← Editor.Ffi.filesPending) == before },
    { name :=
        "a document made from a snapshot holds what the snapshot holds at revision 0, is edited without the snapshot changing, and is freed when Lean drops the last reference"
      run := do
        let document ← Editor.Ffi.Document.new "héllo\r\nwörld\n😀x"
        -- The snapshot is at revision 1, so a copy that kept it is seen.
        discard <| document.replace 0 1 "j"
        let snapshot ← document.snapshot
        let before ← Editor.Ffi.Document.live
        let copy ← Editor.Ffi.Document.ofSnapshot snapshot
        let whileHeld ← Editor.Ffi.Document.live
        let edited ← useCopy snapshot
        let afterDrop ← Editor.Ffi.Document.live
        return whileHeld == before + 1 && edited == "Jéllo\r\nwörld\n😀x" &&
            afterDrop == before + 1 &&
            (← copy.read) == "jéllo\r\nwörld\n😀x" &&
            (← (← copy.snapshot).info).revision == 0 &&
            (← snapshot.read) == "jéllo\r\nwörld\n😀x" &&
            (← snapshot.info).revision == 1 },
    { name :=
        "a file result's words decode by its status: a stamp's seconds before 1970 are negative, and each refusal has its numbers or its detail"
      run :=
        pure
          (decodedFile 0 [0xFFFFFFFFFFFFFFFF, 5, 9] ==
              (some { seconds := -1, nanoseconds := 5, size := 9 }, none) &&
            decodedFile 0 [0x8000000000000000, 0, 0] ==
              (some { seconds := -9223372036854775808, nanoseconds := 0, size := 0 }, none) &&
            decodedFile 0 [0x7FFFFFFFFFFFFFFF, 999999999, 0xFFFFFFFFFFFFFFFF] ==
              (some {
                    seconds := 9223372036854775807, nanoseconds := 999999999
                    size := 0xFFFFFFFFFFFFFFFF },
                none) &&
            decodedFile 1 [] == (none, some .relativePath) &&
            decodedFile 2 [] == (none, some .notFound) &&
            decodedFile 3 [] == (none, some .notAFile) &&
            decodedFile 4 [] "not yours" == (none, some (.denied "not yours")) &&
            decodedFile 5 [7999] == (none, some (.binary 7999)) &&
            decodedFile 6 [11, 10] == (none, some (.tooLarge 11 10)) &&
            decodedFile 7 [1, 0xFFFFFFFFFFFFFFFE, 999999999, 12] ==
              (none,
                some (.changed (some { seconds := -2, nanoseconds := 999999999, size := 12 }))) &&
            decodedFile 7 [0, 0, 0, 0] == (none, some (.changed none)) &&
            decodedFile 8 [] == (none, some .noTemporaryName) &&
            decodedFile 9 [] "the disk is full" == (none, some (.failed "the disk is full"))) },
    { name :=
        "a file result the bindings cannot read is an error: a status the table does not have, words that are not the status's, and a load with no snapshot"
      run :=
        pure
          (([(10, []), (0, []), (0, [1, 2]), (0, [1, 2, 3, 4]), (0, [1, 2, 3, 4, 5]), (5, []),
                  (6, [1]), (7, [1, 2, 3]), (7, [2, 0, 0, 0]), (2, [1])].all
              fun ((status, values) : UInt64 × List UInt64) =>
              (Editor.Ffi.FileResult.decode status none (wordBytes values) "").toOption.isNone) &&
            (Editor.Ffi.FileResult.decode 0 none ⟨#[1, 2, 3]⟩ "").toOption.isNone) }]

/-- The id of the process service as the source of its completions. -/
def processService : UInt64 :=
  3

/-- Whether the next completion on the queue is the process service's, for
the run `id`. -/
def processCompleted (id : UInt64) : IO Bool := do
  let some event ← pull .completion | return false
  return event.source == { kind := .library, id := processService } && event.kind == .completion &&
      event.code == id

/-- Runs `/bin/sh -c script` in `directory` as the run `id`, waits for its
completion and takes its result. `none` when the run was refused, was not
completed in time, or left no result. -/
def processResult (id : UInt64) (script : String) (directory : System.FilePath)
    (limit : UInt64 := 1000000) (set : Array (String × String) := #[]) :
    IO (Option Editor.Ffi.ProcessResult) := do
  unless
    ← Editor.Ffi.processesRun id "/bin/sh" #["-c", script] false set #[] directory.toString limit do
    return none
  unless ← processCompleted id do
    return none
  Editor.Ffi.processesTake id

/-- What `Editor.Ffi.ProcessResult.decode` makes of a status, words and a
detail, with empty streams; `none` when it is an error. -/
def decodedProcess (status : UInt64) (values : List UInt64) (detail : String := "") :
    Option Editor.Ffi.ProcessResult :=
  (Editor.Ffi.ProcessResult.decode status (wordBytes values) detail .empty .empty).toOption

/-- What `Editor.Ffi.StreamReply.decode` makes of a status, words, a detail
and the two buffers; `none` when it is an error. -/
def decodedStream (status : UInt64) (values : List UInt64) (detail : String := "")
    (out err : ByteArray := .empty) : Option Editor.Ffi.StreamReply :=
  (Editor.Ffi.StreamReply.decode status (wordBytes values) detail out err).toOption

/-- The reply of the wait `wait` on a streaming child, once its completion
has come back; `none` when it did not come in time or left no reply. -/
def streamReply (wait : UInt64) : IO (Option Editor.Ffi.StreamReply) := do
  unless ← processCompleted wait do
    return none
  Editor.Ffi.processesTakeStream wait

/-- The checks of the process service's bindings. A run goes in with an id,
its completion comes back on the completion queue, and its result is taken by
the id. What a run does is the library's rule; these pin that a command, its
arguments, its environment and its limit cross, and that every kind of result
comes back. Each check runs its children in a directory of its own
(`inOwnDirectory`), and each run has an id no other check uses. -/
def processChecks (_ : Unit) : List Check :=
  [{  name :=
        "a command runs through the process service: its completion comes back on the completion queue with the run's id, and its result, taken once, is its status and both its streams, with the environment it was given"
      run :=
        inOwnDirectory fun directory => do
          let result ←
            processResult 1101 "printf %s \"$EDITOR_FFI_SET\"; printf 'e\\377' >&2; exit 3"
                directory (set := #[("EDITOR_FFI_SET", "given")])
          let again ← Editor.Ffi.processesTake 1101
          return result == some (.ran (.code 3) "given".toUTF8 ("e".toUTF8.push 0xFF)) &&
              again.isNone },
    { name :=
        "a refusal crosses with its words: a program that is not there is not found, naming it, and a directory that is not absolute is refused as itself"
      run :=
        inOwnDirectory fun directory => do
          let missing := "/nonexistent/editor-ffi-test"
          unless ← Editor.Ffi.processesRun 1110 missing #[] false #[] #[] directory.toString 10 do
            return false
          unless ← processCompleted 1110 do
            return false
          let notFound ←
            match ← Editor.Ffi.processesTake 1110 with
            | some (.notFound detail) =>
              pure (decide ((detail.splitOn missing).length > 1))
            | _ =>
              pure false
          let relative ← processResult 1111 "exit 0" "relative"
          return notFound && relative matches some (.relativeDirectory _) },
    { name := "a stream past the limit crosses as too large, with the stream and the limit"
      run :=
        inOwnDirectory fun directory => do
          let out ← processResult 1120 "printf abc" directory 2
          let err ← processResult 1121 "printf abc >&2" directory 2
          return out == some (.outputTooLarge .out 2) && err == some (.outputTooLarge .err 2) },
    { name :=
        "a run cancelled while its child sleeps is never completed, its child is reaped, and a cancel says whether there was anything to cancel"
      run :=
        inOwnDirectory fun directory => do
          let before ← Editor.Ffi.processesPending
          unless
            ←
              Editor.Ffi.processesRun 1130 "/bin/sleep" #["600"] false #[] #[] directory.toString
                  10 do
            return false
          let cancelled ← Editor.Ffi.processesCancel 1130
          let reaped ← eventually (return (← Editor.Ffi.processesPending) == before)
          let never ← Editor.Ffi.processesCancel 1131
          -- The next completion is the marker's, started after the cancel.
          let marker ← processResult 1132 "exit 0" directory
          return cancelled && reaped && !never && marker == some (.ran (.code 0) .empty .empty) &&
              (← Editor.Ffi.processesTake 1130).isNone },
    { name :=
        "a process result's words decode by its status: an exit by a status or a signal, each refusal with its detail, and a stream too large with its limit"
      run :=
        pure
          (decodedProcess 0 [0, 3] == some (.ran (.code 3) .empty .empty) &&
            decodedProcess 0 [1, 9] == some (.ran (.signal 9) .empty .empty) &&
            decodedProcess 1 [] "d" == some (.relativeDirectory "d") &&
            decodedProcess 2 [] "p" == some (.relativeProgram "p") &&
            decodedProcess 3 [] "n" == some (.notFound "n") &&
            decodedProcess 4 [] "no" == some (.denied "no") &&
            decodedProcess 5 [0, 4] == some (.outputTooLarge .out 4) &&
            decodedProcess 5 [1, 7] == some (.outputTooLarge .err 7) &&
            decodedProcess 6 [] "shut" == some (.shutDown "shut") &&
            decodedProcess 7 [] "f" == some (.failed "f")) },
    { name :=
        "a process result the bindings cannot read is an error: a status the table does not have, and words that are not the status's"
      run :=
        pure
          (([(8, []), (0, []), (0, [2, 0]), (0, [0]), (1, [1]), (5, [2, 1]), (5, [0]), (7, [0])].all
              fun ((status, values) : UInt64 × List UInt64) =>
              (decodedProcess status values).isNone) &&
            (Editor.Ffi.ProcessResult.decode 0 ⟨#[1, 2, 3]⟩ "" .empty .empty).toOption.isNone) },
    { name :=
        "a streaming child crosses the bindings: it opens, its first line is read as it writes it, a line written reaches it, a close ends its input, and its last delivery is its exit"
      run :=
        inOwnDirectory fun directory => do
          let script := "echo one; read x; echo \"$x\"; read y; exit 4"
          unless
            ←
              Editor.Ffi.processesOpen 1140 true false false "/bin/sh" #["-c", script] false #[] #[]
                  directory.toString 1000000 do
            return false
          let opened ← streamReply 1140
          unless ← Editor.Ffi.processesRead 1140 1141 do
            return false
          let first ← streamReply 1141
          unless ← Editor.Ffi.processesWrite 1140 1142 "two\n".toUTF8 do
            return false
          let written ← streamReply 1142
          unless ← Editor.Ffi.processesRead 1140 1143 do
            return false
          let second ← streamReply 1143
          unless ← Editor.Ffi.processesCloseInput 1140 1144 do
            return false
          let closed ← streamReply 1144
          let mut last := none
          for wait in [1145:1165] do
            unless ← Editor.Ffi.processesRead 1140 wait.toUInt64 do
              break
            last ← streamReply wait.toUInt64
            if let some (.delivered _ _ (some _)) := last then
              break
          return opened == some .opened &&
              first == some (.delivered (.lines #["one".toUTF8]) (.lines #[]) none) &&
              written == some .written &&
              second == some (.delivered (.lines #["two".toUTF8]) (.lines #[]) none) &&
              closed == some .written &&
              (match last with
              | some (.delivered _ _ (some (.exited (.code 4)))) => true
              | _ => false) },
    { name :=
        "whether a streaming child is held crosses the bindings: a child that writes for ever, never read, comes to be held at its bound, an id the service does not hold is 2, and a cancel reaps the held child and forgets it"
      run :=
        inOwnDirectory fun directory => do
          let before ← Editor.Ffi.processesPending
          unless
            ←
              Editor.Ffi.processesOpen 1170 false false false "/bin/sh"
                  #["-c", "while :; do echo y; done"] false #[] #[] directory.toString 16 do
            return false
          -- Every step runs whatever the one before it found, so the cancel
          -- always comes and no child is left writing.
          let opened ← streamReply 1170
          let held ← eventually (return (← Editor.Ffi.processesHeld 1170) == 1)
          let unknown ← Editor.Ffi.processesHeld 1171
          let cancelled ← Editor.Ffi.processesCancel 1170
          let reaped ← eventually (return (← Editor.Ffi.processesPending) == before)
          let forgotten ← Editor.Ffi.processesHeld 1170
          return opened == some .opened && held && unknown == 2 && cancelled && reaped &&
              forgotten == 2 },
    { name :=
        "a stream reply's words decode by its status: opened, written, input closed, each refusal, and a delivery's lines by their lengths, its bytes and each end"
      run :=
        pure
          (decodedStream 10 [] == some .opened && decodedStream 12 [] == some .written &&
            decodedStream 8 [] "c" == some (.inputClosed "c") &&
            decodedStream 3 [] "n" == some (.refused (.notFound "n")) &&
            decodedStream 6 [] "s" == some (.refused (.shutDown "s")) &&
            decodedStream 11 [0, 2, 3, 0, 1, 0] "" "one".toUTF8 ("x".toUTF8.push 0xFF) ==
              some
                (.delivered (.lines #["one".toUTF8, .empty]) (.bytes ("x".toUTF8.push 0xFF))
                  none) &&
            decodedStream 11 [0, 0, 0, 0, 1, 0, 4] ==
              some (.delivered (.lines #[]) (.lines #[]) (some (.exited (.code 4)))) &&
            decodedStream 11 [0, 0, 0, 0, 1, 1, 9] ==
              some (.delivered (.lines #[]) (.lines #[]) (some (.exited (.signal 9)))) &&
            decodedStream 11 [0, 0, 0, 0, 2, 1, 64] ==
              some (.delivered (.lines #[]) (.lines #[]) (some (.lineTooLong .err 64))) &&
            decodedStream 11 [1, 1, 3] "EIO" ==
              some (.delivered (.bytes .empty) (.bytes .empty) (some (.failed "EIO")))) },
    { name :=
        "a stream reply the bindings cannot read is an error: a status the table does not have, line lengths that do not add up, words left over, and words a status has none of"
      run :=
        pure
          ((decodedStream 9 []).isNone && (decodedStream 0 [0, 3]).isNone &&
            (decodedStream 11 [0, 1, 4, 0, 0] "" "one".toUTF8).isNone &&
            (decodedStream 11 [0, 0, 0, 0, 0, 7]).isNone &&
            (decodedStream 11 [0, 0, 0, 0, 4]).isNone &&
            (decodedStream 10 [1]).isNone) }]

/-- The checks of the two event queues: Rust threads push, Lean pulls. -/
def queueChecks (_ : Unit) : List Check :=
  [{ name := "events posted to a queue are pulled from that queue, in order",
     run := do
       let first ← Editor.Ffi.postEvent .editor 5 1 ""
       let other ← Editor.Ffi.postEvent .completion 5 2 ""
       let second ← Editor.Ffi.postEvent .editor 5 3 ""
       -- The completion queue first: were the two one queue, this would be
       -- the first event posted.
       let fromCompletion ← pull .completion
       let fromEditor := [← pull .editor, ← pull .editor]
       return first && other && second && fromCompletion == some (message 5 2 "") &&
           fromEditor == [some (message 5 1 ""), some (message 5 3 "")] },
    { name := "a pull parks until an event is posted to its queue"
      run := do
        let task ← IO.asTask (prio := .dedicated) (Editor.Ffi.nextEvent .completion)
        let parked ← eventually (return (← Editor.Ffi.waiting .completion) == 1)
        let othersParked ← Editor.Ffi.waiting .editor
        let finishedEarly ← IO.hasFinished task
        let posted ← Editor.Ffi.postEvent .completion 6 1 "wake"
        let woken ← eventually (IO.hasFinished task)
        unless parked && othersParked == 0 && !finishedEarly && posted && woken do
          return false
        return (← IO.ofExcept task.get) == message 6 1 "wake" },
    { name := "a script fed from a Rust thread arrives in order, tagged with its source"
      run := do
        unless ← Editor.Ffi.feedScript .completion 9 3 do
          return false
        for code in ([0, 1, 2] : List UInt64) do
          let some event ← pull .completion | return false
          unless
            event.source == { kind := .script, id := 9 } && event.kind == .message &&
              event.code == code do
            return false
        return true },
    { name :=
        "an event's words cross whole and in order: each scripted event carries its code and the largest word less its code"
      run := do
        unless ← Editor.Ffi.feedScript .completion 9 2 do
          return false
        let first ← pull .completion
        let second ← pull .completion
        return (first.map (·.words)) == some #[0, 0xFFFFFFFFFFFFFFFF] &&
            (second.map (·.words)) == some #[1, 0xFFFFFFFFFFFFFFFE] },
    { name := "an event posted from Lean has no words"
      run := do
        unless ← Editor.Ffi.postEvent .editor 12 1 "" do
          return false
        return ((← pull .editor).map (·.words)) == some #[] }]

/-- Makes a document holding `text`, appends "!" to it and drops it. Only
plain data leaves: the text it then held. -/
def useDocument (text : String) : IO String := do
  let document ← Editor.Ffi.Document.new text
  discard <| document.replace text.utf8ByteSize.toUSize text.utf8ByteSize.toUSize "!"
  document.read

/-- The checks of a document (`Editor.Ffi.Document`): a handle whose bindings
take a string and hand one back. "é" and "ö" are two bytes each, so in
`"héllo"` the byte offset 2 is inside a character. -/
def documentChecks (_ : Unit) : List Check :=
  [{
      name :=
        "a document reads back the text it was made with, multi-byte characters and an embedded NUL included",
      run := do
        let document ← Editor.Ffi.Document.new "héllo\x00wörld"
        let empty ← Editor.Ffi.Document.new ""
        return (← document.read) == "héllo\x00wörld" && (← empty.read) == "" },
    { name := "a replace changes a document's text at its byte offsets and returns true"
      run := do
        let document ← Editor.Ffi.Document.new "héllo wörld"
        -- The start and the stop differ, so swapping them is seen, and so
        -- is swapping either with the text's length.
        let replaced ← document.replace 7 13 "there!"
        let afterReplace ← document.read
        let inserted ← document.replace 3 3 "XY"
        let deleted ← document.replace 0 1 ""
        return replaced && afterReplace == "héllo there!" && inserted && deleted &&
            (← document.read) == "éXYllo there!" },
    { name := "a refused replace returns false and leaves a document's text as it was"
      run := do
        let document ← Editor.Ffi.Document.new "héllo"
        let insideCharacter ← document.replace 2 2 "x"
        let backwards ← document.replace 3 1 "x"
        let pastEnd ← document.replace 7 7 "x"
        return !insideCharacter && !backwards && !pastEnd && (← document.read) == "héllo" },
    { name := "a document is freed when Lean drops the last reference"
      run := do
        let before ← Editor.Ffi.Document.live
        let held ← Editor.Ffi.Document.new "held"
        let whileHeld ← Editor.Ffi.Document.live
        discard <| useDocument "dropped"
        let afterDrop ← Editor.Ffi.Document.live
        -- `held` is used here, so it is alive until now.
        return whileHeld == before + 1 && afterDrop == before + 1 && (← held.read) == "held" }]

/-- Text of three rows. "é" and "ö" are two bytes and one UTF-16 unit each,
and "😀" is four bytes and two units. The first row ends in a carriage return
and a line feed, at the bytes 6 and 7; the second starts at 8; the third
starts at 15 with "😀", and its "x" is at 19. The text is 20 bytes long. -/
def rows : String :=
  "héllo\r\nwörld\n😀x"

/-- A snapshot of a document made here holding `text`. The document is
dropped on the way out, so the snapshot is all that is left of it. -/
def snapshotOf (text : String) : IO Editor.Ffi.Snapshot := do
  let document ← Editor.Ffi.Document.new text
  document.snapshot

/-- Takes a snapshot of `document`, reads it and drops it. Only plain data
leaves: the text the snapshot held. -/
def useSnapshot (document : Editor.Ffi.Document) : IO String := do
  let snapshot ← document.snapshot
  snapshot.read

/-- Text of four rows, 30 bytes long, for the motions. Row 0 is `foo.bar`,
two spaces and `x`, and ends in a carriage return and a line feed at the
bytes 10 and 11; row 1 is empty, a carriage return and a line feed at 12 and
13; row 2 starts at 14 with a tab, then `s`, `e`, a combining acute (two
bytes, at 17), "😀" (four, at 19), `!`, a space and `y`, and ends in a line
feed at 26; row 3 is `end`, from 27. -/
def moved : String :=
  "foo.bar  x\r\n\r\n\tsé😀! y\nend"

/-- Every motion the library has, each with what it answers from the offsets
3, 7 and 15 of `moved`: the `.` after `foo`, the first of the two spaces, and
the `s` of row 2. The answers are the library's rule (`crates/editor-text`);
they are here so that a motion sent under another's tag is seen, which is why
no two rows have the same three. -/
def motionAnswers : List (Editor.Ffi.Motion × UInt64 × UInt64 × UInt64) :=
  [(.nextCell, 4, 8, 16), (.previousCell, 2, 6, 14), (.nextWordStart .word, 4, 9, 23),
    (.nextWordEnd .word, 6, 9, 19), (.previousWordStart .word, 0, 4, 12),
    (.previousWordEnd .word, 2, 6, 12), (.nextWordStart .bigWord, 9, 9, 25),
    (.nextWordEnd .bigWord, 6, 9, 23), (.previousWordStart .bigWord, 0, 0, 12),
    (.previousWordEnd .bigWord, 0, 6, 12), (.lineStart, 0, 0, 14), (.lineEnd, 10, 10, 26),
    (.lineFirstNonBlank, 0, 0, 15), (.textStart, 0, 0, 0), (.textEnd, 30, 30, 30),
    (.rowsUp 1 4, 4, 4, 12), (.rowsDown 1 2, 12, 12, 29)]

/-- The largest number a word holds, which no text accepts as a length or an
offset, and which a motion by rows reads as a count or a column past any
text's. -/
def largestWord : UInt64 :=
  0xFFFF_FFFF_FFFF_FFFF

/-- The checks of a snapshot (`Editor.Ffi.Snapshot`): a handle made by a call
on another handle, whose bindings hand back a structure of numbers and take
an enumeration. What a row, a point, a cell and a word are is the library's
rule; these pin that the values cross. -/
def snapshotChecks (_ : Unit) : List Check :=
  [{
      name :=
        "a snapshot reads what its document held when it was taken, after the document is edited",
      run := do
        let document ← Editor.Ffi.Document.new rows
        let snapshot ← document.snapshot
        let edited ← document.replace 0 1 "J"
        return edited && (← snapshot.read) == rows && (← document.read) == "Jéllo\r\nwörld\n😀x" },
    { name := "a snapshot's info is its revision, its length in bytes and its row count"
      run := do
        let document ← Editor.Ffi.Document.new rows
        let first ← document.snapshot
        -- Two edits, which leave 15 bytes: three different numbers, so a
        -- field read from another's place is seen.
        discard <| document.replace 0 1 "J"
        discard <| document.replace 15 20 ""
        let second ← document.snapshot
        return (← first.info) == { revision := 0, byteLength := 20, rowCount := 3 } &&
            (← second.info) == { revision := 2, byteLength := 15, rowCount := 3 } },
    { name := "the point of an offset and the offset of a point cross in both units"
      run := do
        let snapshot ← snapshotOf rows
        -- The "x" after "😀": four bytes into its row, and two units.
        let inBytes ← snapshot.pointOf .bytes 19
        let inUnits ← snapshot.pointOf .utf16 19
        let fromBytes ← snapshot.offsetOf .bytes 2 4
        let fromUnits ← snapshot.offsetOf .utf16 2 2
        -- Row 1, column 3 is the "r" of "wörld". Were the row and the column
        -- swapped it would be refused: the text has no row 3.
        let unswapped ← snapshot.offsetOf .bytes 1 3
        return inBytes == some { row := 2, column := 4 } &&
            inUnits == some { row := 2, column := 2 } &&
            fromBytes == some 19 &&
            fromUnits == some 19 &&
            unswapped == some 11 },
    { name := "an offset or a point that is not a position of the text has no point and no offset"
      run := do
        let snapshot ← snapshotOf rows
        let insideCharacter ← snapshot.pointOf .bytes 2
        let pastEnd ← snapshot.pointOf .utf16 21
        let noSuchRow ← snapshot.offsetOf .bytes 3 0
        let pastRowEnd ← snapshot.offsetOf .bytes 0 8
        let betweenUnits ← snapshot.offsetOf .utf16 2 1
        return insideCharacter == none && pastEnd == none && noSuchRow == none &&
            pastRowEnd == none &&
            betweenUnits == none },
    { name := "the point of an offset and the offset of a point cross in cells"
      run := do
        let snapshot ← snapshotOf rows
        -- The "x" after "😀" is the second cell of its row, where it is four
        -- bytes and two units in. The position between the carriage return
        -- and the line feed of row 0 is the last column the row has.
        let afterWide ← snapshot.pointOf .cells 19
        let fromCells ← snapshot.offsetOf .cells 2 1
        let between ← snapshot.pointOf .cells 7
        let lastColumn ← snapshot.offsetOf .cells 0 6
        let pastRowEnd ← snapshot.offsetOf .cells 0 7
        return afterWide == some { row := 2, column := 1 } && fromCells == some 19 &&
            between == some { row := 0, column := 6 } &&
            lastColumn == some 7 &&
            pastRowEnd == none },
    { name :=
        "each motion crosses under its own tag: from three offsets of a text it answers what the library's table says, and no two motions answer alike"
      run := do
        let snapshot ← snapshotOf moved
        let crossed ←
          motionAnswers.allM fun (motion, from3, from7, from15) =>
              return (← snapshot.motion motion 3) == some from3 &&
                  (← snapshot.motion motion 7) == some from7 &&
                  (← snapshot.motion motion 15) == some from15
        let apart := (motionAnswers.map (·.2)).eraseDups.length == motionAnswers.length
        return crossed && apart && motionAnswers.length == 17 },
    { name :=
        "a count and a column cross to the motions by rows, each in its own place, and the largest a word holds is answered"
      run := do
        let snapshot ← snapshotOf moved
        -- Two rows down at column 1 is the "s" of row 2, and one row down at
        -- column 2 the empty row 1: swapped, the two would answer alike.
        let twoDown ← snapshot.motion (.rowsDown 2 1) 0
        let oneDown ← snapshot.motion (.rowsDown 1 2) 0
        let twoUp ← snapshot.motion (.rowsUp 2 1) 30
        let oneUp ← snapshot.motion (.rowsUp 1 2) 30
        let farDown ← snapshot.motion (.rowsDown largestWord largestWord) 0
        let farUp ← snapshot.motion (.rowsUp largestWord 0) 30
        return twoDown == some 15 && oneDown == some 12 && twoUp == some 12 && oneUp == some 16 &&
            farDown == some 30 &&
            farUp == some 0 },
    { name := "a motion from an offset that is not a position of the text has no answer"
      run := do
        let snapshot ← snapshotOf moved
        -- 18 is inside the combining mark, and 31 is past the end.
        motionAnswers.allM fun (motion, _) =>
            return (← snapshot.motion motion 18) == none && (← snapshot.motion motion 31) == none },
    { name :=
        "the content of a row and a range of the text cross, characters of several bytes included"
      run := do
        let snapshot ← snapshotOf rows
        let first ← snapshot.row 0
        let second ← snapshot.row 1
        let third ← snapshot.row 2
        let range ← snapshot.slice 1 9
        let wide ← snapshot.slice 15 20
        let empty ← snapshot.slice 4 4
        let whole ← snapshot.slice 0 20
        return first == some "héllo" && second == some "wörld" && third == some "😀x" &&
            range == some "éllo\r\nw" &&
            wide == some "😀x" &&
            empty == some "" &&
            whole == some rows },
    { name :=
        "a row the text does not have and a range that is not two positions in order have no text"
      run := do
        let snapshot ← snapshotOf rows
        let noSuchRow ← snapshot.row 3
        let backwards ← snapshot.slice 9 1
        let insideCharacter ← snapshot.slice 0 2
        let pastEnd ← snapshot.slice 0 21
        return noSuchRow == none && backwards == none && insideCharacter == none &&
            pastEnd == none },
    { name := "a snapshot is freed when Lean drops the last reference"
      run := do
        let document ← Editor.Ffi.Document.new "held"
        let before ← Editor.Ffi.Snapshot.live
        let held ← document.snapshot
        let whileHeld ← Editor.Ffi.Snapshot.live
        let dropped ← useSnapshot document
        let afterDrop ← Editor.Ffi.Snapshot.live
        -- `held` is used here, so it is alive until now.
        return whileHeld == before + 1 && dropped == "held" && afterDrop == before + 1 &&
            (← held.read) == "held" },
    { name := "a snapshot outlives its document"
      run := do
        let before ← Editor.Ffi.Document.live
        let snapshot ← snapshotOf rows
        -- The document was dropped inside `snapshotOf`.
        let documents ← Editor.Ffi.Document.live
        return documents == before && (← snapshot.read) == rows &&
            (← snapshot.info).byteLength == 20 }]

/-- A transaction over `rows` with every kind of change and both selections:
"a\nb" is inserted after "hé", "o\r\nw" is deleted, and "rl" is replaced by
"RLX". It makes "héa\nbllöRLXd\n😀x", whose second row starts at 5. -/
def threeChanges : Editor.Ffi.Transaction where
  changes :=
    #[.retain 3, .insert "a\nb", .retain 2, .delete 4, .retain 2, .insert "RLX", .delete 2,
      .retain 7]
  before :=
    some { ranges := #[{ anchor := 0, head := 3 }, { anchor := 20, head := 15 }], primary := 1 }
  after := some { ranges := #[{ anchor := 6, head := 6 }] }

/-- The span from `start` to `stop` whose points are the two (row, column)
pairs. -/
def span (start stop : UInt64) (startPoint stopPoint : UInt64 × UInt64) : Editor.Ffi.Span where
  start := start
  stop := stop
  startPoint := { row := startPoint.1, column := startPoint.2 }
  stopPoint := { row := stopPoint.1, column := stopPoint.2 }

/-- Two results are equal when they are the same answer or the same
refusal. -/
instance {ε α : Type} [BEq ε] [BEq α] : BEq (Except ε α) where
  beq
    | .ok one, .ok other => one == other
    | .error one, .error other => one == other
    | _, _ => false

/-- The checks of a document's transactions and its edit log: the example of
lists crossing, as words, in both directions. What a transaction does and
what the log holds are the library's rules; these pin that the values
cross. -/
def transactionChecks (_ : Unit) : List Check :=
  [{  name :=
        "a transaction with every kind of change, multi-byte text and selections is applied, and the document reads back"
      run := do
        let document ← Editor.Ffi.Document.new rows
        let applied ← document.apply threeChanges 7
        return applied == .ok 1 && (← document.read) == "héa\nbllöRLXd\n😀x" },
    { name := "a transaction whose selections have each shape is applied"
      run := do
        let document ← Editor.Ffi.Document.new rows
        let shapes : List Editor.Ffi.Shape := [.exclusive, .inclusive, .line, .block]
        let applied ←
          shapes.mapM fun shape =>
              document.apply
                { changes := #[.retain 20]
                  before := some { ranges := #[{ anchor := 0, head := 3 }], shape }
                  after :=
                    some
                      { ranges := #[{ anchor := 20, head := 15 }, { anchor := 1, head := 1 }]
                        primary := 1
                        shape } }
                0
        return applied == [.ok 1, .ok 2, .ok 3, .ok 4] },
    { name := "the revision a transaction returns is the revision of a snapshot taken then"
      run := do
        let document ← Editor.Ffi.Document.new rows
        let first ← document.apply { changes := #[.retain 20] } 0
        let second ← document.apply { changes := #[.insert "x", .retain 20] } 0
        return first == .ok 1 && second == .ok 2 && (← (← document.snapshot).info).revision == 2 },
    { name := "each refusal of a transaction crosses as itself and changes nothing"
      run := do
        let document ← Editor.Ffi.Document.new rows
        let short ← document.apply { changes := #[.retain 19] } 0
        let insideCharacter ← document.apply { changes := #[.retain 2, .delete 18] } 0
        let astray ←
          document.apply
              { changes := #[.retain 20],
                before := some { ranges := #[{ anchor := 2, head := 0 }] } }
              0
        let noRange ← document.apply { changes := #[.retain 20], after := some { ranges := #[] } } 0
        let noPrimary ←
          document.apply
              { changes := #[.retain 20]
                before := some { ranges := #[{ anchor := 0, head := 0 }], primary := 1 } } 0
        -- A selection that is none is refused before changes that do not fit.
        let both ← document.apply { changes := #[.retain 19], after := some { ranges := #[] } } 0
        return short == .error .badChange && insideCharacter == .error .badChange &&
            astray == .error .badSelection &&
            noRange == .error .badSelection &&
            noPrimary == .error .badSelection &&
            both == .error .badSelection &&
            (← document.read) == rows &&
            (← (← document.snapshot).info).revision == 0 },
    { name := "a length or an offset that is the largest word is refused and changes nothing"
      run := do
        let document ← Editor.Ffi.Document.new rows
        let retained ← document.apply { changes := #[.retain largestWord] } 0
        let deleted ← document.apply { changes := #[.delete largestWord, .retain 20] } 0
        let selected ←
          document.apply
              { changes := #[.retain 20]
                after := some { ranges := #[{ anchor := 0, head := largestWord }] } } 0
        return retained == .error .badChange && deleted == .error .badChange &&
            selected == .error .badSelection &&
            (← document.read) == rows },
    { name :=
        "what changed since a revision comes back as the edits, each with its offsets and points"
      run := do
        let document ← Editor.Ffi.Document.new rows
        discard <| document.apply threeChanges 7
        let patch ← document.changesSince 0
        let nothing ← document.changesSince 1
        return patch ==
              .ok {
                  since := 0
                  revision := 1
                  edits :=
                    #[{ old := span 3 3 (0, 3) (0, 3), new := span 3 6 (0, 3) (1, 1) },
                      { old := span 5 9 (0, 5) (1, 1), new := span 8 8 (1, 3) (1, 3) },
                      { old := span 11 13 (1, 3) (1, 5), new := span 10 13 (1, 5) (1, 8) }] } &&
            nothing == .ok { since := 1, revision := 1, edits := #[] } },
    { name := "several transactions come back as one patch"
      run := do
        let document ← Editor.Ffi.Document.new "ab"
        discard <| document.apply { changes := #[.retain 1, .insert "X", .retain 1] } 1
        discard <| document.apply { changes := #[.retain 2, .insert "Y", .retain 1] } 2
        let patch ← document.changesSince 0
        return patch ==
            .ok {
                since := 0
                revision := 2
                edits := #[{ old := span 1 1 (0, 1) (0, 1), new := span 1 3 (0, 1) (0, 3) }] } },
    { name := "a trace names the revision and the origin each transaction was applied with"
      run := do
        let document ← Editor.Ffi.Document.new "héllo"
        discard <| document.apply { changes := #[.retain 6, .insert "!"] } 7
        discard <| document.apply { changes := #[.insert "¡", .retain 7] } largestWord
        let trace ← document.trace 0 9
        let part ← document.trace 2 5
        return trace ==
              some
                #[{ start := 0, stop := 2, author := .entry 2 largestWord },
                  { start := 2, stop := 8, author := .earlier 0 },
                  { start := 8, stop := 9, author := .entry 1 7 }] &&
            part == some #[{ start := 2, stop := 5, author := .earlier 0 }] },
    { name :=
        "a trace of an empty range is empty, and of a range that is not two positions in order is none"
      run := do
        let document ← Editor.Ffi.Document.new "héllo"
        let empty ← document.trace 3 3
        let insideCharacter ← document.trace 0 2
        let backwards ← document.trace 3 1
        let pastEnd ← document.trace 0 7
        return empty == some #[] && insideCharacter == none && backwards == none &&
            pastEnd == none },
    { name := "forgetting moves where the log starts, and each refusal of the log crosses as itself"
      run := do
        let document ← Editor.Ffi.Document.new "héllo"
        discard <| document.apply { changes := #[.retain 6, .insert "!"] } 7
        discard <| document.apply { changes := #[.insert "¡", .retain 7] } 9
        let ahead ← document.forget 3
        let forgot ← document.forget 1
        let behind ← document.changesSince 0
        let atHorizon ← document.changesSince 1
        let unknown ← document.changesSince 3
        let trace ← document.trace 0 9
        return !ahead && forgot && behind == .error .forgotten &&
            atHorizon ==
              .ok {
                  since := 1
                  revision := 2
                  edits := #[{ old := span 0 0 (0, 0) (0, 0), new := span 0 2 (0, 0) (0, 2) }] } &&
            unknown == .error .unknownRevision &&
            trace ==
              some
                #[{ start := 0, stop := 2, author := .entry 2 9 },
                  { start := 2, stop := 9, author := .earlier 1 }] &&
            (← document.read) == "¡héllo!" },
    { name := "a transaction with no change, and one that inserts an empty string, cross"
      run := do
        let document ← Editor.Ffi.Document.new ""
        let noChange ← document.apply { changes := #[] } 0
        let empty ← document.apply { changes := #[.insert ""] } 0
        let patch ← document.changesSince 0
        return noChange == .ok 1 && empty == .ok 2 && (← document.read) == "" &&
            patch == .ok { since := 0, revision := 2, edits := #[] } }]

/-- The checks of a document's markers and of what a selection covers: words
crossing in both directions for one value. Where a marker goes, which are
refused and what a shape covers are the library's rules; these pin that the
values cross. -/
def markerChecks (_ : Unit) : List Check :=
  [{  name := "an anchor of each bias is marked and reads back"
      run := do
        let document ← Editor.Ffi.Document.new rows
        let before : Editor.Ffi.Marker := .anchor { offset := 3, bias := .before }
        let after : Editor.Ffi.Marker := .anchor { offset := 19, bias := .after }
        let .ok first ← document.mark before | return false
        let .ok second ← document.mark after | return false
        return first != second && (← document.marker first) == some before &&
            (← document.marker second) == some after },
    { name := "a selection of each shape is marked and reads back, with its primary and its ranges"
      run := do
        let document ← Editor.Ffi.Document.new rows
        let shapes : List Editor.Ffi.Shape := [.exclusive, .inclusive, .line, .block]
        shapes.allM fun shape => do
            -- Two ranges that are apart and in order, the second pointing
            -- backward and the primary.
            let marker : Editor.Ffi.Marker :=
              .selection
                { ranges := #[{ anchor := 0, head := 3 }, { anchor := 20, head := 15 }]
                  primary := 1
                  shape }
            let .ok id ← document.mark marker | return false
            return (← document.marker id) == some marker },
    { name := "each refusal of a marker crosses as itself"
      run := do
        let document ← Editor.Ffi.Document.new rows
        let .ok id ← document.mark (.anchor { offset := 0, bias := .after }) | return false
        let insideCharacter ← document.mark (.anchor { offset := 2, bias := .before })
        let pastEnd ← document.mark (.anchor { offset := largestWord, bias := .after })
        let astray ← document.mark (.selection { ranges := #[{ anchor := 0, head := 2 }] })
        let noRange ← document.mark (.selection { ranges := #[], shape := .line })
        let noPrimary ←
          document.mark (.selection { ranges := #[{ anchor := 0, head := 0 }], primary := 1 })
        let unknown ← document.place (id + 1) (.anchor { offset := 0, bias := .after })
        let misplaced ← document.place id (.anchor { offset := 2, bias := .after })
        -- A selection that is none is refused before the id is looked up.
        let noneForUnknown ← document.place (id + 1) (.selection { ranges := #[] })
        return insideCharacter == .error .badPosition && pastEnd == .error .badPosition &&
            astray == .error .badSelection &&
            noRange == .error .badSelection &&
            noPrimary == .error .badSelection &&
            unknown == .error .noSuchMarker &&
            misplaced == .error .badPosition &&
            noneForUnknown == .error .badSelection &&
            (← document.marker (id + 1)) == none &&
            (← document.marker id) == some (.anchor { offset := 0, bias := .after }) },
    { name := "a marker moves when its document is edited"
      run := do
        let document ← Editor.Ffi.Document.new rows
        let .ok anchor ← document.mark (.anchor { offset := 3, bias := .after }) | return false
        let .ok selection ←
          document.mark
              (.selection
                { ranges := #[{ anchor := 8, head := 13 }], shape := .line }) | return false
        discard <| document.apply { changes := #[.insert "XY", .retain 20] } 0
        return (← document.marker anchor) == some (.anchor { offset := 5, bias := .after }) &&
            (← document.marker selection) ==
              some (.selection { ranges := #[{ anchor := 10, head := 15 }], shape := .line }) },
    { name := "a marker is put somewhere else, made the other kind, and given up"
      run := do
        let document ← Editor.Ffi.Document.new rows
        let .ok id ← document.mark (.anchor { offset := 3, bias := .after }) | return false
        let cursor : Editor.Ffi.Marker :=
          .selection { ranges := #[{ anchor := 4, head := 4 }], shape := .inclusive }
        let placed ← document.place id cursor
        let moved ← document.marker id
        let givenUp ← document.unmark id
        let again ← document.unmark id
        return placed == .ok () && moved == some cursor && givenUp && !again &&
            (← document.marker id) == none &&
            (← document.place id cursor) == .error .noSuchMarker },
    { name := "what a selection covers crosses as its extents, and a selection with none as nothing"
      run := do
        let snapshot ← snapshotOf rows
        let range ← snapshot.extents { ranges := #[{ anchor := 3, head := 1 }] }
        let cursors ←
          snapshot.extents
              { ranges := #[{ anchor := 19, head := 19 }, { anchor := 1, head := 1 }]
                shape := .inclusive }
        let astray ← snapshot.extents { ranges := #[{ anchor := 0, head := 2 }] }
        let pastEnd ← snapshot.extents { ranges := #[{ anchor := 0, head := largestWord }] }
        let noRange ← snapshot.extents { ranges := #[], shape := .block }
        return range == some #[{ start := 1, stop := 3 }] &&
            cursors == some #[{ start := 1, stop := 3 }, { start := 19, stop := 20 }] &&
            astray == none &&
            pastEnd == none &&
            noRange == none }]

/-- The checks of a document's kept inverses: a run of revisions and an
origin in, as numbers, and what the inverse did out, as words with an option
in them. What the inverse of a run does, when it is refused and what it hands
back are the library's rules; these pin that the values cross. -/
def inverseChecks (_ : Unit) : List Check :=
  [{  name := "an inverse crosses with its revision and the selection it hands back, of each shape"
      run := do
        let shapes : List Editor.Ffi.Shape := [.exclusive, .inclusive, .line, .block]
        shapes.allM fun shape => do
            let document ← Editor.Ffi.Document.new rows
            -- Two ranges that are apart and in order, the second pointing
            -- backward and the primary.
            let before : Editor.Ffi.Selection :=
              { ranges := #[{ anchor := 0, head := 3 }, { anchor := 20, head := 15 }]
                primary := 1
                shape }
            discard <|
                document.apply { changes := #[.insert "XY", .retain 20], before := some before } 7
            let inverted ← document.applyInverse 1 1 9
            return inverted == .ok { revision := 2, selection := some before } &&
                (← document.read) == rows },
    { name := "an inverse that hands back no selection crosses with none"
      run := do
        let document ← Editor.Ffi.Document.new rows
        discard <|
            document.apply
              { changes := #[.insert "XY", .retain 20]
                after := some { ranges := #[{ anchor := 2, head := 2 }] } } 7
        let inverted ← document.applyInverse 1 1 9
        return inverted == .ok { revision := 2, selection := none } && (← document.read) == rows },
    { name := "the inverse of an inverse crosses, and each has the origin it was given"
      run := do
        let document ← Editor.Ffi.Document.new "héllo"
        let cursor : Editor.Ffi.Selection :=
          { ranges := #[{ anchor := 1, head := 1 }], shape := .inclusive }
        discard <|
            document.apply { changes := #[.retain 1, .delete 2, .retain 3], after := some cursor } 7
        let undone ← document.applyInverse 1 1 9
        let restored ← document.trace 0 6
        let redone ← document.applyInverse 2 2 largestWord
        let again ← document.applyInverse 3 3 11
        return undone == .ok { revision := 2, selection := none } &&
            restored ==
              some
                #[{ start := 0, stop := 1, author := .earlier 0 },
                  { start := 1, stop := 3, author := .entry 2 9 },
                  { start := 3, stop := 6, author := .earlier 0 }] &&
            redone == .ok { revision := 3, selection := some cursor } &&
            again == .ok { revision := 4, selection := none } &&
            (← document.trace 1 3) == some #[{ start := 1, stop := 3, author := .entry 4 11 }] &&
            (← document.read) == "héllo" },
    { name := "each refusal of an inverse crosses as itself and changes nothing"
      run := do
        let document ← Editor.Ffi.Document.new "héllo"
        discard <| document.apply { changes := #[.retain 6, .insert "!"] } 0
        discard <| document.apply { changes := #[.insert "¡", .retain 7] } 0
        let ahead ← document.applyInverse 1 3 0
        let noWord ← document.applyInverse largestWord largestWord 0
        let fromZero ← document.applyInverse 0 2 0
        let backwards ← document.applyInverse 2 1 0
        let elsewhere ← document.applyInverse 1 1 0
        return ahead == .error .unknownRevision && noWord == .error .unknownRevision &&
            fromZero == .error .noInverse &&
            backwards == .error .noInverse &&
            elsewhere == .error .notInState &&
            (← document.read) == "¡héllo!" &&
            (← (← document.snapshot).info).revision == 2 },
    { name := "a drop of kept inverses crosses, and its refusal"
      run := do
        let document ← Editor.Ffi.Document.new "héllo"
        discard <| document.apply { changes := #[.retain 6, .insert "!"] } 0
        discard <| document.apply { changes := #[.insert "¡", .retain 7] } 0
        let ahead ← document.dropInverses 1 3
        let kept ← document.applyInverse 2 2 0
        let dropped ← document.dropInverses 3 3
        let gone ← document.applyInverse 3 3 0
        let noWord ← document.dropInverses 0 largestWord
        return !ahead && kept == .ok { revision := 3, selection := none } && dropped &&
            gone == .error .noInverse &&
            !noWord &&
            (← document.read) == "héllo!" }]

/-- The words of a key the scripted platform could not identify, with no
modifier held. -/
def unidentifiedKey : Array UInt64 :=
  #[0, 0, 0, 0, 0]

/-- What the library's scripted platform reports of its window, as the kind,
the code, the text and the words of each event: that it opened, with the
platform's name; the focus gained; `a` pressed, the character `a` on the key
`KeyA` (75, 101, 121, 65) with shift and control (bits 1 and 2); `a`
released, unidentified; the dead key `´` (180) pressed; `é` pressed,
unidentified; then, when composition is allowed, a composition enabled, its
preedit and its commit; the secondary button (2) pressed at (12.5, 40) with
alt (bit 4); the window resized to 800 by 600 at scale 2; and a request to
close. A float is its bits. -/
def windowSample (composition : Bool) :
    List (Editor.Ffi.EventKind × UInt64 × String × Array UInt64) :=
  [(.windowOpened, 0, "scripted", #[]), (.windowFocus, 1, "", #[]),
      (.key, 1, "a", #[1, 1, 97, 1, 4, 75, 101, 121, 65, 3]), (.key, 0, "", unidentifiedKey),
      (.key, 5, "", #[3, 1, 180, 0, 0, 0]), (.key, 1, "é", unidentifiedKey)] ++
    (if composition then
      [(.composition, 0, "", #[]), (.composition, 1, "´", #[]), (.composition, 2, "é", #[])]
    else []) ++
    [(.pointer, 0, "", #[(12.5 : Float).toBits, (40.0 : Float).toBits, 2, 0, 4, 0, 0, 0]),
      (.resize, 0, "", #[800, 600, (2.0 : Float).toBits, 0]), (.closeRequested, 0, "", #[])]

/-- What one run of the scripted platform's window showed. -/
structure WindowRun where
  /-- The events pulled from the editor queue while the window ran, in order. -/
  events : List Editor.Ffi.Event
  /-- Whether every event had a stamp that was set, was not before the stamp
  of the event before it, and was not after the input clock's reading once
  the event was pulled. -/
  stamped : Bool
  /-- Whether `windowRun` was still running once every event had been pulled
  and before the window was closed. -/
  waited : Bool
  /-- What `windowRun` returned after the close; `none` if it did not return
  in time. -/
  result : Option (Except String Editor.Ffi.WindowRan)

/-- Runs the window of `platform`, a scripted one that opens, on a dedicated
task, pulls as many events from the editor queue as its sample has, closes
the window and waits for the run. It always closes the window, so a check
that fails leaves no run behind to hold the main-thread service. -/
def runScripted (composition : Bool) (platform : Editor.Ffi.Platform := .scripted) : IO WindowRun :=
  do
  let run ← IO.asTask (prio := .dedicated) (Editor.Ffi.windowRun platform composition)
  let mut events := #[]
  let mut stamped := true
  let mut last : UInt64 := 0
  for _ in [0:(windowSample composition).length] do
    let some event ← pull .editor | break
    let pulledAt ← Editor.Ffi.inputClock
    stamped := stamped && event.stamp > 0 && last <= event.stamp && event.stamp <= pulledAt
    last := event.stamp
    events := events.push event
  IO.sleep 20
  let waited := !(← IO.hasFinished run)
  Editor.Ffi.windowClose platform
  let result ←
    if ← eventually (IO.hasFinished run) then
      some <$> IO.ofExcept run.get
    else
      pure none
  return { events := events.toList, stamped, waited, result }

/-- What a run of the scripted window that was asked things showed: the next
event after the sample, and what the window says it was asked. -/
structure AskedRun where
  /-- The run, as `runScripted` gives it. -/
  ran : WindowRun
  /-- The first event pulled after the sample's and the requests. -/
  after : Option Editor.Ffi.Event
  /-- What the scripted window says it was asked in this run. -/
  asked : Option (Array Editor.Ffi.WindowAsked)

/-- Runs the scripted window as `runScripted` does, but once its sample has
been pulled runs `ask`, which asks the window things, pulls the `changes`
events the requests make the window report (one for each change of
fullscreen), and reads what the window was asked, before closing it. -/
def runScriptedWhile (ask : IO Unit) (changes : Nat := 1) : IO AskedRun := do
  let run ← IO.asTask (prio := .dedicated) (Editor.Ffi.windowRun .scripted true)
  let mut events := #[]
  for _ in [0:(windowSample true).length] do
    let some event ← pull .editor | break
    events := events.push event
  ask
  let after ← pull .editor
  for _ in [1:changes] do
    discard <| pull .editor
  let asked ← Editor.Ffi.windowAsked .scripted
  Editor.Ffi.windowClose .scripted
  let result ←
    if ← eventually (IO.hasFinished run) then
      some <$> IO.ofExcept run.get
    else
      pure none
  return { ran := { events := events.toList, stamped := true, waited := true, result }, after,
           asked }

/-- Runs the scripted window as `runScriptedWhile` does, asking it
`requests` in order through the library, which change fullscreen once. -/
def runScriptedAsking (requests : List Editor.Ffi.WindowRequest) : IO AskedRun :=
  runScriptedWhile do
    for request in requests do
      Editor.Ffi.windowRequest .scripted request

/-- The requests in `asked`, without the titles: a title is the presenter's,
sent when the window opens if a scene bound to it named one. -/
def requestsOf (asked : Array Editor.Ffi.WindowAsked) : Array Editor.Ffi.WindowRequest :=
  asked.filterMap fun
    | .request request => some request
    | .title _ => none

/-- Whether `events` are those of `windowSample composition`, in order, each
from the window source of the window number 1. -/
def isWindowSample (composition : Bool) (events : List Editor.Ffi.Event) : Bool :=
  events.all (·.source == { kind := .window, id := 1 }) &&
    events.map (fun event => (event.kind, event.code, event.text, event.words)) ==
      windowSample composition

/-- Runs the keyboard check (`Editor/WindowCheck.lean`) over the real
bindings, on `platform`, and returns the lines of its report and its exit
status; `none` if it did not end in time, in which case the window is closed
so that no run is left behind. The check blocks until the window has closed,
so it runs on a dedicated task. -/
def checkOn (platform : Editor.Ffi.Platform) (composition : Bool) :
    IO (Option (List String × UInt32)) := do
  let lines ← IO.mkRef #[]
  let window := Editor.WindowCheck.real platform fun line => lines.modify (·.push line)
  let task ← IO.asTask (prio := .dedicated) (Editor.WindowCheck.check window { composition })
  unless ← eventually (IO.hasFinished task) do
    Editor.Ffi.windowClose platform
    return none
  let status ← IO.ofExcept task.get
  return some ((← lines.get).toList, status)

/-- The lines of the keyboard check's report on the scripted platform; `none`
if the check did not end in time. -/
def checkScripted (composition : Bool) : IO (Option (List String)) :=
  return (← checkOn .scripted composition).map (·.1)

/-- Why the library's scripted platform that cannot open a window says it
cannot (`SCRIPTED_FAILURE` in `crates/editor-ffi/src/window.rs`). "é" is two
bytes, so a reason whose length the glue took in characters would arrive
cut. -/
def scriptedFailure : String :=
  "the scripted platform opens no window: pas d'écran"

/-- Why nothing can draw in the window of the library's scripted platform
whose renderer cannot be made (`SCRIPTED_NO_RENDERER` in
`crates/editor-ffi/src/window.rs`). -/
def scriptedNoRenderer : String :=
  "the scripted platform's window has no renderer: pas de GPU"

/-- What `windowRun` returns on `platform`; `none` if it does not return in
time, in which case the window is closed so that no run is left behind. -/
def runUntilReturn (platform : Editor.Ffi.Platform) :
    IO (Option (Except String Editor.Ffi.WindowRan)) := do
  let run ← IO.asTask (prio := .dedicated) (Editor.Ffi.windowRun platform true)
  unless ← eventually (IO.hasFinished run) do
    Editor.Ffi.windowClose platform
    return none
  return some (← IO.ofExcept run.get)

/-- Whether `result` is a run that returned and failed for exactly `reason`. -/
def failedFor (reason : String) : Option (Except String Editor.Ffi.WindowRan) → Bool
  | some (.error actual) => actual == reason
  | _ => false

/-- The checks of the window's bindings, on the library's scripted platforms:
nothing opens and no display is needed. A run blocks until the window is
closed, so each runs on a dedicated task, and the events are pulled on
dedicated tasks too. None of them quits the queues.

Three run the keyboard check's own loop over the bindings: what
`editor window-check` runs on the real window. One is on the scripted
platform whose renderer cannot be made: the glue's path for a window that
ran with nothing drawing in it, which the real platform takes on a machine
with no usable GPU. The last three are on the scripted platform that cannot
open a window: the glue's path for a failure, which the real platform takes
only on a machine with no display. -/
def windowChecks (_ : Unit) : List Check :=
  [{
      name :=
        "a window's inputs arrive on the editor queue in order, from the window source, with the kind, the code and the text of each, the first of them that the window opened, with the platform's name",
      run := return isWindowSample true (← runScripted true).events },
    { name := "run with composition not allowed, the same window reports no composition event"
      run := return isWindowSample false (← runScripted false).events },
    { name :=
        "each of a window's events is stamped on the input clock: with a stamp that is set, is not before the stamp of the event before it, and is not after the clock's reading once the event is pulled"
      run := do
        let ran ← runScripted true
        return ran.stamped && ran.events.length == (windowSample true).length },
    { name :=
        "running a window returns only after the window is closed, and says that it ran with something drawing in it"
      run := do
        let ran ← runScripted true
        return ran.waited && ran.result matches some (.ok { nothingDrew := none }) },
    { name :=
        "a window whose renderer cannot be made runs, reports its inputs and waits for its close all the same, and then says why nothing drew in it, whole"
      run := do
        let ran ← runScripted true .scriptedUndrawn
        let said :=
          match ran.result with
          | some (.ok { nothingDrew := some reason }) => reason == scriptedNoRenderer
          | _ => false
        return isWindowSample true ran.events && ran.waited && said },
    { name :=
        "an input posted as a window would report it arrives on the editor queue as the window's event, stamped, and words that do not read as an input are refused and queue nothing"
      run := do
        let words := #[1024, 768, (1.5 : Float).toBits, 16]
        let short ← Editor.Ffi.postInput .resize 0 "" #[1024, 768]
        let notWindow ← Editor.Ffi.postInput .message 0 "" #[]
        let posted ← Editor.Ffi.postInput .resize 0 "" words
        let some event ← pull .editor | return false
        return !short && !notWindow && posted && event.source == { kind := .window, id := 1 } &&
            event.kind == .resize &&
            event.code == 0 &&
            event.words == words &&
            event.stamp > 0 },
    { name :=
        "asked while the scripted window runs, a fullscreen request and a minimise request are what the window was asked, in that order, and entering fullscreen arrives on the editor queue as a resize in fullscreen at the size the window last said"
      run := do
        let ran ← runScriptedAsking [.enterFullscreen, .minimise]
        let resized :=
          match ran.after.map Editor.Event.ofFfi with
          | some (.ok { event := .resize size, .. }) =>
            size == { width := 800, height := 600, scale := 2.0, fullscreen := true }
          | _ => false
        return isWindowSample true ran.ran.events &&
            (ran.asked.map requestsOf) == some #[.enterFullscreen, .minimise] &&
            resized &&
            ran.ran.result matches some (.ok _) },
    { name :=
        "the light and the dark appearance asked while the scripted window runs are what the window was asked, in order among the other requests, and report nothing of their own"
      run := do
        let ran ← runScriptedAsking [.lightAppearance, .enterFullscreen, .darkAppearance]
        let resized :=
          match ran.after.map Editor.Event.ofFfi with
          | some (.ok { event := .resize size, .. }) => size.fullscreen
          | _ => false
        return isWindowSample true ran.ran.events &&
            (ran.asked.map requestsOf) ==
              some #[.lightAppearance, .enterFullscreen, .darkAppearance] &&
            resized &&
            ran.ran.result matches some (.ok _) },
    { name :=
        "a frame request asked of the real display binding made over the scripted platform, directly and through the window mode's host display, is what the scripted window was asked, in order"
      run := do
        let table ← Editor.Snapshots.new
        let display ← Editor.Ffi.Display.newCells 8 16
        let real ←
          Editor.RealDisplay.over display table.reader Editor.Theme.builtin (platform :=
              some .scripted)
        let hosted ← Editor.Window.hostDisplay display .scripted table.reader
        -- Entering and leaving fullscreen each change it: two resizes.
        let ran ←
          runScriptedWhile (changes := 2) do
              discard <| (Editor.Display.askFrame .enterFullscreen).runReal real
              hosted.handle (.frame .leaveFullscreen)
              hosted.handle (.frame .minimise)
        return (ran.asked.map requestsOf) ==
              some #[.enterFullscreen, .leaveFullscreen, .minimise] &&
            ran.ran.result matches some (.ok _) },
    { name :=
        "a request to a window that is not running is not recorded, and the real platform records nothing"
      run := do
        Editor.Ffi.windowRequest .scriptedFailing .enterFullscreen
        Editor.Ffi.windowRequest .scriptedFailing .minimise
        return (← Editor.Ffi.windowAsked .scriptedFailing) == some #[] &&
            (← Editor.Ffi.windowAsked .winit) == none },
    { name := "the input clock is never 0 and does not go back"
      run := do
        let first ← Editor.Ffi.inputClock
        return first > 0 && first <= (← Editor.Ffi.inputClock) },
    { name :=
        "the keyboard check over the bindings reports what the scripted window sent: that it opened, the focus, four key events of which three are presses and one is dead, the text they typed, a composition with one preedit and one commit, and that the window was closed"
      run := do
        let some lines ← checkScripted true | return false
        return lines.length == 8 &&
            lines[0]? ==
              some
                "window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: yes" &&
            lines[1]?.any (·.startsWith "window: opened by scripted ") &&
            lines[2]?.any (·.startsWith "focus: gained ") &&
            lines[3]? ==
              some
                "keys: 4 key events reached the Lean loop (3 presses, 0 of them repeats, 1 releases); text: \"aé\"" &&
            lines[4]?.any (·.endsWith "(4 samples)") &&
            lines[5]? == some "dead keys: 1 key events marked dead" &&
            lines[6]? ==
              some "composition: enabled; 1 preedit and 1 commit events; committed: \"é\"" &&
            lines[7]? == some "ended: the window was closed" },
    { name :=
        "run with composition not allowed, the keyboard check reports the same keys and no composition"
      run := do
        let some lines ← checkScripted false | return false
        return lines.length == 8 &&
            lines[0]? ==
              some
                "window-check: composition off, limit 120 s; the main-thread service is on the process's main thread: yes" &&
            lines[3]? ==
              some
                "keys: 4 key events reached the Lean loop (3 presses, 0 of them repeats, 1 releases); text: \"aé\"" &&
            lines[6]? ==
              some "composition: not enabled; 0 preedit and 0 commit events; committed: \"\"" &&
            lines[7]? == some "ended: the window was closed" },
    { name :=
        "running a window that cannot be opened returns the platform's reason, whole, and does so again on a second run"
      run := do
        let first ← runUntilReturn .scriptedFailing
        let second ← runUntilReturn .scriptedFailing
        return failedFor scriptedFailure first && failedFor scriptedFailure second },
    { name :=
        "a window that cannot be opened puts nothing on the editor queue, and closing it does nothing"
      run := do
        let ran ← runUntilReturn .scriptedFailing
        Editor.Ffi.windowClose .scriptedFailing
        -- The message is the first event of the queue: the run queued nothing.
        return failedFor scriptedFailure ran && (← roundTrips 11 1 "after the run that failed") },
    { name :=
        "the keyboard check over the bindings on a window that cannot be opened prints its eight lines, with the platform's reason in the second, and ends with status 1"
      run := do
        let some (lines, status) ← checkOn .scriptedFailing true | return false
        return lines.length == 8 &&
            lines[0]? ==
              some
                "window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: yes" &&
            lines[1]? == some s!"window: could not open: {scriptedFailure}" &&
            lines[7]? == some "ended: the window never opened" &&
            status == 1 },
    { name :=
        "the window mode's report says only the halves of a presentation the run asked for, and nothing when it asked for none"
      run :=
        pure
          (Editor.Window.askedText (none, none) == "nothing" &&
            Editor.Window.askedText (some .mailbox, none) == "mailbox" &&
            Editor.Window.askedText (none, some 2) == "a frame latency of 2" &&
            Editor.Window.askedText (some .immediate, some 3) ==
              "immediate at a frame latency of 3") }]

/-- An event from the window number 1, of this kind, code and text. -/
def fromWindow (kind : Editor.Ffi.EventKind) (code : UInt64) (text : String := "") :
    Editor.Ffi.Event :=
  { source := { kind := .window, id := 1 }, kind, code, text, stamp := 7 }

/-- The input the keyboard check takes an event from the window for. -/
def decoded (kind : Editor.Ffi.EventKind) (code : UInt64) (text : String := "") :
    Editor.WindowCheck.Input :=
  Editor.WindowCheck.decode (fromWindow kind code text)

/-- The checks of which event of the editor queue is which input to the
keyboard check (`Editor.WindowCheck.decode`): the Lean side of the table in
`crates/editor-ffi/src/window.rs`, row by row, on events built by hand. They
call no binding and need no window. -/
def decodeChecks (_ : Unit) : List Check :=
  [{ name := "an event that a window opened decodes to the platform's name, which is its text",
     run := pure (decoded .windowOpened 0 "winit" == .opened "winit") },
    { name := "a focus event decodes to the focus gained for code 1 and lost for code 0"
      run :=
        pure (decoded .windowFocus 1 == .focus true && decoded .windowFocus 0 == .focus false) },
    { name :=
        "a key event decodes to a key with its text: bit 0 of the code says it was pressed, bit 1 that it is a repeat and bit 2 that the key is dead, each by itself and together"
      run :=
        pure
          (decoded .key 0 == .key false false false "" &&
            decoded .key 1 "a" == .key true false false "a" &&
            decoded .key 2 == .key false true false "" &&
            decoded .key 3 "a" == .key true true false "a" &&
            decoded .key 4 == .key false false true "" &&
            decoded .key 5 == .key true false true "" &&
            decoded .key 7 "x" == .key true true true "x") },
    { name :=
        "a composition event decodes by its code: 0 to enabled, 1 to a preedit of its text, 2 to a commit of its text and 3 to disabled"
      run :=
        pure
          (decoded .composition 0 == .compositionEnabled &&
            decoded .composition 1 "´" == .preedit "´" &&
            decoded .composition 2 "é" == .commit "é" &&
            decoded .composition 3 == .compositionDisabled) },
    { name := "a pointer press and a request to close decode to themselves"
      run :=
        pure
          (decoded .pointer 0 == .pointerPressed && decoded .closeRequested 0 == .closeRequested) },
    { name :=
        "a pointer's drag, release and wheel, and a resize, decode to nothing: the keyboard check counts presses only"
      run :=
        pure
          (decoded .pointer 1 == .other && decoded .pointer 2 == .other &&
            decoded .pointer 3 == .other &&
            decoded .resize 0 == .other) },
    { name := "a quit of the queue decodes to the stop, whatever its source"
      run :=
        pure
          (Editor.WindowCheck.decode
                { source := { kind := .library, id := 0 }, kind := .quit, code := 0, text := ""
                  stamp := 0 } ==
              .stop &&
            decoded .quit 0 == .stop) },
    { name :=
        "a message from the check's stop source decodes to the stop, and one from another Lean source to nothing"
      run :=
        pure
          (Editor.WindowCheck.decode (message Editor.WindowCheck.stopSource 0 "") == .stop &&
            Editor.WindowCheck.decode (message (Editor.WindowCheck.stopSource + 1) 0 "") ==
              .other) },
    { name :=
        "an event of a window's kind from a source that is not a window decodes to nothing: a key from the script source, and a request to close from the library"
      run :=
        pure
          (Editor.WindowCheck.decode
                { fromWindow .key 1 "a" with source := { kind := .script, id := 1 } } ==
              .other &&
            Editor.WindowCheck.decode
                { fromWindow .closeRequested 0 with source := { kind := .library, id := 1 } } ==
              .other) },
    { name :=
        "an event from a window that the table has no row for decodes to nothing: a message, a completion, and a composition with a code past 3"
      run :=
        pure
          (decoded .message 1 "a" == .other && decoded .completion 1 == .other &&
            decoded .composition 4 "é" == .other) }]

/-- An event of `kind` from the window number 1, with this code, text and
words, built by hand. -/
def windowEvent (kind : Editor.Ffi.EventKind) (code : UInt64) (words : Array UInt64 := #[])
    (text : String := "") : Editor.Ffi.Event :=
  { source := { kind := .window, id := 1 }, kind, code, text, stamp := 7, words }

/-- What `Editor.Event.ofFfi` makes of an event built by hand: the event, or
`none` when it is refused. -/
def decodedEvent (event : Editor.Ffi.Event) : Option Editor.Received :=
  (Editor.Event.ofFfi event).toOption

/-- What `Editor.Event.ofFfi` makes of a window event built by hand, without
its stamp. -/
def decodedWindow (kind : Editor.Ffi.EventKind) (code : UInt64) (words : Array UInt64 := #[])
    (text : String := "") : Option Editor.Event :=
  (decodedEvent (windowEvent kind code words text)).map (·.event)

/-- The words of a pointer at (12.5, 40) with alt held, the button tag and its
number, and the wheel's delta tag and two floats. -/
def pointerWords (button other delta : UInt64) (dx dy : Float := 0) : Array UInt64 :=
  #[(12.5 : Float).toBits, (40.0 : Float).toBits, button, other, 4, delta,
    if delta == 0 then 0 else dx.toBits, if delta == 0 then 0 else dy.toBits]

/-- A pointer at (12.5, 40) with alt held. -/
def pointerAt (action : Editor.PointerAction) (button : Option Editor.Button) : Editor.Pointer :=
  { action, x := 12.5, y := 40.0, button, modifiers := { alt := true } }

/-- The checks of which event of the editor queue is which `Editor.Event`
(`Editor.Event.ofFfi`, `Editor/Event/Queue.lean`): each kind the queue
delivers decodes to its own variant, with its fields, and what cannot be read
is refused. They are on events built by hand: they call no binding and need
no window. -/
def eventDecodeChecks (_ : Unit) : List Check :=
  [{ name := "a message decodes with its source, its code and its text, whatever its words",
     run :=
       pure
         ((decodedEvent { message 5 6 "hi" with words := #[1, 2] }).map (·.event) ==
           some (.message { kind := .lean, id := 5 } 6 "hi")) },
    { name := "a completion decodes with its source and its id, and a quit to quit"
      run :=
        pure
          ((decodedEvent
                    { source := { kind := .library, id := 4 }, kind := .completion, code := 17,
                      text := "", stamp := 0 }).map
                (·.event) ==
              some (.completion { kind := .library, id := 4 } 17) &&
            (decodedEvent
                    { source := { kind := .library, id := 0 }, kind := .quit, code := 0, text := ""
                      stamp := 0 }).map
                (·.event) ==
              some .quit) },
    { name := "a window opened decodes with its platform, and a focus gained and lost"
      run :=
        pure
          (decodedWindow .windowOpened 0 (text := "winit") == some (.windowOpened "winit") &&
            decodedWindow .windowFocus 1 == some (.focus true) &&
            decodedWindow .windowFocus 0 == some (.focus false)) },
    { name :=
        "a key decodes with its logical key, its physical key, its modifiers, whether it is a repeat, whether it was pressed, and its text"
      run :=
        pure
          (decodedWindow .key 1 #[1, 1, 97, 1, 4, 75, 101, 121, 65, 3] "a" ==
              some
                (.key
                  { logical := .character "a", physical := .code "KeyA"
                    modifiers := { shift := true, control := true } } true "a") &&
            decodedWindow .key 2 #[2, 6, 69, 115, 99, 97, 112, 101, 0, 0, 15] ==
              some
                (.key
                  { logical := .named .escape
                    modifiers := { shift := true, control := true, alt := true, superKey := true }
                    repeated := true } false "") &&
            decodedWindow .key 5 #[3, 1, 180, 0, 0, 0] ==
              some (.key { logical := .dead (some '´') } true "") &&
            decodedWindow .key 4 #[3, 0, 0, 0, 0] ==
              some (.key { logical := .dead none } false "") &&
            decodedWindow .key 0 #[0, 0, 0, 0, 0] ==
              some (.key { logical := .unidentified } false "")) },
    { name :=
        "a composition decodes by its code: 0 to enabled, 1 to a preedit of its text, 2 to a commit of its text and 3 to disabled"
      run :=
        pure
          (decodedWindow .composition 0 == some .compositionEnabled &&
            decodedWindow .composition 1 (text := "´") == some (.preedit "´") &&
            decodedWindow .composition 2 (text := "é") == some (.commit "é") &&
            decodedWindow .composition 3 == some .compositionDisabled) },
    { name :=
        "a pointer decodes with its action, its position, its button and its modifiers: each action, each button, and each wheel delta"
      run :=
        pure
          (decodedWindow .pointer 0 (pointerWords 1 0 0) ==
              some (.pointer (pointerAt .press (some .primary))) &&
            decodedWindow .pointer 1 (pointerWords 2 0 0) ==
              some (.pointer (pointerAt .drag (some .secondary))) &&
            decodedWindow .pointer 2 (pointerWords 3 0 0) ==
              some (.pointer (pointerAt .release (some .middle))) &&
            decodedWindow .pointer 0 (pointerWords 4 0 0) ==
              some (.pointer (pointerAt .press (some .back))) &&
            decodedWindow .pointer 0 (pointerWords 5 0 0) ==
              some (.pointer (pointerAt .press (some .forward))) &&
            decodedWindow .pointer 0 (pointerWords 6 9 0) ==
              some (.pointer (pointerAt .press (some (.other 9)))) &&
            decodedWindow .pointer 3 (pointerWords 0 0 1 0 (-1.5)) ==
              some (.pointer (pointerAt (.wheel (.lines 0 (-1.5))) none)) &&
            decodedWindow .pointer 3 (pointerWords 0 0 2 7 0.5) ==
              some (.pointer (pointerAt (.wheel (.pixels 7 0.5)) none))) },
    { name :=
        "a resize decodes with its size, its scale, whether it is in fullscreen and its corner clearance, and a request to close to itself"
      run :=
        pure
          (decodedWindow .resize 0 #[800, 600, (2.0 : Float).toBits, 0] ==
              some (.resize { width := 800, height := 600, scale := 2.0 }) &&
            decodedWindow .resize 0 #[800, 600, (2.0 : Float).toBits, 16] ==
              some (.resize { width := 800, height := 600, scale := 2.0, corner := 16 }) &&
            decodedWindow .resize 1 #[1440, 900, (2.0 : Float).toBits, 0] ==
              some (.resize { width := 1440, height := 900, scale := 2.0, fullscreen := true }) &&
            decodedWindow .closeRequested 0 == some .closeRequested) },
    { name :=
        "files to open decode with their paths in order, each its count of characters and its characters, and no path to none"
      run :=
        pure
          (decodedWindow .openFiles 0 #[2, 1, 97, 2, 98, 99] == some (.openFiles ["a", "bc"]) &&
            decodedWindow .openFiles 0 #[0] == some (.openFiles [])) },
    { name :=
        "files to open are refused with a code, with text, with too few words, with words left over, and with a scalar that is not a character"
      run :=
        pure
          ((decodedWindow .openFiles 1 #[1, 1, 97]).isNone &&
            (decodedWindow .openFiles 0 #[1, 1, 97] "x").isNone &&
            (decodedWindow .openFiles 0 #[2, 1, 97]).isNone &&
            (decodedWindow .openFiles 0 #[]).isNone &&
            (decodedWindow .openFiles 0 #[1, 1, 97, 5]).isNone &&
            (decodedWindow .openFiles 0 #[1, 1, 0xD800]).isNone) },
    { name := "the stamp of an event is kept beside it"
      run := pure ((decodedEvent (windowEvent .closeRequested 0)).map (·.stamp) == some 7) },
    { name :=
        "a key whose code carries the interrupt mark decodes as the key it is, marked as an interrupt key, and one without the mark is not marked"
      run :=
        pure
          (decodedEvent (windowEvent .key 9 #[1, 1, 103, 0, 0, 2]) ==
              some
                { event :=
                    .key { logical := .character "g", modifiers := { control := true } } true ""
                  stamp := 7, interrupt := true } &&
            decodedEvent (windowEvent .key 11 #[0, 0, 0, 0, 0]) ==
              some
                { event := .key { logical := .unidentified, repeated := true } true "", stamp := 7
                  interrupt := true } &&
            (decodedEvent (windowEvent .key 1 #[1, 1, 103, 0, 0, 2])).map (·.interrupt) ==
              some false &&
            (decodedEvent (windowEvent .closeRequested 0)).map (·.interrupt) == some false) },
    { name :=
        "whether an event carries the interrupt mark is read from its kind and its code alone: a key with bit 3 of its code carries it whether or not the key can be read, a key without the bit does not, and no other kind does with the bit"
      run :=
        pure
          (Editor.Event.interruptMarked (windowEvent .key 9 #[1, 1, 103, 0, 0, 2]) &&
            Editor.Event.interruptMarked (windowEvent .key 9 #[1, 1, 103, 0, 0, 2, 0]) &&
            Editor.Event.interruptMarked (windowEvent .key 8 #[0, 0, 0, 0, 0]) &&
            !Editor.Event.interruptMarked (windowEvent .key 1 #[1, 1, 103, 0, 0, 2]) &&
            !Editor.Event.interruptMarked (windowEvent .composition 8) &&
            !Editor.Event.interruptMarked (message 5 8 "")) },
    { name :=
        "a code the table does not have is refused: a focus of 2, a composition of 4, a key with a bit past the interrupt mark, a key with the mark that was not pressed, a pointer of 4, a resize of 2"
      run :=
        pure
          ((decodedWindow .windowFocus 2).isNone && (decodedWindow .composition 4).isNone &&
            (decodedWindow .key 16 #[0, 0, 0, 0, 0]).isNone &&
            (decodedWindow .key 17 #[0, 0, 0, 0, 0]).isNone &&
            (decodedWindow .key 8 #[0, 0, 0, 0, 0]).isNone &&
            (decodedWindow .pointer 4 (pointerWords 1 0 0)).isNone &&
            (decodedWindow .resize 2 #[1, 1, 0, 0]).isNone) },
    { name :=
        "malformed words are refused: too few, left over, an unknown tag, a scalar that is not a character, modifier bits past super, a dead bit with no dead key, a named button with a number, a pointer that is not a wheel with a delta"
      run :=
        pure
          ((decodedWindow .key 1 #[1, 1]).isNone &&
            (decodedWindow .key 1 #[0, 0, 0, 0, 0, 0]).isNone &&
            (decodedWindow .key 1 #[4, 0, 0, 0, 0]).isNone &&
            (decodedWindow .key 1 #[0, 0, 2, 0, 0]).isNone &&
            (decodedWindow .key 1 #[1, 1, 0xD800, 0, 0, 0]).isNone &&
            (decodedWindow .key 1 #[1, 1, 0x110000, 0, 0, 0]).isNone &&
            (decodedWindow .key 1 #[0, 0, 0, 0, 16]).isNone &&
            (decodedWindow .key 5 #[0, 0, 0, 0, 0]).isNone &&
            (decodedWindow .pointer 0 (pointerWords 7 0 0)).isNone &&
            (decodedWindow .pointer 3 (pointerWords 0 0 0)).isNone &&
            (decodedWindow .pointer 0 (pointerWords 1 9 0)).isNone &&
            (decodedWindow .pointer 0
                #[(12.5 : Float).toBits, (40.0 : Float).toBits, 1, 0, 4, 0, 0,
                  (1.0 : Float).toBits]).isNone &&
            (decodedWindow .pointer 0
                #[(12.5 : Float).toBits, (40.0 : Float).toBits, 1, 0, 16, 0, 0, 0]).isNone &&
            (decodedWindow .resize 0 #[800, 600]).isNone &&
            (decodedWindow .resize 0 #[800, 600, (2.0 : Float).toBits]).isNone &&
            (decodedWindow .closeRequested 0 #[1]).isNone) }]

/-- The events of a run of the scripted platform's window, decoded. -/
def scriptedEvents : IO (List Editor.Event) := do
  let ran ← runScripted true
  ran.events.mapM fun event => (·.event) <$> IO.ofExcept (Editor.Event.ofFfi event)

/-- Posts `event` as a window would report it, pulls it back from the editor
queue and decodes it. -/
def roundTrip (event : Editor.Event) : IO (Option Editor.Event) := do
  unless ← Editor.Event.post event do
    return none
  let some pulled ← pull .editor | return none
  return (Editor.Event.ofFfi pulled).toOption.map (·.event)

/-- The checks of `Editor.Event` against the real library: what Rust posts
arrives in Lean with the same values. -/
def eventChecks (_ : Unit) : List Check :=
  [{  name :=
        "the scripted window's key arrives as a key with its logical key a, its physical key KeyA, and shift and control"
      run := do
        let events ← scriptedEvents
        return events.contains
            (.key
              { logical := .character "a", physical := .code "KeyA"
                modifiers := { shift := true, control := true } } true "a") },
    { name :=
        "the scripted window's pointer arrives as a press of the secondary button at (12.5, 40) with alt, and its resize as 800 by 600 at scale 2"
      run := do
        let events ← scriptedEvents
        return events.contains (.pointer (pointerAt .press (some .secondary))) &&
            events.contains (.resize { width := 800, height := 600, scale := 2.0 }) },
    { name := "every event of the scripted window decodes, each to its own variant, in order"
      run := do
        let events ← scriptedEvents
        return events.length == (windowSample true).length &&
            events.head? == some (.windowOpened "scripted") &&
            events.getLast? == some .closeRequested },
    { name :=
        "a window opened, a focus gained and lost, a key, each composition, each pointer action, a resize out of fullscreen and one in it, files to open, none to open, and a request to close posted as a window would come back from the library equal"
      run := do
        let events : List Editor.Event :=
          [.windowOpened "x", .focus true, .focus false,
            .key
              { logical := .named .escape, physical := .code "Escape"
                modifiers := { superKey := true } } true "",
            .key { logical := .character "é", repeated := true } true "é", .compositionEnabled,
            .preedit "´", .commit "é", .compositionDisabled,
            .pointer (pointerAt .press (some .primary)), .pointer (pointerAt .drag (some .middle)),
            .pointer (pointerAt .release (some (.other 12))),
            .pointer (pointerAt (.wheel (.lines 1 (-2))) none),
            .pointer (pointerAt (.wheel (.pixels 0.25 8)) none),
            .resize { width := 1920, height := 1080, scale := 1.25 },
            .resize { width := 1920, height := 1080, scale := 1.25, fullscreen := true },
            .openFiles ["/Users/me/notes.txt", "/tmp/é x.lean"], .openFiles [], .closeRequested]
        events.allM fun event => return (← roundTrip event) == some event },
    { name := "an event no window reports is not posted: a message, a completion and a quit"
      run := do
        let posted ←
          [Editor.Event.message { kind := .lean, id := 1 } 0 "",
                  .completion { kind := .library, id := 1 } 0, .quit].mapM
              Editor.Event.post
        return posted.all (!·) }]

/-- The key of the character `text` with control held, and shift too when
`shift`. -/
def controlKey (text : String) (shift : Bool := false) : Editor.Key :=
  { logical := .character text, modifiers := { control := true, shift } }

/-- The named key `Tab` with control held, and shift too when `shift`. -/
def controlTab (shift : Bool := false) : Editor.Key :=
  { logical := .named .tab, modifiers := { control := true, shift } }

/-- Posts `key`, pressed or released, as a window would report it, and pulls
it back from the editor queue: whether the interrupt flag was up once the
key had arrived, before anything pulled it, and whether the event pulled is
marked as an interrupt key. The flag is lowered for a marked event, as the
loop lowers it, so the queue is empty and the flag down afterwards. `none`
when the key was not queued, did not come back or did not decode. -/
def arrives (key : Editor.Key) (pressed : Bool := true) : IO (Option (Bool × Bool)) := do
  unless ← Editor.Event.post (.key key pressed "") do
    return none
  let raised ← Editor.Ffi.interruptRaised
  let some pulled ← pull .editor | return none
  let .ok received := Editor.Event.ofFfi pulled | return none
  if received.interrupt then
    Editor.Ffi.interruptLower
  return some (raised, received.interrupt)

/-- Runs `body` with `key` as the library's interrupt key, and leaves the
library with none. `false` when the library did not take the key, when
`body` does not hold, or when the flag is still up after it. -/
def withInterruptKey (key : Editor.Key) (body : IO Bool) : IO Bool := do
  unless ← Editor.Event.setInterruptKey (some key) do
    return false
  try
    let held ← body
    return held && !(← Editor.Ffi.interruptRaised)
  finally
    discard <| Editor.Event.setInterruptKey none

/-- The checks of the interrupt flag against the real library
(`crates/editor-ffi/src/interrupt.rs`): Lean tells the library its interrupt
key, a press of that key raises the flag as it arrives and its event is
marked, and Lean lowers the flag. Each leaves the queue empty, the flag down
and no interrupt key. -/
def interruptChecks (_ : Unit) : List Check :=
  [{  name :=
        "once Lean has told the library its interrupt key, a press of it raises the flag as it arrives, the event pulled is marked, and lowering brings the flag down"
      run :=
        withInterruptKey (controlKey "g") do
          let before ← Editor.Ffi.interruptRaised
          return !before && (← arrives (controlKey "g")) == some (true, true) },
    { name :=
        "a chord drops shift on a character, so the interrupt key's character with shift held raises the flag too"
      run :=
        withInterruptKey (controlKey "g") do
          return (← arrives (controlKey "g" true)) == some (true, true) },
    { name :=
        "another character with the interrupt key's modifiers, its character with none or with one more, a release of it and another key raise nothing and are not marked"
      run :=
        withInterruptKey (controlKey "g") do
          let others : List (Editor.Key × Bool) :=
            [(controlKey "G", true), ({ logical := .character "g" }, true),
              ({ controlKey "g" with modifiers := { control := true, alt := true } }, true),
              (controlKey "g", false), (controlKey "x", true), (controlTab, true)]
          others.allM fun (key, pressed) => return (← arrives key pressed) == some (false, false) },
    { name :=
        "a chord keeps shift on a named key, so with a named key as the interrupt key the key with shift held is another key"
      run :=
        withInterruptKey controlTab do
          return (← arrives controlTab) == some (true, true) &&
              (← arrives (controlTab true)) == some (false, false) },
    { name :=
        "two presses of the interrupt key need two lowers: the flag is still up after the first"
      run :=
        withInterruptKey (controlKey "g") do
          let posted ←
            [controlKey "g", controlKey "g"].allM fun key => Editor.Event.post (.key key true "")
          let pulled ← [(), ()].mapM fun _ => pull .editor
          let marked :=
            pulled.all fun event =>
              (event.bind fun event => (Editor.Event.ofFfi event).toOption).map (·.interrupt) ==
                some true
          Editor.Ffi.interruptLower
          let between ← Editor.Ffi.interruptRaised
          Editor.Ffi.interruptLower
          return posted && marked && between && !(← Editor.Ffi.interruptRaised) },
    { name :=
        "with no interrupt key told, the key raises nothing and arrives unmarked, and a lower with nothing raised is nothing"
      run := do
        Editor.Ffi.interruptLower
        return (← Editor.Event.setInterruptKey none) &&
            (← arrives (controlKey "g")) == some (false, false) &&
            !(← Editor.Ffi.interruptRaised) },
    { name :=
        "the words of an interrupt key are its logical key, its modifiers as a chord has them, and the modifiers a chord compares: every one but shift for a character, and every one for a named key"
      run :=
        pure
          (Editor.EventWords.interruptWords (controlKey "g" true) == #[1, 1, 103, 2, 14] &&
            Editor.EventWords.interruptWords (controlTab true) == #[2, 3, 84, 97, 98, 3, 15] &&
            Editor.EventWords.interruptWords { logical := .character "é" } ==
              #[1, 1, 233, 0, 14]) },
    { name := "words that are not an interrupt key are refused by the library, and set none"
      run := do
        let refused ← Editor.Ffi.interruptKeySet #[1, 1, 103, 2]
        let unmasked ← Editor.Ffi.interruptKeySet #[1, 1, 103, 3, 14]
        return !refused && !unmasked && (← arrives (controlKey "g")) == some (false, false) }]

/-- Makes a display, asks it one question and drops it: what is left of it
must be freed. Its rows of "abc" at one pixel a cell, two wide, from 0. -/
def useDisplay : IO (Option (Array Editor.Ffi.DisplayRow)) := do
  let display ← Editor.Ffi.Display.newCells 1 1
  let snapshot ← (← Editor.Ffi.Document.new "abc").snapshot
  display.rows snapshot 2 10 0

/-- The checks of the display handle (`Editor.Ffi.Display`): it is freed with
its last reference, and its answers cross. What it answers is layout's rule,
pinned by `editor-layout`'s tests, and the queries' rules are held to the
display contract by `contract-test`. -/
def displayChecks (_ : Unit) : List Check :=
  [{  name :=
        "a display is freed when Lean drops the last reference, and its rows cross as start and stop"
      run := do
        let before ← Editor.Ffi.Display.live
        let rows ← useDisplay
        return rows == some #[{ start := 0, stop := 2 }, { start := 2, stop := 3 }] &&
            (← Editor.Ffi.Display.live) == before },
    { name :=
        "a display's move crosses as a position and a goal, and a position inside a character is refused"
      run := do
        let display ← Editor.Ffi.Display.newCells 1 1
        let snapshot ← (← Editor.Ffi.Document.new "abcdé\nx").snapshot
        -- From b (x 1) one row down at width 3: "dé" is the next row, so é.
        let down ← display.move snapshot 3 1 1 none
        -- Two rows up from x, aiming for x 1: "dé", then "abc", so b.
        let up ← display.move snapshot 3 7 (-2) (some 1)
        let inside ← display.move snapshot 3 5 1 none
        return down == some { position := 4, goal := 1 } &&
            up == some { position := 1, goal := 1 } &&
            inside.isNone }]

/-- Marks `document` with `marker`, and returns its number. -/
def markIn (document : Editor.Ffi.Document) (marker : Editor.Ffi.Marker) : IO Nat := do
  match ← document.mark marker with
  | .ok number =>
    return number.toNat
  | .error refusal =>
    throw (IO.userError s!"the fixture's marker was refused: {repr refusal}")

/-- A selection marker of the one range from `anchor` to `head`. -/
def rangeMarker (anchor head : UInt64) : Editor.Ffi.Marker :=
  .selection { ranges := #[{ anchor, head }] }

/-- The theme of the display fixture, which
`crates/editor-layout/tests/frame_fixture.rs` states the same way (its
`theme`): `default`, `keyword` with a weight, `emphasis` with a slant,
`number` with an underline, `selection`, `mode-line`, `position` and
`cursor.normal`, and not `cursor.insert`, which view 2's cursors name. -/
def fixtureTheme : Editor.Theme :=
  #[{ name := ⟨"default"⟩
      face :=
        { foreground := some (.rgb 0x20 0x20 0x20), background := some (.rgb 0xf8 0xf8 0xf8) } },
    { name := ⟨"keyword"⟩, face := { foreground := some (.rgb 0 0 0xc0), weight := some 700 } },
    { name := ⟨"emphasis"⟩
      face := { foreground := some (.rgb 0 0x80 0), slant := some .italic } },
    { name := ⟨"number"⟩
      face := { foreground := some (.rgb 0xc0 0 0), underline := some { style := .single } } },
    { name := ⟨"selection"⟩, face := { background := some (.rgb 0xc0 0xd8 0xff) } },
    { name := ⟨"mode-line"⟩
      face :=
        { foreground := some (.rgb 0xff 0xff 0xff), background := some (.rgb 0x40 0x40 0x40) } },
    { name := ⟨"position"⟩, face := { foreground := some (.rgb 0xff 0xff 0) } },
    { name := ⟨"cursor.normal"⟩
      face :=
        { foreground := some (.rgb 0xf8 0xf8 0xf8), background := some (.rgb 0x20 0x20 0x20) } }]

/-- The display fixture: the scene `crates/editor-layout/tests/frame_fixture.rs`
lays out, built here through the library's documents and markers and the
text binding's table of snapshots, and the binding over a display in cells
8 pixels across and 16 down, with `fixtureTheme` to send. Text A is the
text of view 1, text B of view 2, and their snapshots are 0 and 1. The
documents come back too: a snapshot holds its document weakly, and the
library reads the markers in the document, so whoever publishes keeps it
alive, as the text binding does. -/
def displayFixture : IO (Editor.RealDisplay × Editor.Scene × Array Editor.Ffi.Document) := do
  let a ← Editor.Ffi.Document.new "fn main() {\n\tlet x = 1;\n}\nabcdefghijklmnopqrstuvwxyz\n"
  let b ← Editor.Ffi.Document.new "hello\nworld wide web"
  let marker (text : Nat) (index : Nat) : Editor.MarkerId := { text := ⟨text⟩, index }
  let scrollA ← markIn a (.anchor { offset := 0, bias := .before })
  let selectedA ← markIn a (rangeMarker 3 7)
  let cursorA ← markIn a (rangeMarker 18 18)
  let scrollB ← markIn b (.anchor { offset := 6, bias := .before })
  let cursorB ← markIn b (rangeMarker 12 12)
  let table ← Editor.Snapshots.new
  let snapshotA ← table.add (← a.snapshot)
  let snapshotB ← table.add (← b.snapshot)
  let display ← Editor.Ffi.Display.newCells 8 16
  let scene : Editor.Scene :=
    { size := { width := 96, height := 112 }
      views :=
        #[{ id := ⟨1⟩, rect := { x := 0, y := 0, width := 96, height := 80 }, snapshot := snapshotA
            scroll := marker 0 scrollA, selections := #[marker 0 selectedA, marker 0 cursorA]
            cursor := { shape := .block, face := ⟨"cursor.normal"⟩ }
            decorations :=
              #[{ start := 0, stop := 2, face := ⟨"keyword"⟩ },
                { start := 17, stop := 18, face := ⟨"number"⟩ },
                { start := 1, stop := 5, face := ⟨"emphasis"⟩ }]
            status :=
              #[{ text := "fixture.rs", face := ⟨"mode-line"⟩ },
                { text := " 1:8", face := ⟨"position"⟩ }] },
          { id := ⟨2⟩, rect := { x := 0, y := 80, width := 64, height := 32 }, snapshot := snapshotB
            scroll := marker 1 scrollB, selections := #[marker 1 cursorB]
            cursor := { shape := .bar, face := ⟨"cursor.insert"⟩ }, decorations := #[]
            status := #[] }]
      focused := some ⟨1⟩, echo := "fixture", pending := "", preedit := none }
  return (← Editor.RealDisplay.over display table.reader fixtureTheme, scene, #[a, b])

/-- What `sceneChecks` publish from: one text, "ab\ncd\nef", its markers, and
the binding over a table that holds its snapshot alone, with a theme to
send. -/
structure SceneFixture where
  /-- The binding, over a display in cells 8 pixels across and 16 down. -/
  real : Editor.RealDisplay
  /-- The text's snapshot, the only one in the binding's table. -/
  snapshot : Editor.SnapshotId
  /-- The number of the text's anchor marker at offset 3, where its second
  row starts. -/
  anchor : Nat
  /-- The number of its selection marker of the range 4..5. -/
  selection : Nat
  /-- The number of its anchor marker at offset 0. -/
  top : Nat
  /-- The text's document. The library reads the markers in it, and a
  snapshot holds it weakly, so whoever publishes keeps it alive. -/
  document : Editor.Ffi.Document

/-- Makes a `SceneFixture` whose binding has `theme` to send: no definition,
unless a check gives one. -/
def sceneFixture (theme : Editor.Theme := #[]) : IO SceneFixture := do
  let document ← Editor.Ffi.Document.new "ab\ncd\nef"
  let anchor ← markIn document (.anchor { offset := 3, bias := .before })
  let selection ← markIn document (rangeMarker 4 5)
  let top ← markIn document (.anchor { offset := 0, bias := .before })
  let table ← Editor.Snapshots.new
  let snapshot ← table.add (← document.snapshot)
  let display ← Editor.Ffi.Display.newCells 8 16
  return {
      real := ← Editor.RealDisplay.over display table.reader theme, snapshot, anchor, selection, top
      document }

/-- The marker numbered `index` of the fixture's text, which is text 0. -/
def SceneFixture.own (index : Nat) : Editor.MarkerId :=
  { text := ⟨0⟩, index }

/-- A scene that takes the branches of the binding's encoding the display
fixture does not: a pending prefix and a preedit, and an echo padding; view
1, of a snapshot the table does not hold and padded, before view 2, of the one it holds, scrolled to its
second row with a selection, a right status field with a padding and a
status face; and view 3, of the same snapshot, whose scroll
marker is `scroll` and whose selection markers are `selections`. Each view
is 4 columns by 3 rows. -/
def SceneFixture.scene (fixture : SceneFixture) (scroll : Editor.MarkerId)
    (selections : Array Editor.MarkerId) : Editor.Scene :=
  let rect (y : Nat) : Editor.Rect := { x := 0, y, width := 32, height := 48 }
  { size := { width := 32, height := 144 }
    views :=
      #[{ id := ⟨1⟩, rect := rect 0, snapshot := ⟨fixture.snapshot.index + 1⟩
          scroll := SceneFixture.own fixture.anchor, selections := #[]
          cursor := { shape := .block, face := ⟨"c1"⟩ }, decorations := #[], status := #[]
          padding := { across := 8, down := 4 } },
        { id := ⟨2⟩, rect := rect 48, snapshot := fixture.snapshot
          scroll := SceneFixture.own fixture.anchor
          selections := #[SceneFixture.own fixture.selection]
          cursor := { shape := .bar, face := ⟨"c2"⟩ }
          decorations := #[{ start := 0, stop := 2, face := ⟨"kw"⟩ }]
          status :=
            #[{ text := "NORMAL", face := ⟨"mode"⟩ },
              { text := "1:1", face := ⟨"pos"⟩, side := .right, padding := 4 }]
          statusFace := some ⟨"dim"⟩ },
        { id := ⟨3⟩, rect := rect 96, snapshot := fixture.snapshot, scroll, selections
          cursor := { shape := .underline, face := ⟨"c3"⟩ }, decorations := #[], status := #[] }]
    focused := some ⟨2⟩, echo := "fixture", echoPadding := 14, pending := "g"
    preedit := some "é", title := "notes.txt" }

/-- The fixture's scene with view 3's markers of two texts: its scroll
marker is the text's anchor at offset 3, and its selection marker is a
marker of text 1 with the number of the text's own selection marker, which
is what the library would read if the number were sent. -/
def SceneFixture.mixed (fixture : SceneFixture) : Editor.Scene :=
  fixture.scene (SceneFixture.own fixture.anchor) #[{ text := ⟨1⟩, index := fixture.selection }]

/-- The rows of the fixture's text the rows query answers for one of its
views, from `anchor`, as pairs; `none` when it is refused. -/
def SceneFixture.asked (fixture : SceneFixture) (anchor : Nat) : IO (Option (Array (Nat × Nat))) :=
  do
  let answer ← fixture.real.rows { snapshot := fixture.snapshot, width := 32, height := 48, anchor }
  return answer.toOption.map (·.map fun row => (row.start, row.stop))

/-- The rows the view numbered `view` shows in the frame the fixture's
display holds, as pairs; `none` when the frame has no such view. -/
def SceneFixture.shown (fixture : SceneFixture) (view : UInt64) : IO (Option (Array (Nat × Nat))) :=
  do
  return (← fixture.real.display.frameRows view).map
      (·.map fun row => (row.start.toNat, row.stop.toNat))

/-- A theme whose definitions use every constructor of `Slant`, of
`UnderlineStyle` and of `LineHeight`, every attribute of a face, a name of
more than one byte to a character, and a weight on each side of the range
the library takes. -/
def everyTheme : Editor.Theme :=
  #[{ name := ⟨"all"⟩
      face :=
        { family := some "mono", size := some 20, weight := some 700, slant := some .italic
          foreground := some (.rgba 0x11 0x22 0x33 0x44), background := some (.rgb 0xaa 0xbb 0xcc)
          underline := some { style := .curly, color := some (.rgb 0xff 0 0) }
          strikeThrough := some true, lineHeight := some (.pixels 24)
          verticalPadding := some 3 } },
    { name := ⟨"unset"⟩, face := {} },
    { name := ⟨"é"⟩
      face :=
        { slant := some .upright, underline := some { style := .none }, strikeThrough := some false
          lineHeight := some (.multiple 96) } },
    { name := ⟨"b"⟩, face := { slant := some .oblique, underline := some { style := .single } } },
    { name := ⟨"c"⟩, face := { weight := some 5000, underline := some { style := .double } } },
    { name := ⟨"d"⟩, face := { weight := some 0, underline := some { style := .dotted } } },
    { name := ⟨"e"⟩, face := { underline := some { style := .dashed } } }]

/-- A scene of no view, 8 pixels by 16. -/
def emptyScene : Editor.Scene :=
  { size := { width := 8, height := 16 }, views := #[], focused := none, echo := "", pending := ""
    preedit := none }

/-- The checks of the real binding's encoding of a scene
(`Editor.RealDisplay.encode`) that the display fixture does not make: a
pending prefix and a preedit, a view whose snapshot the table does not
hold, and a view whose markers are of two texts; and of a theme: its
definitions as words, when it is sent and when it is not, and the names
layout reads by itself. The words are compared with the library's layout
written out here once (`crates/editor-ffi/src/display/wire.rs`), since the
library writes back what it was sent whatever it was. What a frame holds
is layout's rule: a view's rows are compared with the rows query's answer,
and a frame with another frame, never with a colour or a size written
here. -/
def sceneChecks (_ : Unit) : List Check :=
  [{  name :=
        "a scene with a pending prefix, a preedit, a title, a view of a snapshot the table does not hold and a view whose markers are of two texts is the words and the string of the library's layout"
      run := do
        let fixture ← sceneFixture
        let encoded ← fixture.real.encode fixture.mixed none
        let anchor := fixture.anchor.toUInt64
        let selection := fixture.selection.toUInt64
        -- The echo's padding after its length, and the title's length after
        -- the preedit's presence and length.
        let scene : Array UInt64 := #[32, 144, 1, 2, 7, 14, 1, 1, 2, 9, 3]
        -- No snapshot; its scroll marker; no selection; a block cursor; no
        -- status field and no status face; padded 8 across and 4 down.
        let first : Array UInt64 := #[1, 0, 0, 32, 48, 0, 0, 1, anchor, 0, 0, 2, 0, 0, 0, 0, 8, 4]
        -- The first handle; its scroll marker and its selection; a bar
        -- cursor; a decoration; a left status field with no padding and a
        -- right one padded 4; and a status face.
        let second : Array UInt64 :=
          #[2, 0, 48, 32, 48, 1, 0, 1, anchor, 1, selection, 1, 2, 1, 0, 2, 2, 2, 6, 4, 0, 0, 3, 3,
            1, 4, 1, 3, 0, 0]
        -- The second handle; no scroll marker and no selection; an
        -- underline cursor.
        let third : Array UInt64 := #[3, 0, 96, 32, 48, 1, 1, 0, 0, 0, 2, 2, 0, 0, 0, 0, 0, 0]
        -- No faces: as last published.
        let faces : Array UInt64 := #[0]
        return encoded.words == scene ++ first ++ second ++ third ++ faces &&
            encoded.strings == "fixturegénotes.txtc1c2kwNORMALmode1:1posdimc3" &&
            encoded.snapshots.size == 2 },
    { name :=
        "published, that scene comes back as sent; the view of the unknown snapshot shows nothing, the view after it shows its text from its anchor, and the view whose markers are of two texts shows its text from the start with no selection"
      run := do
        let fixture ← sceneFixture
        let real := fixture.real
        real.publish fixture.mixed
        -- The first publish sends the binding's theme, which has no
        -- definition.
        let encoded ← real.encode fixture.mixed (some #[])
        let back ← real.display.scene
        let mixed ← real.display.frameText
        let unknown ← fixture.shown 1
        let second ← fixture.shown 2
        let third ← fixture.shown 3
        let fromAnchor ← fixture.asked 3
        let fromStart ← fixture.asked 0
        -- View 3 scrolled to the start, with no selection: the same frame.
        real.publish (fixture.scene (SceneFixture.own fixture.top) #[])
        let plain ← real.display.frameText
        -- View 3 with the scroll marker and the selection marker the
        -- library would read if the numbers were sent: another frame.
        real.publish
            (fixture.scene (SceneFixture.own fixture.anchor) #[SceneFixture.own fixture.selection])
        let whole ← real.display.frameText
        -- The document is held until here, past the last publish.
        let held ← fixture.document.read
        return back == some (encoded.words, encoded.strings) && unknown == some #[] &&
            second.isSome &&
            second == fromAnchor &&
            third == fromStart &&
            second != third &&
            mixed == plain &&
            mixed != whole &&
            held == "ab\ncd\nef" },
    { name := "a display nothing was published to has no scene to write back"
      run := do
        let display ← Editor.Ffi.Display.newCells 8 16
        return (← display.scene).isNone },
    { name :=
        "a theme that uses every slant, every underline style and both kinds of line height is the words and the string of the library's layout, with a weight out of range sent as the nearest end; and the library takes it and writes it back"
      run := do
        let fixture ← sceneFixture everyTheme
        let real := fixture.real
        let encoded ← real.encode emptyScene (some everyTheme)
        let scene : Array UInt64 := #[8, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        -- Present, and seven definitions.
        let faces : Array UInt64 := #[1, 7]
        -- Its name; a family; 20 pixels; weight 700; italic; a foreground
        -- and a background; a curly underline with a colour; struck
        -- through; a line height of 24 pixels; a vertical padding of 3.
        let all : Array UInt64 :=
          #[3, 1, 4, 1, 1280, 1, 700, 1, 1, 1, 0x11223344, 1, 0xaabbccff, 1, 3, 1, 0xff0000ff, 1, 1,
            1, 1, 1536, 1, 192]
        -- Its name, and nothing set.
        let unset : Array UInt64 :=
          #[5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        -- A name of two bytes; upright; no underline, which is set; not
        -- struck through, which is set; one and a half times the font's
        -- own line height.
        let upright : Array UInt64 :=
          #[2, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 96, 0, 0]
        -- Oblique, and a single underline with no colour of its own.
        let oblique : Array UInt64 :=
          #[1, 0, 0, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        -- A weight over 1000, sent as 1000, and a double underline.
        let heavy : Array UInt64 :=
          #[1, 0, 0, 0, 0, 1, 1000, 0, 0, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        -- A weight of 0, sent as 1, and a dotted underline.
        let light : Array UInt64 :=
          #[1, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 1, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        -- A dashed underline.
        let dashed : Array UInt64 :=
          #[1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        real.publish emptyScene
        let back ← real.display.scene
        return encoded.words ==
              scene ++ faces ++ all ++ unset ++ upright ++ oblique ++ heavy ++ light ++ dashed &&
            encoded.strings == "allmonounsetébcde" &&
            back == some (encoded.words, encoded.strings) },
    { name :=
        "a theme is sent with the first scene published after it was set and not with the next, which is laid out in the faces last sent"
      run := do
        let first : Editor.Theme :=
          #[{ name := ⟨"default"⟩, face := { background := some (.rgb 1 2 3) } }]
        let second : Editor.Theme :=
          #[{ name := ⟨"default"⟩, face := { background := some (.rgb 4 5 6) } }]
        let fixture ← sceneFixture first
        let real := fixture.real
        let scene := fixture.scene (SceneFixture.own fixture.top) #[]
        let sent (faces : Option Editor.Theme) : IO (Option (Array UInt64 × String)) := do
          let encoded ← real.encode scene faces
          return some (encoded.words, encoded.strings)
        real.publish scene
        let withFirst ← real.display.scene
        let inFirst ← real.display.frameText
        real.publish scene
        let withNone ← real.display.scene
        let stillFirst ← real.display.frameText
        real.setTheme second
        real.publish scene
        let withSecond ← real.display.scene
        let inSecond ← real.display.frameText
        real.publish scene
        let withNoneAgain ← real.display.scene
        let stillSecond ← real.display.frameText
        -- The document is held until here, past the last publish.
        let held ← fixture.document.read
        return withFirst == (← sent (some first)) && withNone == (← sent none) &&
            stillFirst == inFirst &&
            withSecond == (← sent (some second)) &&
            inSecond != inFirst &&
            withNoneAgain == withNone &&
            stillSecond == inSecond &&
            held == "ab\ncd\nef" },
    { name :=
        "of the built-in theme's names, layout reads default, selection and mode-line by itself: with each renamed in turn the frame is another, and with echo-area renamed, which nothing draws, it is the built-in theme's"
      run := do
        let renamed (name : String) : Editor.Theme :=
          Editor.Theme.builtin.map fun definition =>
            if definition.name.name == name then { definition with name := ⟨name ++ ".renamed"⟩ }
            else definition
        let fixture ← sceneFixture Editor.Theme.builtin
        let real := fixture.real
        -- View 2 has a selection and a status field.
        let scene :=
          fixture.scene (SceneFixture.own fixture.anchor) #[SceneFixture.own fixture.selection]
        real.publish scene
        let builtin ← real.display.frameText
        let mut frames := #[builtin]
        for name in ["default", "selection", "mode-line"] do
          real.setTheme (renamed name)
          real.publish scene
          frames := frames.push (← real.display.frameText)
        real.setTheme (renamed "echo-area")
        real.publish scene
        let unread ← real.display.frameText
        -- The document is held until here, past the last publish.
        let held ← fixture.document.read
        let distinct :=
          (List.range frames.size).all fun later =>
            (List.range later).all fun earlier => frames[later]? != frames[earlier]?
        return frames.size == 4 && distinct && unread == builtin && held == "ab\ncd\nef" }]

/-- Publishes the display fixture through the real binding and checks it
against the frame checked in at `fixture` (`tests/display/frame.expected`),
which `editor-layout`'s own test lays out from the same scene: the frame's
text must be the file's; the scene the library writes back must be the
words and the string it was sent; and for a position on each of three of
the frame's rows, one of them inside a wrapped line, the position one
visual line below it, asked through the binding, must be on the frame's
next row. Returns the names of what did not hold. -/
def displayChecks' (fixture : String) : IO (List String) := do
  let expected ← IO.FS.readFile fixture
  let (real, scene, documents) ← displayFixture
  let published ← (Editor.Display.publish scene).runReal real
  let mut failed : List String := []
  if let .error refusal := published then
    failed := failed ++ [s!"publishing was refused: {repr refusal}"]
  if (← real.display.frameText) != expected then
    failed := failed ++ ["the published frame differs from the fixture"]
  -- The first publish sends the fixture's theme with the scene.
  let encoded ← real.encode scene (some fixtureTheme)
  if (← real.display.scene) != some (encoded.words, encoded.strings) then
    failed := failed ++ ["the scene the library writes back is not the one it was sent"]
  let rows := (← real.display.frameRows 1).getD #[]
  -- The documents are held until here, past the publish.
  if documents.size != 2 then
    failed := failed ++ ["the fixture made two documents"]
  for position in [2, 14, 19] do
    let some here := rows.findIdx? fun row => row.start.toNat ≤ position ∧ position < row.stop.toNat
      | failed := failed ++ [s!"no row of the frame holds {position}"]
    let some next := rows[here + 1]?
      | failed := failed ++ [s!"the frame has no row below {position}'s"]
    let moved ←
      (Editor.Display.linesFrom
              { snapshot := ⟨0⟩, width := 96, position, lines := 1, goal := none }).runReal
          real
    match moved with
    | .ok moved =>
      unless next.start.toNat ≤ moved.position ∧ moved.position ≤ next.stop.toNat do
        failed :=
          failed ++
            [s!"one line below {position} is {moved.position}, not on the frame's next row {next.start}..{next.stop}"]
    | .error refusal =>
      failed := failed ++ [s!"the move from {position} was refused: {repr refusal}"]
  return failed

/-- Runs `displayChecks'` on the fixture at `fixture`: exits 0 when all hold,
and 1 after naming on stderr those that do not. -/
def displayScenario (fixture : String) : IO UInt8 := do
  let failed ← displayChecks' fixture
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    return 1
  IO.println
      "ffi-test display: the published frame is the fixture, the scene comes back as sent, and three moves land on the frame's next row"
  return 0

/-! ## Theme pictures

Pictures the library's CPU renderer draws of a display's frame
(`Ffi.Display.picture`), and the pure helpers the theme-pictures scenario
reads them with. A pixel is a `Color`, its four bytes red first, so it
compares with a theme's colours as they are. -/

/-- The pixel numbered `index` of `picture`, counted row by row from the
top left; `none` past its last. -/
def pixelAt (picture : Editor.Ffi.Picture) (index : Nat) : Option Editor.Color :=
  if index * 4 + 4 ≤ picture.rgba.size then
    let byte (offset : Nat) : UInt8 := picture.rgba.get! (index * 4 + offset)
    some (.rgba (byte 0) (byte 1) (byte 2) (byte 3))
  else none

/-- How many pixels `picture` has. -/
def pixelCount (picture : Editor.Ffi.Picture) : Nat :=
  picture.rgba.size / 4

/-- The four bytes of `color`, red first. -/
def channels (color : Editor.Color) : List Nat :=
  [24, 16, 8, 0].map fun shift => ((color.word >>> shift.toUInt32) &&& 0xff).toNat

/-- The largest difference of any channel of two colours. -/
def channelDistance (one two : Editor.Color) : Nat :=
  ((channels one).zip (channels two)).foldl (fun worst (a, b) => max worst (max a b - min a b)) 0

/-- The numbers of the pixels where `one` and `two` differ; none when they
are not the same size. -/
def differing (one two : Editor.Ffi.Picture) : Array Nat :=
  if (one.width, one.height) != (two.width, two.height) then #[]
  else (Array.range (pixelCount one)).filter fun index => pixelAt one index != pixelAt two index

/-- How `one` differs from `two`: `none` when they are not the same size,
and otherwise the largest difference of any channel of any pixel, with how
many pixels differ at all. -/
def difference (one two : Editor.Ffi.Picture) : Option (Nat × Nat) :=
  if (one.width, one.height) != (two.width, two.height) then none
  else
    some <|
      (differing one two).foldl
        (fun (worst, count) index =>
          match pixelAt one index, pixelAt two index with
          | some a, some b => (max worst (channelDistance a b), count + 1)
          | _, _ => (worst, count + 1))
        (0, 0)

/-- The colour most of the pixels numbered `indices` of `picture` have;
`none` when there are none. -/
def commonest (picture : Editor.Ffi.Picture) (indices : Array Nat) : Option Editor.Color :=
  let counts : Std.HashMap UInt32 Nat :=
    indices.foldl
      (fun counts index =>
        match pixelAt picture index with
        | some color => counts.insert color.word (counts.getD color.word 0 + 1)
        | none => counts)
      {}
  let best :=
    counts.fold
      (fun (best : Option (UInt32 × Nat)) word count =>
        match best with
        | some (_, most) => if count > most then some (word, count) else best
        | none => some (word, count))
      none
  best.map fun (word, _) => { word }

/-- Whether `color` lies, channel by channel, between `paper` and `ink`,
within `slack` of either end: a blend of the two. -/
def between (paper ink color : Editor.Color) (slack : Nat) : Bool :=
  ((channels paper).zip ((channels ink).zip (channels color))).all fun (p, i, c) =>
    min p i ≤ c + slack && c ≤ max p i + slack

/-- A picture 2 pixels by 2 of `colors`, row by row. -/
def pictureOf (colors : List Editor.Color) : Editor.Ffi.Picture :=
  { width := 2, height := 2
    rgba := ⟨(colors.flatMap fun color => (channels color).map (·.toUInt8)).toArray⟩ }

/-- The checks of the helpers the theme-pictures scenario reads its
pictures with, on pictures 2 by 2 written here, and of a picture's round
trip through a PNG file by the real binding. -/
def pictureChecks (_ : Unit) : List Check :=
  let black := Editor.Color.rgb 0 0 0
  let white := Editor.Color.rgb 255 255 255
  let grey := Editor.Color.rgb 128 128 128
  let red := Editor.Color.rgb 200 0 0
  [{  name := "two pictures differ where their pixels do, by their worst channel"
      run :=
        let one := pictureOf [black, white, grey, grey]
        let two := pictureOf [black, Editor.Color.rgb 250 255 254, grey, red]
        pure
          (differing one two == #[1, 3] && difference one two == some (128, 2) &&
            difference one one == some (0, 0) &&
            difference one
                { one with
                  width := 4, height := 1 } ==
              none) },
    { name := "the commonest colour of some pixels is the one most of them have"
      run :=
        let picture := pictureOf [grey, white, grey, red]
        pure
          (commonest picture #[0, 1, 2, 3] == some grey && commonest picture #[1] == some white &&
            commonest picture #[] == none) },
    { name := "a blend of paper and ink is between them, and a third colour is not"
      run :=
        pure
          (between black white grey 0 && between white black grey 0 && !between black grey red 0 &&
            between black grey (Editor.Color.rgb 129 130 0) 2 &&
            !between black grey (Editor.Color.rgb 129 131 0) 2) },
    { name := "a picture comes back from its PNG file through the library"
      run := do
        let picture := pictureOf [black, white, grey, red]
        return (← Editor.Ffi.Picture.ofPng (← picture.toPng)) == picture },
    { name := "a picture of no pixels is refused a PNG file with a reason"
      run := do
        try
          discard <| Editor.Ffi.Picture.toPng { width := 0, height := 0, rgba := .empty }
          pure false
        catch error =>
          pure !(toString error).isEmpty },
    { name := "bytes that are no PNG file and a font that is none are refused with a reason"
      run := do
        let notPng ←
          try
            discard <| Editor.Ffi.Picture.ofPng "no".toUTF8
            pure false
          catch error =>
            pure !(toString error).isEmpty
        let notFont ←
          try
            discard <| Editor.Ffi.Display.newFont "no".toUTF8 "Noto Sans Mono"
            pure false
          catch error =>
            pure !(toString error).isEmpty
        return notPng && notFont }]

/-- Where `needle` first starts in `haystack`, as a byte offset. -/
def offsetOf (haystack needle : String) : Option Nat :=
  let hay := haystack.toUTF8
  let pin := needle.toUTF8
  (List.range (hay.size + 1 - pin.size)).find? fun start =>
    (List.range pin.size).all fun index => hay.get! (start + index) == pin.get! index

/-- The size of the theme pictures: one view covers it, taller than the
fixture's text, so rows of bare paper remain. -/
def themePictureSize : Editor.Size :=
  { width := 320, height := 160 }

/-- The face name no theme defines, which the scenario draws the cursor in
to find the cursor's cell: by the face rule (`Editor/Face.lean`) a cursor
in it is drawn in the default face's paint, the ink on the paper, so its
background is the paper. -/
def unthemedFace : Editor.FaceName :=
  ⟨"theme-pictures.unthemed"⟩

/-- The status line of the theme pictures: the shipped mode line
(`ModeLine.standard`) of the selected window on `source.lean`, opened as
`source.lean` and not modified, of which the Vim scheme reports `VISUAL` in
`Vim.stateFace "visual"`, with its cursor at the byte `head` of `text`, the
fixture's own text, and `text`'s rows: what the editor sends of such a
window. -/
def themeStatus (text : String) (head : Nat) : Array Editor.StatusField :=
  let before := (String.fromUTF8? (text.toUTF8.extract 0 head)).getD ""
  let rows := before.splitOn "\n"
  let all := text.splitOn "\n"
  let lines := if all.length > 1 && all.getLast? == some "" then all.length - 1 else all.length
  let buffer : Editor.Buffer :=
    { name := "source.lean", text := ⟨0⟩, history := Editor.UndoTree.new ⟨0⟩ 0
      file :=
        some { path := "source.lean", stamp := { seconds := 0, nanoseconds := 0, size := 0 } } }
  Editor.ModeLine.standard.fields
    { buffer, reported := #[{ text := "VISUAL", face := Editor.Vim.stateFace "visual" }]
      cursor := some ⟨rows.length - 1, ((rows.getLast?).getD "").length⟩, lines }

/-- One picture of the theme-pictures scene, drawn through the real
binding over a display of the one font `font`: `text` in one view the size
of `themePictureSize`, in `theme`, with the shipped mode line of a selected
window in visual state on `source.lean` (`themeStatus`): the `VISUAL` badge,
the buffer's name, and on the right line:col and the position, the same in
every draw, read from `selectedIn`; padded as the editor pads a window,
`Loop.padding` points across and down. With `selected`, the text holds
one selection, from the `a` of `area` to its head on the `h` of `(w h`,
with a block cursor there in `cursor`; without, it holds none, and so no
cursor. The offsets are found in `selectedIn`, the fixture's own text, so
that a text of spaces is selected where the fixture is. -/
def themePicture (font : ByteArray) (theme : Editor.Theme) (text selectedIn : String)
    (selected : Option Editor.FaceName) : IO Editor.Ffi.Picture := do
  let some anchor := offsetOf selectedIn "def area"
    | throw (IO.userError "the fixture has no `def area`")
  let some head := offsetOf selectedIn "(w h"
    | throw (IO.userError "the fixture has no `(w h`")
  let document ← Editor.Ffi.Document.new text
  let scroll ← markIn document (.anchor { offset := 0, bias := .before })
  let selection ← markIn document (rangeMarker (anchor + 4).toUInt64 (head + 3).toUInt64)
  let table ← Editor.Snapshots.new
  let snapshot ← table.add (← document.snapshot)
  let display ← Editor.Ffi.Display.newFont font "Noto Sans Mono"
  let real ← Editor.RealDisplay.over display table.reader theme
  let marker (index : Nat) : Editor.MarkerId := { text := ⟨0⟩, index }
  let size := themePictureSize
  let scene : Editor.Scene :=
    { size
      views :=
        #[{ id := ⟨1⟩, rect := { x := 0, y := 0, width := size.width, height := size.height }
            snapshot, scroll := marker scroll
            selections := if selected.isSome then #[marker selection] else #[]
            cursor := { shape := .block, face := selected.getD unthemedFace }
            decorations := #[]
            status := themeStatus selectedIn (head + 3)
            -- The editor's frame padding at scale 1 (`Loop.padding`).
            padding := { across := Editor.Loop.padding, down := Editor.Loop.padding } }]
      focused := some ⟨1⟩, echo := "", pending := "", preedit := none }
  if let .error refusal← (Editor.Display.publish scene).runReal real then
    throw (IO.userError s!"publishing was refused: {repr refusal}")
  let picture ← display.picture
  -- The document is held until here, past the publish: the library reads
  -- its markers.
  discard <| document.read
  return picture

/-- The colours a shipped theme's source gives its paper, its body text and
its cursor, written from its published record (`Themes.Solarized.published`,
`Themes.FairyFloss.published`, pinned by `ModelTest.solarizedChecks` and
`ModelTest.fairyFlossChecks`), not read from the theme. -/
structure ThemeRoles where
  /-- The shipped theme's name, and its reference image's. -/
  name : String
  /-- The background. -/
  paper : Editor.Color
  /-- The body text. -/
  ink : Editor.Color
  /-- The cursor's background. -/
  cursor : Editor.Color

/-- Solarized dark's and light's roles: base0 on base03, its cursor
base0; base00 on base3, its cursor base00. -/
def solarizedRoles : List ThemeRoles :=
  let c := Editor.Themes.Solarized.published
  [{ name := "solarized-dark", paper := c.base03, ink := c.base0, cursor := c.base0 },
    { name := "solarized-light", paper := c.base3, ink := c.base00, cursor := c.base00 }]

/-- Fairy Floss's roles: the tmTheme's foreground on its background, its
cursor the caret. -/
def fairyFlossRoles : ThemeRoles :=
  let c := Editor.Themes.FairyFloss.published
  { name := "fairy-floss", paper := c.background, ink := c.foreground, cursor := c.caret }

/-- The roles of every shipped theme that has a reference image. -/
def shippedRoles : List ThemeRoles :=
  solarizedRoles ++ [fairyFlossRoles]

/-- `names` as a list in prose: `a`, `a and b`, `a, b and c`. -/
def proseList : List String → String
  | [] => ""
  | [one] => one
  | names => ", ".intercalate names.dropLast ++ " and " ++ names.getLast!

/-- How far any channel of any pixel may be from the reference's: 2 of 255,
the bound and the reason of the renderer's own reference image
(`crates/editor-render-wgpu/tests/reference.rs`). -/
def pictureTolerance : Nat :=
  2

/-- The largest a theme's reference image may be as a file. -/
def largestReference : Nat :=
  20000

/-- The four pictures of one variant: the scene, the scene with its cursor
in a face nothing defines, and the scene with no selection over the
fixture's text and over the same text with every character but a newline a
space. -/
structure ThemePictures where
  /-- The scene. -/
  scene : Editor.Ffi.Picture
  /-- Its cursor unthemed. -/
  unthemed : Editor.Ffi.Picture
  /-- No selection, over the text. -/
  text : Editor.Ffi.Picture
  /-- No selection, over spaces. -/
  blank : Editor.Ffi.Picture

/-- The four pictures of `theme`, over the fixture `source`. -/
def themePictures (font : ByteArray) (theme : Editor.Theme) (source : String) : IO ThemePictures :=
  do
  let spaces := String.ofList (source.toList.map fun c => if c == '\n' then c else ' ')
  return {
      scene := ← themePicture font theme source source (some (Editor.Vim.cursorFace "visual"))
      unthemed := ← themePicture font theme source source (some unthemedFace)
      text := ← themePicture font theme source source none
      blank := ← themePicture font theme spaces source none }

/-- The role checks of one variant's pictures, as the names of what did
not hold: the commonest colour is the paper; the pixels where the cursor's
cell changes when its face is unthemed are mostly the cursor colour; and
the pixels the text changes from spaces are blends of the paper and the
ink, one of them within the tolerance of the ink. -/
def roleChecks (roles : ThemeRoles) (pictures : ThemePictures) : List String :=
  let all := Array.range (pixelCount pictures.scene)
  let paper :=
    if commonest pictures.scene all == some roles.paper then []
    else [s!"{roles.name}: the commonest colour is not the paper"]
  let cell := differing pictures.scene pictures.unthemed
  let cursor :=
    if cell.isEmpty then [s!"{roles.name}: the cursor's face changes no pixel"]
    else
      if commonest pictures.scene cell == some roles.cursor then []
      else [s!"{roles.name}: the cursor's cell is not mostly the cursor colour"]
  let glyphs := differing pictures.text pictures.blank
  let inked := glyphs.filterMap (pixelAt pictures.text)
  let blended :=
    if inked.isEmpty then [s!"{roles.name}: the text changes no pixel from spaces"]
    else
      if !inked.all (between roles.paper roles.ink · pictureTolerance) then
        [s!"{roles.name}: a pixel of the text is not between the paper and the ink"]
      else
        let farthest :=
          inked.foldl
            (fun (far : Editor.Color) pixel =>
              if channelDistance pixel roles.paper > channelDistance far roles.paper then pixel
              else far)
            roles.paper
        if channelDistance farthest roles.ink ≤ pictureTolerance then []
        else [s!"{roles.name}: no pixel of the text is the ink"]
  paper ++ cursor ++ blended

/-- The theme-pictures scenario over the reference images in `dir`, its
fixture `dir/source.lean`, and the font file `font`. For each theme of
`variants`, looked up by name in `Themes.shipped`, it draws the four pictures (`themePictures`) and, with
`write`, writes the scene's picture to `dir/<name>.png` (`mise run
theme-references`); without, it compares the scene's picture with that
file within `pictureTolerance`, runs `roleChecks`, and guards that each
reference is the scene's size and at most `largestReference` bytes, and
that the light picture does not match the dark reference. Exits 0 after a
line naming what held, or 1 after `FAILED:` lines, in either mode.
`variants`, the themes it draws, are `shippedRoles` except in its own
check (`themePicturesChecks`). -/
def themePicturesScenario (dir font : String) (write : Bool)
    (variants : List ThemeRoles := shippedRoles) : IO UInt8 := do
  let source ← IO.FS.readFile (System.FilePath.mk dir / "source.lean")
  let fontBytes ← IO.FS.readBinFile font
  let mut failed : List String := []
  let mut scenes : List (String × Editor.Ffi.Picture) := []
  let mut references : List (String × Editor.Ffi.Picture) := []
  for roles in variants do
    let some named := Editor.Themes.shipped.find? (·.name == roles.name)
      | failed := failed ++ [s!"no shipped theme is named {roles.name}"]
    let pictures ← themePictures fontBytes named.theme source
    let path := System.FilePath.mk dir / s!"{roles.name}.png"
    scenes := scenes ++ [(roles.name, pictures.scene)]
    if write then
      let bytes ← pictures.scene.toPng
      IO.FS.writeBinFile path bytes
      IO.println
          s!"ffi-test theme-pictures: wrote {path}: {pictures.scene.width} by {pictures.scene.height} pixels, {bytes.size} bytes"
      continue
    let file ← IO.FS.readBinFile path
    let reference ← Editor.Ffi.Picture.ofPng file
    references := references ++ [(roles.name, reference)]
    let size := themePictureSize
    unless
      (reference.width, reference.height) == (size.width, size.height) &&
        file.size ≤ largestReference do
      failed :=
        failed ++
          [s!"{path} is {reference.width} by {reference.height} and {file.size} bytes, not {size.width} by {size.height} and at most {largestReference}"]
    match difference pictures.scene reference with
    | some (worst, count) =>
      unless worst ≤ pictureTolerance do
        failed :=
          failed ++
            [s!"{count} pixels of {roles.name} differ from {path}, one by {worst} of 255; the tolerance is {pictureTolerance}"]
    | none =>
      failed := failed ++ [s!"the picture of {roles.name} is not the size of {path}"]
    failed := failed ++ roleChecks roles pictures
  unless write do
    match scenes.lookup "solarized-light", references.lookup "solarized-dark" with
    | some light, some dark =>
      unless (difference light dark).any (·.1 > pictureTolerance) do
        failed := failed ++ ["the light picture matches the dark reference"]
    | _, _ =>
      failed := failed ++ ["there is no light picture and dark reference to tell apart"]
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    return 1
  if write then
    return 0
  IO.println
      s!"ffi-test theme-pictures: {proseList (variants.map (·.name))} match their reference images; in each the paper, the cursor and the text carry the palette's colours; the light picture is not the dark reference"
  return 0

/-- The checks of the theme-pictures scenario's own reporting, over a
directory of its own and a theme no shipped theme is named, so that
nothing is drawn or written. -/
def themePicturesChecks (_ : Unit) : List Check :=
  [{  name := "theme-pictures --write says why it fails on stderr, not only by its status"
      run :=
        inOwnDirectory fun directory => do
          IO.FS.writeFile (directory / "source.lean") ""
          let font := directory / "font.ttf"
          IO.FS.writeBinFile font .empty
          let missing : ThemeRoles :=
            { name := "no-such-theme", paper := .rgb 0 0 0, ink := .rgb 0 0 0,
              cursor := .rgb 0 0 0 }
          let errors ← IO.mkRef ({} : IO.FS.Stream.Buffer)
          let status ←
            IO.withStderr (IO.FS.Stream.ofBuffer errors) <|
                themePicturesScenario directory.toString font.toString true [missing]
          let said := String.fromUTF8? (← errors.get).data
          return status == 1 && said == some "FAILED: no shipped theme is named no-such-theme\n" }]

/-- The checks of the fuzzy ranking's binding: a pattern and a list of
strings in, as words and one string, and the indices of the candidates the
pattern matches out, as words. Which candidates match and in what order are
the library's rules; these pin that the pattern, the candidates and the
answer cross. The first case is one the library's rules fix whatever a
matcher's scores: of `wq`, `edit` and `w` the pattern `w` matches the first
and the third, and the third is the pattern. -/
def fuzzyChecks (_ : Unit) : List Check :=
  [{ name := "a ranking crosses: the candidates a pattern matches, as their indices, best first",
     run := return (← Editor.Ffi.fuzzyRank "w" #["wq", "edit", "w"]) == #[2, 0] },
    { name :=
        "a candidate of two-byte characters between two of ASCII is cut where it ends: each is matched by a pattern of its own characters alone"
      run := do
        let candidates := #["ab", "éè", "cd"]
        return (← Editor.Ffi.fuzzyRank "b" candidates) == #[0] &&
            (← Editor.Ffi.fuzzyRank "éè" candidates) == #[1] &&
            (← Editor.Ffi.fuzzyRank "è" candidates) == #[1] &&
            (← Editor.Ffi.fuzzyRank "c" candidates) == #[2] &&
            (← Editor.Ffi.fuzzyRank "bé" candidates) == #[] },
    { name := "a pattern of two-byte characters crosses whole",
      run := return (← Editor.Ffi.fuzzyRank "日本" #["日x本", "日", "本日"]) == #[0] },
    { name := "an empty candidate crosses as a candidate, and an empty list as no candidates"
      run := do
        return (← Editor.Ffi.fuzzyRank "x" #["", "x", ""]) == #[1] &&
            (← Editor.Ffi.fuzzyRank "x" #[]) == #[] &&
            (← Editor.Ffi.fuzzyRank "" #[]) == #[] },
    { name := "the empty pattern answers every index, each once"
      run := do
        let ranked ← Editor.Ffi.fuzzyRank "" #["b", "", "a", "b"]
        return ranked.qsort (· < ·) == #[0, 1, 2, 3] },
    { name := "ten thousand candidates cross, and every index answered is one of theirs"
      run := do
        let candidates := (Array.range 10000).map fun index => s!"candidate-{index}"
        let ranked ← Editor.Ffi.fuzzyRank "date-99" candidates
        -- `candidate-99`, `candidate-199`, `candidate-990` and their like.
        return ranked.contains 99 && ranked.contains 9990 && !ranked.contains 98 &&
            ranked.all (· < 10000) &&
            (← Editor.Ffi.fuzzyRank "" candidates).size == 10000 }]

/-- How many frames the library's latest render session was submitted; 0
when none has started. -/
def framesSubmitted : IO UInt64 := do
  return (← Editor.Ffi.renderCounters).map (·.framesSubmitted) |>.getD 0

/-- The checks of the bindings that reach the library's render wiring: the
headless render session, a display bound to the process's presenter, the
journal and the counters of the latest session, and the display's heights.
They check that the bindings reach the wiring, and nothing of the render
loop's scheduler, which is `editor-render`'s: no check waits for time to
pass to see that nothing happens, and none publishes a scene twice to see
what an equal frame does. The process has one presenter, so each check
stops what it starts and asserts only differences it caused. -/
def renderChecks (_ : Unit) : List Check :=
  [{  name :=
        "a bound display's scene reaches the headless render session, which comes to rest, and the frame's entry answers the window input taken before it"
      run := do
        let fixture ← sceneFixture
        Editor.Ffi.Display.present fixture.real.display
        -- An earlier check's window input may still wait for a frame: a
        -- publish with no session running spends it.
        fixture.real.publish (fixture.scene (SceneFixture.own fixture.anchor) #[])
        unless (← Editor.Ffi.renderHeadless) matches .ok () do
          return false
        let before ← framesSubmitted
        let posted ← Editor.Ffi.postInput .resize 0 "" #[64, 48, (1.0 : Float).toBits, 0]
        let some taken ← pull .editor | return false
        fixture.real.publish (fixture.scene (SceneFixture.own fixture.top) #[])
        let submitted := (← framesSubmitted) == before + 1
        let rested ← eventually (return (← Editor.Ffi.renderResting) == some true)
        let entries := (← Editor.Ffi.renderJournal 0).getD #[]
        let answered := entries.back?.map (·.inputNs) == some taken.stamp
        let stopped ← Editor.Ffi.renderStop
        let _ ← fixture.document.read
        return posted && taken.source.kind == .window && submitted && rested && answered &&
            stopped },
    { name := "a scene published by a display that is not bound reaches no render session"
      run := do
        unless (← Editor.Ffi.renderHeadless) matches .ok () do
          return false
        let fixture ← sceneFixture
        let before ← framesSubmitted
        fixture.real.publish (fixture.scene (SceneFixture.own fixture.top) #[])
        let after ← framesSubmitted
        let stopped ← Editor.Ffi.renderStop
        let _ ← fixture.document.read
        return after == before && stopped },
    { name :=
        "a headless render session asked for while one runs is refused with the library's reason, starting nothing, and the one that runs is stopped once"
      run := do
        unless (← Editor.Ffi.renderHeadless) matches .ok () do
          return false
        let again ← Editor.Ffi.renderHeadless
        let stopped ← Editor.Ffi.renderStop
        let stoppedAgain ← Editor.Ffi.renderStop
        return (match again with
            | .error reason => !reason.isEmpty
            | .ok () => false) &&
            stopped &&
            !stoppedAgain },
    { name :=
        "a display in cells answers its cell's height for a text row, a status row and the bottom row"
      run := do
        let display ← Editor.Ffi.Display.newCells 8 16
        let heights ← display.heights
        let taller ← (← Editor.Ffi.Display.newCells 8 20).heights
        return heights == { text := 16, status := 16, message := 16 } &&
            taller == { text := 20, status := 20, message := 20 } },
    { name :=
        "a theme whose mode line and echo area have a vertical padding reaches layout through the binding: its status row and bottom row are taller by twice it"
      run := do
        let padded : Editor.Theme :=
          #[{ name := ⟨"mode-line"⟩, face := { verticalPadding := some 3 } },
            { name := ⟨"echo-area"⟩, face := { verticalPadding := some 5 } }]
        let fixture ← sceneFixture padded
        let heights ← fixture.real.heights
        let _ ← fixture.document.read
        return heights == { text := 16, status := 22, message := 26 } },
    { name :=
        "a bound display is drawn in the scripted window while it is open, the window's session's counters are read once it has closed, and a scene published then reaches nothing"
      run := do
        let fixture ← sceneFixture
        Editor.Ffi.Display.present fixture.real.display
        let run ← IO.asTask (prio := .dedicated) (Editor.Ffi.windowRun .scripted true)
        -- The window has opened once its first event arrives.
        let some opened ← pull .editor | return false
        fixture.real.publish (fixture.scene (SceneFixture.own fixture.top) #[])
        for _ in [1:(windowSample true).length] do
          let some _ ← pull .editor | break
        Editor.Ffi.windowClose .scripted
        unless ← eventually (IO.hasFinished run) do
          return false
        let ran := (← IO.ofExcept run.get) matches .ok { nothingDrew := none }
        let drawn ← framesSubmitted
        fixture.real.publish (fixture.scene (SceneFixture.own fixture.anchor) #[])
        let after ← framesSubmitted
        let _ ← fixture.document.read
        return ran && opened.kind == .windowOpened && drawn >= 1 && after == drawn }]

/-- The id of the watch service as an event's source. -/
def watchService : UInt64 :=
  4

/-- Whether the next completion is the watch service's for `id`. -/
def watchCompleted (id : UInt64) : IO Bool := do
  let some event ← pull .completion | return false
  return event.source == { kind := .library, id := watchService } && event.kind == .completion &&
      event.code == id

/-- The bit of a written change. -/
def writtenBit : UInt64 :=
  2

/-- The checks of the watch service's bindings: a start, a read and a take
in a temporary directory, words that spell no start refused, and the
decoding of a reply's words. -/
def watchChecks (_ : Unit) : List Check :=
  [{  name :=
        "a watch starts through the watch service, its completion comes back with its id, and a write to its file comes back as a change of the file's path, written, taken once"
      run :=
        inOwnDirectory fun directory => do
          let file := directory / "f"
          IO.FS.writeFile file "a"
          unless ← Editor.Ffi.watchesStart 1201 0 0 64 file.toString do
            return false
          unless ← watchCompleted 1201 do
            return false
          let started ← Editor.Ffi.watchesTake 1201
          IO.FS.writeFile file "b"
          let mut written := false
          let mut onlyTheFile := true
          for wait in [1202:1206] do
            unless ← Editor.Ffi.watchesNext 1201 wait.toUInt64 do
              return false
            unless ← watchCompleted wait.toUInt64 do
              return false
            match ← Editor.Ffi.watchesTake wait.toUInt64 with
            | some (.changes changes) =>
              onlyTheFile := onlyTheFile && changes.all (·.1 == file.toString.toUTF8)
              if changes.any (·.2 &&& writtenBit != 0) then
                written := true
                break
            | _ =>
              return false
          let again ← Editor.Ffi.watchesTake 1202
          let cancelled ← Editor.Ffi.watchesCancel 1201
          return started == some .started && written && onlyTheFile && again.isNone && cancelled },
    { name :=
        "words that spell no start start no watch, and a missing directory is refused as not found, naming it"
      run :=
        inOwnDirectory fun directory => do
          let malformed ← Editor.Ffi.watchesStart 1210 9 0 64 directory.toString
          let missing := directory / "missing"
          unless ← Editor.Ffi.watchesStart 1211 1 0 64 missing.toString do
            return false
          unless ← watchCompleted 1211 do
            return false
          let refused ←
            match ← Editor.Ffi.watchesTake 1211 with
            | some (.refused .notFound detail) =>
              pure (decide ((detail.splitOn "missing").length > 1))
            | _ =>
              pure false
          return !malformed && refused },
    { name :=
        "a watch reply decodes: started, each refusal, and changes as each path's bytes and its kinds' bits; words that do not add up are an error"
      run := do
        let decode (status : UInt64) (values : List UInt64) (paths : ByteArray := .empty) :=
          (Editor.Ffi.WatchReply.decode status (wordBytes values) "why" paths).toOption
        let changes := decode 8 [2, 4, 3, 2, 16] ("/w/a/x".toUTF8)
        return decode 0 [] == some .started && decode 2 [] == some (.refused .notFound "why") &&
            decode 5 [] == some (.refused .limit "why") &&
            changes == some (.changes #[("/w/a".toUTF8, 3), ("/x".toUTF8, 16)]) &&
            decode 8 [1, 9, 2] ("/w".toUTF8) == none &&
            decode 9 [] == none }]

/-- The `status` line of the view `id` in `frame`, a frame as
`Display.frameText` writes it; `none` when the view has no status row. -/
def statusLineOf (frame : String) (id : Nat) : Option String := do
  let lines := frame.splitOn "\n"
  let start ← lines.findIdx? (·.startsWith s!"view {id} rect ")
  let inView := (lines.drop (start + 1)).takeWhile (·.startsWith "  ")
  inView.find? (·.startsWith "  status ")

/-- The x of the first glyph of the status row of the view `id` in `frame`:
the first `id@x` after ` glyphs` on its `status` line; `none` when the view
has no status row or its row no glyph. -/
def firstStatusGlyph (frame : String) (id : Nat) : Option Nat := do
  let status ← statusLineOf frame id
  let glyphs := (status.splitOn " glyphs ")[1]?.getD ""
  let first ← (glyphs.splitOn " ").head?
  let x := (first.splitOn "@")[1]?.getD ""
  -- A glyph in another font has `#font` after its x.
  ((x.splitOn "#").head?.getD "").toNat?

/-- The x of the first field's box of the status row of the view `id` in
`frame`: the `x` of the first `x+width:colour` after ` boxes`. -/
def firstStatusBox (frame : String) (id : Nat) : Option Nat := do
  let status ← statusLineOf frame id
  let boxes := (status.splitOn " boxes ")[1]?.getD ""
  let first ← (boxes.splitOn " ").head?
  ((first.splitOn "+").head?.getD "").toNat?

/-- The frame the real display, in cells 8 pixels across and 16 down at scale
1, lays out of the scene the loop publishes after a resize of a frame 640 by
480 to `corner` points of corner clearance, in fullscreen when `fullscreen`
says, each step handed a frame padding of 8: with a `:` prompt open over the
scratch window when `prompt` says, and otherwise with `echo` in the echo
area. And the id of the minibuffer's view, when a prompt is open. At scale 1
a point is a pixel, so the glyph positions are the scene's points. -/
def paddedFrame (corner : Nat) (fullscreen prompt : Bool) (echo : String := "") :
    IO (String × Option Nat) := do
  let table ← Editor.Snapshots.new
  let display ← Editor.Ffi.Display.newCells 8 16
  let real ← Editor.RealDisplay.over display table.reader #[]
  let program : Editor.EditorM (Option Nat) := do
    let state ← Editor.EditorState.initial ⟨640, 480⟩
    let state ←
      if prompt then
        do
          let made ← Editor.createText ""
          let scroll ← made.mark (.anchor { offset := 0, bias := .before })
          let selection ← made.mark (.selection { ranges := #[⟨0, 0⟩] })
          let history ← Editor.UndoTree.over made
          pure (state.openPrompt ":" { command := "ex" } made history scroll selection).2
      else
        pure { state with echo }
    let loop : Editor.Loop Editor.TestScheme.scheme := { state }
    let keys : Editor.Loop.Keys Editor.TestScheme.scheme := { padding := 8 }
    let resized ←
      loop.step keys (.resize { width := 640, height := 480, scale := 1.0, fullscreen, corner })
    return resized.loop.state.minibufferView?.map (·.index)
  let (result, _) ← program.runReal (Editor.RealTexts.over table) real.handle
  let .ok minibuffer := result | throw (IO.userError "the loop's program was refused")
  return (← display.frameText, minibuffer)

/-- The checks of criterion 3 over real layout (`ModelTest.paddingChecks`
pins the same numbers in the scene): the first glyph of the frame's bottom
row, the `:` prompt's label in the minibuffer's view's status row and an
echo in the echo's view, starts at or past the larger of the padding and the
corner clearance outside fullscreen, and at the padding alone in
fullscreen. -/
def paddingChecks (_ : Unit) : List Check :=
  [{  name :=
        "criterion 3, over real layout: with a prompt open, padding 8 and a corner clearance of 14, the prompt's first glyph is at 14 or past it, and the window's text and its mode line's first field are at 8; in fullscreen the prompt's first glyph is at 8, the padding alone"
      run := do
        let (windowed, some minibuffer) ← paddedFrame 14 false true | return false
        let (full, some fullMinibuffer) ← paddedFrame 14 true true | return false
        let prompt := firstStatusGlyph windowed minibuffer
        -- The window's mode line's first field starts at the padding; its
        -- glyphs are its own padding further in.
        let window := firstStatusBox windowed 0
        return prompt.any (· ≥ 14) && prompt == some 14 && window == some 8 &&
            firstStatusGlyph full fullMinibuffer == some 8 &&
            (windowed.splitOn "  row x 8 y 8 ").length > 1 },
    { name :=
        "criterion 3, over real layout: with no prompt open, padding 8 and a corner clearance of 14, an echo's first glyph is at 14 or past it; in fullscreen at 8, the padding alone"
      run := do
        let echoView := 18446744073709551615
        let (windowed, none) ← paddedFrame 14 false false "hello" | return false
        let (full, none) ← paddedFrame 14 true false "hello" | return false
        let echo := firstStatusGlyph windowed echoView
        return echo.any (· ≥ 14) && echo == some 14 && firstStatusGlyph full echoView == some 8 }]

/-- Every check, in the order they run. -/
def checks (_ : Unit) : List Check :=
  entryChecks () ++ handleChecks () ++ dataChecks () ++ queueChecks () ++ timerChecks () ++
    fileChecks () ++
    processChecks () ++
    watchChecks () ++
    documentChecks () ++
    snapshotChecks () ++
    transactionChecks () ++
    markerChecks () ++
    inverseChecks () ++
    windowChecks () ++
    displayChecks () ++
    sceneChecks () ++
    decodeChecks () ++
    eventDecodeChecks () ++
    eventChecks () ++
    interruptChecks () ++
    fuzzyChecks () ++
    pictureChecks () ++
    themePicturesChecks () ++
    paddingChecks () ++
    renderChecks ()

/-- Runs `checks` and returns the names of those that failed. A check that
throws has failed, and its error is reported with its name. -/
def failures (checks : List Check) : IO (List String) :=
  checks.filterMapM fun check => do
    try
      return if ← check.run then none else some check.name
    catch error =>
      return some s!"{check.name} ({error})"

/-- The checks of shutdown, run by `ffi-test shutdown` in a process of their
own because quit is for good. They run in order: the first quits the queues. -/
def shutdownChecks (_ : Unit) : List Check :=
  [{ name := "quit wakes a task parked on each queue with a quit event",
     run := do
       let editor ← IO.asTask (prio := .dedicated) (Editor.Ffi.nextEvent .editor)
       let completion ← IO.asTask (prio := .dedicated) (Editor.Ffi.nextEvent .completion)
       let parked ←
         eventually do
             return (← Editor.Ffi.waiting .editor) == 1 && (← Editor.Ffi.waiting .completion) == 1
       Editor.Ffi.quit
       let returned ←
         eventually do
             return (← IO.hasFinished editor) && (← IO.hasFinished completion)
       unless parked && returned do
         return false
       let woken := [← IO.ofExcept editor.get, ← IO.ofExcept completion.get]
       return woken.all (·.kind == .quit) },
    { name := "after quit every pull returns a quit event at once"
      run := do
        let pulled := [← pull .editor, ← pull .completion, ← pull .editor]
        return pulled.all fun event => (event.map (·.kind)) == some .quit },
    { name := "after quit a post is refused"
      run := return !(← Editor.Ffi.postEvent .editor 1 1 "after quit") }]

/-- Parks a dedicated task in a pull that nothing will ever wake. `true` once
it is parked. -/
def blockForGood : IO Bool := do
  discard <| IO.asTask (prio := .dedicated) (Editor.Ffi.nextEvent .editor)
  eventually (return (← Editor.Ffi.waiting .editor) == 1)

/-- Prints a line of the overflow scenario and flushes it: the process is
about to abort, and an abort does not flush. -/
def say (line : String) : IO Unit := do
  IO.println s!"ffi-test overflow: {line}"
  (← IO.getStdout).flush

/-- What the overflow scenario says just before it recurses. The
`ffi-overflow` task in `mise.toml` requires this to be the last line of
stdout. -/
def overflowMarker : String :=
  "entering the recursion"

/-- The overflow scenario; see `overflow`. It is `unsafe` because evaluating a
constant from an environment trusts the type it is given. -/
unsafe def overflowUnsafe (sysroot oleanDir : String) : IO UInt8 := do
  try
    Lean.initSearchPath ⟨sysroot⟩ [⟨oleanDir⟩]
    let env ← Lean.importModules #[{ module := `InterpretedFixture }] {}
    let shallow ← IO.ofExcept (env.evalConst (IO Nat) {} `InterpretedFixture.shallow)
    let tooDeep ← IO.ofExcept (env.evalConst (IO Nat) {} `InterpretedFixture.tooDeep)
    unless (← shallow) == 10 do
      say "the interpreter did not run the fixture's shallow recursion"
      return 1
    say overflowMarker
    let depth ← tooDeep
    say s!"the recursion returned {depth}, and the process is still running"
    return 1
  catch error =>
    say s!"Lean caught an error: {error}"
    return 1

/-- Has Lean's interpreter run a recursion that overflows its stack, on this
thread, inside a Lean `try`/`catch`. The interpreter's stack check throws a
C++ exception, which the Lean handler does not see and nothing else catches,
and the process dies of SIGABRT: that is the outcome the scenario exists to
show. So this returns only when something is wrong, with the exit status 1.

Before it recurses it has the interpreter run a shallow recursion from the
same module and checks the value, then prints the marker line. The marker is
therefore the last line of stdout exactly when the process died in the deep
recursion and nowhere earlier.

`sysroot` is the Lean toolchain's directory and `oleanDir` the directory
holding `InterpretedFixture.olean`. -/
@[implemented_by overflowUnsafe]
opaque overflow (sysroot oleanDir : String) : IO UInt8

/-- Runs `checks`, names on stderr the ones that failed, and returns the exit
status: 0 when all hold, 1 otherwise. `scenario` names the run in the line
printed on success. -/
def run (scenario : String) (checks : List Check) : IO UInt8 := do
  let failed ← failures checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    return 1
  IO.println s!"{scenario}: {checks.length} checks passed"
  return 0

/-- Reports a command line `main` does not understand; the exit status is 2. -/
def usage : IO UInt32 := do
  IO.eprintln
      "usage: ffi-test [exit <code> | shutdown | exit-while-blocked | overflow <sysroot> <olean dir> | display <fixture> | theme-pictures <dir> <font> [--write] | window-host [<file>] | window-host-undrawn <file>]"
  return 2

/-- The window mode's wiring (`Editor.Window.host`) on the library's
scripted platform, on the absolute path `file`, or with no file, on the
editor's one empty buffer, when it is `none`: a cells display bound to the
presenter, a clipboard of its own, no config, and the report asked for. The
sample window opens, reports its fixed input and asks to close, which ends
the host's loop and closes the window, and the report is printed to stderr.
0 when the window ran, the latest render session's counters, read once
`windowRun` has returned (the presenter's last handle), show a frame drawn,
and no surface said what it offered, and, with no file, the last title the
scripted window was asked to show is `scratch`; 1 otherwise, saying why on
stderr. The process starts no other render session, so the counters are this
run's. -/
def windowHostScenario (file : Option String) : IO UInt8 := do
  let options : Editor.Window.Options :=
    { file, config := none, configGiven := false, sysroot := none, oleans := ""
      composition := true, report := true }
  let status ←
    Editor.Window.host .scripted options (.skip none) (← Editor.Ffi.Display.newCells 8 16)
        (← Editor.Clipboard.InProcess.new).handle #[]
  unless status == 0 do
    IO.eprintln s!"ffi-test window-host: the window mode ended with status {status}"
    return 1
  let some counters ← Editor.Ffi.renderCounters |
    IO.eprintln "ffi-test window-host: no render session was started"
    return 1
  unless counters.draws > 0 do
    IO.eprintln "ffi-test window-host: no frame was drawn in the window"
    return 1
  -- The scripted platform draws with the recording renderer, which has no
  -- surface to say anything of.
  unless (← Editor.Ffi.windowPresentation) == none do
    IO.eprintln "ffi-test window-host: a scripted window said what a surface offered"
    return 1
  -- With no file the selected buffer is the one empty buffer, whose name is
  -- the window's title. With a file, its load may not finish before the
  -- sample asks to close, so the title is not looked at.
  if file.isNone then
    let titles :=
      ((← Editor.Ffi.windowAsked .scripted).getD #[]).filterMap fun
        | .title text => some text
        | .request _ => none
    unless titles.back? == some "scratch" do
      IO.eprintln
          s!"ffi-test window-host: the window was last asked for the title {titles.back?}, not scratch"
      return 1
  IO.println "ffi-test window-host: the window ran and closed, and frames were drawn in it"
  return 0

/-- The window mode's wiring (`Editor.Window.host`) on the library's
scripted platform whose renderer cannot be made, on the absolute path
`file`, as `windowHostScenario` sets it up but with no report. The sample
window opens, reports its fixed input and asks to close, as it does there,
and nothing draws in it. 0 when the window mode ended with status 1 and no
render session was started; 1 otherwise, saying why on stderr. What the
window mode prints of the failure is on stderr, for the gate to read. -/
def windowHostUndrawnScenario (file : String) : IO UInt8 := do
  let options : Editor.Window.Options :=
    { file := some file, config := none, configGiven := false, sysroot := none, oleans := ""
      composition := true }
  let status ←
    Editor.Window.host .scriptedUndrawn options (.skip none) (← Editor.Ffi.Display.newCells 8 16)
        (← Editor.Clipboard.InProcess.new).handle #[]
  unless status == 1 do
    IO.eprintln s!"ffi-test window-host-undrawn: the window mode ended with status {status}, not 1"
    return 1
  if (← Editor.Ffi.renderCounters).isSome then
    IO.eprintln "ffi-test window-host-undrawn: a render session was started"
    return 1
  IO.println
      "ffi-test window-host-undrawn: the window ran with nothing drawing in it, and the window mode said so"
  return 0

end FfiTest

/-- With no arguments, runs the checks: exits 0 when all hold, and 1 after
naming the ones that do not.

With the arguments `exit <code>`, exits with that status and does nothing
else. The `ffi-test` task uses this to see that the entry point passes the
arguments to Lean's `main` and makes its result the process's exit status.

`shutdown` runs the shutdown sequence: tasks parked in a pull on each queue,
quit, then an explicit exit, with status 0 when every task came back with a
quit event.

`exit-while-blocked` parks a task in a pull, never quits, and exits
explicitly with status 0. It shows that the process ends although a dedicated
task is still blocked in the library, which returning from `main` would wait
for.

`overflow <sysroot> <olean dir>` has the interpreter run a recursion deeper
than its stack. Nothing catches the C++ exception the interpreter throws, so
the process dies of SIGABRT, and the `ffi-overflow` task requires exactly
that. Any exit status of its own means the scenario went wrong. -/
def main (args : List String) : IO UInt32 := do
  match args with
  | [] =>
    if (← FfiTest.run "ffi-test" (FfiTest.checks ())) == 0 then
      return 0
    else
      -- A failed check may have left a task parked in the library, and
      -- returning from `main` would wait for it for ever.
      IO.Process.exit 1
  | ["shutdown"] =>
    IO.Process.exit (← FfiTest.run "ffi-test shutdown" (FfiTest.shutdownChecks ()))
  | ["display", fixture] =>
    IO.Process.exit (← FfiTest.displayScenario fixture)
  | ["theme-pictures", dir, font] =>
    IO.Process.exit (← FfiTest.themePicturesScenario dir font false)
  | ["theme-pictures", dir, font, "--write"] =>
    IO.Process.exit (← FfiTest.themePicturesScenario dir font true)
  | ["window-host", file] =>
    let status ← FfiTest.windowHostScenario (some file)
    Editor.Ffi.quit
    IO.Process.exit status
  | ["window-host"] =>
    let status ← FfiTest.windowHostScenario none
    Editor.Ffi.quit
    IO.Process.exit status
  | ["window-host-undrawn", file] =>
    let status ← FfiTest.windowHostUndrawnScenario file
    Editor.Ffi.quit
    IO.Process.exit status
  | ["exit-while-blocked"] =>
    IO.Process.exit (if ← FfiTest.blockForGood then 0 else 1)
  | ["overflow", sysroot, oleanDir] =>
    IO.Process.exit (← FfiTest.overflow sysroot oleanDir)
  | ["exit", code] =>
    match code.toNat? with
    | some status =>
      return status.toUInt32
    | none =>
      FfiTest.usage
  | _ =>
    FfiTest.usage
