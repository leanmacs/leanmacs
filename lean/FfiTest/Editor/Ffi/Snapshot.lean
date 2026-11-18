import Editor.Ffi.Document
import Editor.Ffi.Snapshot
import FfiTest.Check
import FfiTest.Support.Texts

/-!
# FFI tests: `Editor/Ffi/Snapshot.lean`

The tests of `Editor/Ffi/Snapshot.lean`: `snapshotChecks`. The root module
`FfiTest` runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

/-- Takes a snapshot of `document`, reads it and drops it. Only plain data
leaves: the text the snapshot held. -/
def useSnapshot (document : Editor.Ffi.Document) : IO String := do
  let snapshot ← document.snapshot
  snapshot.read

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
        return edited == .done && (← snapshot.read) == rows && (← document.read) == "Jéllo\r\nwörld\n😀x" },
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

end FfiTest
