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
          ((([3, 4, 5, 6, 7, 8] : List UInt64).map Editor.Ffi.EventKind.ofTag?) ==
              [some .windowOpened, some .windowFocus, some .key, some .composition,
                some .pointerPressed, some .closeRequested] &&
            Editor.Ffi.SourceKind.ofTag? 3 == some .window) },
    { name := "a tag the bindings do not know is refused"
      run :=
        pure ((Editor.Ffi.EventKind.ofTag? 9).isNone && (Editor.Ffi.SourceKind.ofTag? 4).isNone) }]

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
        return true }]

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

/-- The checks of a snapshot (`Editor.Ffi.Snapshot`): a handle made by a call
on another handle, whose bindings hand back a structure of numbers and take
an enumeration. What a row and a point are is the library's rule; these pin
that the values cross. -/
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

/-- The largest number a word holds, which no text accepts as a length or an
offset. -/
def largestWord : UInt64 :=
  0xFFFF_FFFF_FFFF_FFFF

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

/-- What the library's scripted platform reports of its window, as the kind,
the code and the text of each event: that it opened, with the platform's
name; the focus gained; `a` pressed and released; a dead key pressed; `é`
pressed; then, when composition is allowed, a composition enabled, its
preedit and its commit; a pointer press; and a request to close. -/
def windowSample (composition : Bool) : List (Editor.Ffi.EventKind × UInt64 × String) :=
  [(.windowOpened, 0, "scripted"), (.windowFocus, 1, ""), (.key, 1, "a"), (.key, 0, ""),
      (.key, 5, ""), (.key, 1, "é")] ++
    (if composition then [(.composition, 0, ""), (.composition, 1, "´"), (.composition, 2, "é")]
    else []) ++
    [(.pointerPressed, 0, ""), (.closeRequested, 0, "")]

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
    events.map (fun event => (event.kind, event.code, event.text)) == windowSample composition

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
          (decoded .pointerPressed 0 == .pointerPressed &&
            decoded .closeRequested 0 == .closeRequested) },
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

/-- Every check, in the order they run. -/
def checks (_ : Unit) : List Check :=
  entryChecks () ++ handleChecks () ++ dataChecks () ++ queueChecks () ++ timerChecks () ++
    documentChecks () ++
    snapshotChecks () ++
    transactionChecks () ++
    markerChecks () ++
    windowChecks () ++
    decodeChecks ()

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
