import Editor.Ffi.Document
import Editor.Ffi.Marker
import Editor.Ffi.Snapshot
import Editor.Ffi.Text
import Editor.Ffi.Transaction
import FfiTest.Check
import FfiTest.Support.Texts

/-!
# FFI tests: `Editor/Ffi/Marker.lean`

The tests of `Editor/Ffi/Marker.lean`: `markerChecks`. The root module `FfiTest`
runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

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

end FfiTest
