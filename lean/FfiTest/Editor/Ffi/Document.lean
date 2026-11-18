import Editor.Ffi.Document
import Editor.Ffi.Excerpts
import FfiTest.Check

/-!
# FFI tests: `Editor/Ffi/Document.lean`

The tests of `Editor/Ffi/Document.lean`: `documentChecks`. The root module
`FfiTest` runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

/-- Makes a document holding `text`, appends "!" to it and drops it. Only
plain data leaves: the text it then held. -/
def useDocument (text : String) : IO String := do
  let document ← Editor.Ffi.Document.new text
  discard <| document.replace text.utf8ByteSize.toUSize text.utf8ByteSize.toUSize "!"
  document.read

/-- Makes an excerpt document of the first two bytes of `source`, reads it
and drops it. Only plain data leaves: the text it read. -/
def useExcerpts (source : Editor.Ffi.Document) : IO String := do
  let excerpts ← Editor.Ffi.Document.excerptsNew
  discard <| excerpts.excerptsSet #[source] #[(0, 0, 2)]
  excerpts.read

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
    { name := "a replace changes a document's text at its byte offsets and says it is done"
      run := do
        let document ← Editor.Ffi.Document.new "héllo wörld"
        -- The start and the stop differ, so swapping them is seen, and so
        -- is swapping either with the text's length.
        let replaced ← document.replace 7 13 "there!"
        let afterReplace ← document.read
        let inserted ← document.replace 3 3 "XY"
        let deleted ← document.replace 0 1 ""
        return replaced == .done && afterReplace == "héllo there!" && inserted == .done &&
            deleted == .done &&
            (← document.read) == "éXYllo there!" },
    { name := "a refused replace says badRange and leaves a document's text as it was"
      run := do
        let document ← Editor.Ffi.Document.new "héllo"
        let insideCharacter ← document.replace 2 2 "x"
        let backwards ← document.replace 3 1 "x"
        let pastEnd ← document.replace 7 7 "x"
        return [insideCharacter, backwards, pastEnd].all (· == .badRange) &&
            (← document.read) == "héllo" },
    { name := "a document is freed when Lean drops the last reference"
      run := do
        let before ← Editor.Ffi.Document.live
        let held ← Editor.Ffi.Document.new "held"
        let whileHeld ← Editor.Ffi.Document.live
        discard <| useDocument "dropped"
        let afterDrop ← Editor.Ffi.Document.live
        -- `held` is used here, so it is alive until now.
        return whileHeld == before + 1 && afterDrop == before + 1 && (← held.read) == "held" },
    { name :=
        "an excerpt document is one more live document, reads its source's range, and is freed when Lean drops the last reference"
      run := do
        let source ← Editor.Ffi.Document.new "held"
        let before ← Editor.Ffi.Document.live
        let excerpts ← Editor.Ffi.Document.excerptsNew
        let whileHeld ← Editor.Ffi.Document.live
        let set ← excerpts.excerptsSet #[source] #[(0, 1, 3)]
        let read ← useExcerpts source
        let afterDrop ← Editor.Ffi.Document.live
        -- `excerpts` is used here, so it is alive until now.
        return whileHeld == before + 1 && afterDrop == before + 1 && set matches .ok () &&
            read == "he" &&
            (← excerpts.read) == "el" &&
            (← excerpts.isExcerpts) &&
            !(← source.isExcerpts) }]

end FfiTest
