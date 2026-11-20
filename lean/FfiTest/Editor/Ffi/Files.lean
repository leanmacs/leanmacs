import Editor.Ffi.Document
import Editor.Ffi.Events
import Editor.Ffi.Files
import Editor.Ffi.Snapshot
import Editor.Ffi.Timers
import FfiTest.Check
import FfiTest.Support.Files
import FfiTest.Support.Queues

/-!
# FFI tests: `Editor/Ffi/Files.lean`

The tests of `Editor/Ffi/Files.lean`: `fileChecks`. The root module `FfiTest`
runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

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
        "a stamp request's result decodes as four words: present or not, then the stamp, its seconds before 1970 negative"
      run :=
        let stamped (values : List UInt64) : Option (Option Editor.Ffi.FileStamp) :=
          match Editor.Ffi.FileResult.decode 0 none (wordBytes values) "" with
          | .ok (.stamped stamp) => some stamp
          | _ => none
        pure
          (stamped [1, 0xFFFFFFFFFFFFFFFF, 5, 9] ==
              some (some { seconds := -1, nanoseconds := 5, size := 9 }) &&
            stamped [0, 0, 0, 0] == some none) },
    { name :=
        "FileResult.decode reads a listing's words and names, and statuses 10 and 11, and refuses a length past the detail"
      run :=
        let listed (values : List UInt64) (detail : String) : Option (Array (String × UInt64)) :=
          match Editor.Ffi.FileResult.decode 11 none (wordBytes values) detail with
          | .ok (.listed entries) => some entries
          | _ => none
        pure
          (listed [3, 1, 5, 0, 9, 2, 4] "notescafé.txtfifo" ==
              some #[("notes", 1), ("café.txt", 0), ("fifo", 2)] &&
            listed [0] "" == some #[] &&
            decodedFile 10 [] == (none, some .notADirectory) &&
            -- A length past the detail's end, one that cuts a character,
            -- a detail longer than the names, a kind no one defined, and
            -- a count the words do not hold.
            listed [1, 0, 6] "notes" == none &&
            listed [1, 0, 4] "café" == none &&
            listed [1, 0, 4] "notes" == none &&
            listed [1, 3, 5] "notes" == none &&
            listed [2, 0, 5] "notes" == none) },
    { name :=
        "a directory is listed through the file service: its entries cross sorted by name, each with its kind, and a file is refused as not a directory"
      run :=
        inOwnDirectory fun directory => do
          IO.FS.createDirAll (directory / "sub")
          IO.FS.writeFile (directory / "b.txt") "b"
          IO.FS.writeFile (directory / "a.txt") "a"
          unless ← Editor.Ffi.filesList 1050 directory.toString do
            return false
          unless ← fileCompleted 1050 do
            return false
          let some (.listed entries) ← Editor.Ffi.filesTake 1050 | return false
          unless ← Editor.Ffi.filesList 1051 (directory / "a.txt").toString do
            return false
          unless ← fileCompleted 1051 do
            return false
          let refused := (← Editor.Ffi.filesTake 1051).bind refusalOf
          return entries == #[("a.txt", 0), ("b.txt", 0), ("sub", 1)] &&
              refused == some .notADirectory },
    { name :=
        "a directory is made through the file service, with the one on the way to it, and crosses as made; one where a file is is refused as not a directory"
      run :=
        inOwnDirectory fun directory => do
          IO.FS.writeFile (directory / "a.txt") "a"
          let deep := directory / "made" / "deep"
          unless ← Editor.Ffi.filesMakeDirectory 1052 deep.toString do
            return false
          unless ← fileCompleted 1052 do
            return false
          let some .made ← Editor.Ffi.filesTake 1052 | return false
          unless ← Editor.Ffi.filesMakeDirectory 1053 (directory / "a.txt" / "sub").toString do
            return false
          unless ← fileCompleted 1053 do
            return false
          let refused := (← Editor.Ffi.filesTake 1053).bind refusalOf
          let decoded := (Editor.Ffi.FileResult.decode 0 none (wordBytes []) "").toOption
          let madeDecoded :=
            match decoded with
            | some .made => true
            | _ => false
          return (← deep.isDir) && refused == some .notADirectory && madeDecoded },
    { name :=
        "an append through the file service makes the file and then extends it, a remove removes it and one of nothing is done, each crossing as made; an append into a directory that is not there is refused as not found"
      run :=
        inOwnDirectory fun directory => do
          let log := directory / "j.log"
          let done (id : UInt64) : IO Bool := do
            unless ← fileCompleted id do
              return false
            match ← Editor.Ffi.filesTake id with
            | some .made =>
              return true
            | _ =>
              return false
          unless ← Editor.Ffi.filesAppend 1060 log.toString "one\n".toUTF8 do
            return false
          let first ← done 1060
          unless ← Editor.Ffi.filesAppend 1061 log.toString mixedBytes do
            return false
          let second ← done 1061
          let held ← IO.FS.readBinFile log
          unless ← Editor.Ffi.filesRemove 1062 log.toString do
            return false
          let removed ← done 1062
          unless ← Editor.Ffi.filesRemove 1063 log.toString do
            return false
          let again ← done 1063
          unless ← Editor.Ffi.filesAppend 1064 (directory / "none" / "j.log").toString "x".toUTF8 do
            return false
          unless ← fileCompleted 1064 do
            return false
          let refused := (← Editor.Ffi.filesTake 1064).bind refusalOf
          return first && second && held == "one\n".toUTF8 ++ mixedBytes && removed && again &&
              !(← log.pathExists) &&
              refused == some .notFound },
    { name :=
        "unobserved appends, a save and a remove are worked in order and never completed; a failure is kept with its path and taken once; pending falls to 0"
      run :=
        inOwnDirectory fun directory => do
          let source := directory / "mixed.txt"
          IO.FS.writeBinFile source mixedBytes
          let some (.loaded snapshot _ _ _) ← loadResult 1070 source 1000 | return false
          let log := directory / "j.log"
          let base := directory / "j.base"
          let missing := directory / "none" / "j.log"
          let started :=
            [← Editor.Ffi.filesSaveUnobserved snapshot base.toString,
              ← Editor.Ffi.filesAppendUnobserved log.toString "a".toUTF8,
              ← Editor.Ffi.filesAppendUnobserved log.toString "b".toUTF8,
              ← Editor.Ffi.filesAppendUnobserved missing.toString "c".toUTF8,
              ← Editor.Ffi.filesRemoveUnobserved source.toString]
          let mut drained := false
          for _ in [0:5000] do
            if (← Editor.Ffi.filesPending) == 0 then
              drained := true
              break
            IO.sleep 1
          let failure ← Editor.Ffi.filesFailure
          let once := (← Editor.Ffi.filesFailure).isNone
          return once && started.all id && drained && (← IO.FS.readBinFile log) == "ab".toUTF8 &&
              (← IO.FS.readBinFile base) == mixedBytes &&
              !(← source.pathExists) &&
              (failure.map (·.1)) == some missing.toString },
    { name :=
        "a file result the bindings cannot read is an error: a status the table does not have, words that are not the status's, and a load with no snapshot"
      run :=
        pure
          (([(12, []), (0, [1, 2]), (0, [2, 0, 0, 0]), (0, [1, 2, 3, 4, 5]), (5, []), (6, [1]),
                  (7, [1, 2, 3]), (7, [2, 0, 0, 0]), (2, [1])].all
              fun ((status, values) : UInt64 × List UInt64) =>
              (Editor.Ffi.FileResult.decode status none (wordBytes values) "").toOption.isNone) &&
            (Editor.Ffi.FileResult.decode 0 none ⟨#[1, 2, 3]⟩ "").toOption.isNone) }]

end FfiTest
