import Editor.Ffi.Document
import Editor.Ffi.Log
import Editor.Ffi.Snapshot
import Editor.Ffi.Transaction
import FfiTest.Check
import FfiTest.Support.Texts

/-!
# FFI tests: `Editor/Ffi/Transaction.lean`

The tests of `Editor/Ffi/Transaction.lean`: `transactionChecks`, which also
check the edit log. The root module `FfiTest` runs them, and each list's own doc
says what it checks.
-/

namespace FfiTest

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

end FfiTest
