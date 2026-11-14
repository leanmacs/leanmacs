import Editor.Event.Queue
import Editor.Ffi
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
because it ends in an abort. `mise run ffi-test` runs the checks and every
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
          ((([3, 4, 5, 6, 7, 8, 9] : List UInt64).map Editor.Ffi.EventKind.ofTag?) ==
              [some .windowOpened, some .windowFocus, some .key, some .composition, some .pointer,
                some .closeRequested, some .resize] &&
            Editor.Ffi.SourceKind.ofTag? 3 == some .window) },
    { name := "a tag the bindings do not know is refused"
      run :=
        pure ((Editor.Ffi.EventKind.ofTag? 10).isNone && (Editor.Ffi.SourceKind.ofTag? 4).isNone) }]

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
      (.resize, 0, "", #[800, 600, (2.0 : Float).toBits]), (.closeRequested, 0, "", #[])]

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
  result : Option (Except String Unit)

/-- Runs the scripted platform's window on a dedicated task, pulls as many
events from the editor queue as its sample has, closes the window and waits
for the run. It always closes the window, so a check that fails leaves no run
behind to hold the main-thread service. -/
def runScripted (composition : Bool) : IO WindowRun := do
  let run ← IO.asTask (prio := .dedicated) (Editor.Ffi.windowRun .scripted composition)
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
  Editor.Ffi.windowClose .scripted
  let result ←
    if ← eventually (IO.hasFinished run) then
      some <$> IO.ofExcept run.get
    else
      pure none
  return { events := events.toList, stamped, waited, result }

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

/-- What `windowRun` returns on `platform`; `none` if it does not return in
time, in which case the window is closed so that no run is left behind. -/
def runUntilReturn (platform : Editor.Ffi.Platform) : IO (Option (Except String Unit)) := do
  let run ← IO.asTask (prio := .dedicated) (Editor.Ffi.windowRun platform true)
  unless ← eventually (IO.hasFinished run) do
    Editor.Ffi.windowClose platform
    return none
  return some (← IO.ofExcept run.get)

/-- Whether `result` is a run that returned and failed for exactly `reason`. -/
def failedFor (reason : String) : Option (Except String Unit) → Bool
  | some (.error actual) => actual == reason
  | _ => false

/-- The checks of the window's bindings, on the library's scripted platforms:
nothing opens and no display is needed. A run blocks until the window is
closed, so each runs on a dedicated task, and the events are pulled on
dedicated tasks too. None of them quits the queues.

Three run the keyboard check's own loop over the bindings: what
`editor window-check` runs on the real window. The last three are on the
scripted platform that cannot open a window: the glue's path for a failure,
which the real platform takes only on a machine with no display. -/
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
    { name := "running a window returns only after the window is closed, and says that it ran"
      run := do
        let ran ← runScripted true
        return ran.waited && ran.result matches some (.ok ()) },
    { name :=
        "an input posted as a window would report it arrives on the editor queue as the window's event, stamped, and words that do not read as an input are refused and queue nothing"
      run := do
        let words := #[1024, 768, (1.5 : Float).toBits]
        let short ← Editor.Ffi.postInput .resize 0 "" #[1024, 768]
        let notWindow ← Editor.Ffi.postInput .message 0 "" #[]
        let posted ← Editor.Ffi.postInput .resize 0 "" words
        let some event ← pull .editor | return false
        return !short && !notWindow && posted && event.source == { kind := .window, id := 1 } &&
            event.kind == .resize &&
            event.code == 0 &&
            event.words == words &&
            event.stamp > 0 },
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
            status == 1 }]

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
    { name := "a resize decodes with its size and its scale, and a request to close to itself"
      run :=
        pure
          (decodedWindow .resize 0 #[800, 600, (2.0 : Float).toBits] ==
              some (.resize { width := 800, height := 600, scale := 2.0 }) &&
            decodedWindow .closeRequested 0 == some .closeRequested) },
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
        "a code the table does not have is refused: a focus of 2, a composition of 4, a key with a bit past the interrupt mark, a key with the mark that was not pressed, a pointer of 4, a resize of 1"
      run :=
        pure
          ((decodedWindow .windowFocus 2).isNone && (decodedWindow .composition 4).isNone &&
            (decodedWindow .key 16 #[0, 0, 0, 0, 0]).isNone &&
            (decodedWindow .key 17 #[0, 0, 0, 0, 0]).isNone &&
            (decodedWindow .key 8 #[0, 0, 0, 0, 0]).isNone &&
            (decodedWindow .pointer 4 (pointerWords 1 0 0)).isNone &&
            (decodedWindow .resize 1 #[1, 1, 0]).isNone) },
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
        "a window opened, a focus gained and lost, a key, each composition, each pointer action, a resize and a request to close posted as a window would come back from the library equal"
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
            .resize { width := 1920, height := 1080, scale := 1.25 }, .closeRequested]
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

/-- Every check, in the order they run. -/
def checks (_ : Unit) : List Check :=
  entryChecks () ++ handleChecks () ++ dataChecks () ++ queueChecks () ++ timerChecks () ++
    fileChecks () ++
    documentChecks () ++
    snapshotChecks () ++
    transactionChecks () ++
    markerChecks () ++
    inverseChecks () ++
    windowChecks () ++
    decodeChecks () ++
    eventDecodeChecks () ++
    eventChecks () ++
    interruptChecks ()

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
      "usage: ffi-test [exit <code> | shutdown | exit-while-blocked | overflow <sysroot> <olean dir>]"
  return 2

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
