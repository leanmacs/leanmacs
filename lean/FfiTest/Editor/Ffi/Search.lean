import Editor.Ffi.Document
import Editor.Ffi.Search
import Editor.Ffi.Snapshot
import Editor.Ffi.Text
import FfiTest.Check

/-!
# FFI tests: `Editor/Ffi/Search.lean`

The tests of `Editor/Ffi/Search.lean`: `searchChecks`. The root module `FfiTest`
runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

/-- The search of `text` for `pattern` from `offset`, forward when `forward`,
on a snapshot of a document the library holds. -/
def searched (text pattern : String) (forward : Bool := true) (offset : Nat := 0) :
    IO Editor.Ffi.SearchAnswer := do
  let document ← Editor.Ffi.Document.new text
  (← document.snapshot).search pattern forward offset.toUSize

/-- The matches of `pattern` in all of `text`, as offsets. -/
def matched (text pattern : String) : IO (Option (List (Nat × Nat))) := do
  let document ← Editor.Ffi.Document.new text
  match ← (← document.snapshot).matches pattern 0 text.utf8ByteSize.toUSize with
  | .ranges all =>
    return some (all.toList.map fun range => (range.start.toNat, range.stop.toNat))
  | _ =>
    return none

/-- What the library answers of the pattern syntax only it reads: the model
answers literal patterns alone (`Editor/Text/Model.lean`), so these are
checked on the real binding and nowhere else (`docs/design/rust-library.md`,
"Search, as built"). -/
def searchChecks (_ : Unit) : List Check :=
  [{  name := "a search crosses: the match, and whether it wrapped, both ways"
      run := do
        return (← searched "a foo foo" "foo") == .found ⟨2, 5⟩ false &&
            (← searched "a foo foo" "foo" true 6) == .found ⟨2, 5⟩ true &&
            (← searched "a foo foo" "foo" false 6) == .found ⟨2, 5⟩ false &&
            (← searched "abc" "x") == .notFound },
    { name := "`.` is any character but a line feed, and `*` repeats greedily"
      run := do
        return (← matched "a.b axb a\nb" "a.b") == some [(0, 3), (4, 7)] &&
            (← matched "baaac" "a*c") == some [(1, 5)] &&
            (← matched "x*y" "x\\*y") == some [(0, 3)] },
    { name := "a collection, negated or not, and a negated one never takes a line feed"
      run := do
        return (← matched "cat cot cut" "c[ao]t") == some [(0, 3), (4, 7)] &&
            (← matched "cat cot c\nt" "c[^a]t") == some [(4, 7)] },
    { name := "`\\|` is an alternative, the leftmost match winning"
      run := return (← matched "bar foo baz" "foo\\|bar") == some [(0, 3), (4, 7)] },
    { name := "`^` and `$` hold at each row's start and end"
      run := do
        return (← matched "ab\nab\nxab" "^ab") == some [(0, 2), (3, 5)] &&
            (← matched "ab\nab\nabx" "ab$") == some [(0, 2), (3, 5)] },
    { name := "a pattern of characters outside ASCII crosses whole, and its offsets are bytes"
      run := return (← searched "日本 日本語" "日本語") == .found ⟨7, 16⟩ false },
    { name :=
        "a pattern the syntax refuses is answered with Vim's sentence: `~` with E33, an unmatched `\\(` with E54"
      run := do
        return (← searched "abc" "a~") ==
              .invalid "E33: No previous substitute regular expression" &&
            (← searched "abc" "\\(a") == .invalid "E54: Unmatched \\(" },
    { name := "an offset that is not a position is refused, and a range that is not two in order"
      run := do
        let document ← Editor.Ffi.Document.new "héllo"
        let snapshot ← document.snapshot
        return (← snapshot.search "l" true 2) == .badPosition &&
            (← snapshot.matches "l" 3 1) == .badRange &&
            (← snapshot.matches "l" 0 99) == .badRange }]

end FfiTest
