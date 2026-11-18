import Editor.Ffi.Document
import Editor.Ffi.Inverse
import Editor.Ffi.Log
import Editor.Ffi.Snapshot
import Editor.Ffi.Transaction
import FfiTest.Check
import FfiTest.Support.Texts

/-!
# FFI tests: `Editor/Ffi/Inverse.lean`

The tests of `Editor/Ffi/Inverse.lean`: `inverseChecks`. The root module
`FfiTest` runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

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

end FfiTest
