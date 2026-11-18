import Editor.Ffi.Document
import Editor.Ffi.Pair
import Editor.Ffi.Snapshot
import Editor.Ffi.Text
import FfiTest.Check

/-!
# FFI tests: `Editor/Ffi/Pair.lean`

The tests of `Editor/Ffi/Pair.lean`: `pairChecks`. The root module `FfiTest`
runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

/-- The checks of the two reads of a pair as they cross: each tag reaches the
kind it names, the three flags reach the walk, a string's two offsets come
back in order, and nothing found and a refusal are told apart. What the
walks answer is the library's rule, which the text contract pins on both
sides (`TextContract.pairProperties`). -/
def pairChecks (_ : Unit) : List Check :=
  [{  name := "each bracket's tag reaches its kind, and the flags reach the walk"
      run := do
        let document ← Editor.Ffi.Document.new "([{a}]) \\(b\\)"
        let snapshot ← document.snapshot
        let quoted ← (← Editor.Ffi.Document.new "(a \")\" b)").snapshot
        return (← snapshot.unmatched .round false true false false 0) == some (some 6) &&
            (← snapshot.unmatched .square false true false false 1) == some (some 5) &&
            (← snapshot.unmatched .curly true false false false 4) == some (some 2) &&
            (← snapshot.unmatched .round true true false false 1) == some none &&
            (← snapshot.unmatched .round false true true false 9) == some (some 12) &&
            (← snapshot.unmatched .round false true false false 99) == none &&
            (← quoted.unmatched .round false true false false 0) == some (some 4) &&
            (← quoted.unmatched .round false true false true 0) == some (some 8) },
    { name := "each quote's tag reaches its kind, and a string comes back as its two offsets"
      run := do
        let document ← Editor.Ffi.Document.new "\"a\" 'b' `c`"
        let snapshot ← document.snapshot
        return (← snapshot.quoted .double 1) == some (some ⟨0, 3⟩) &&
            (← snapshot.quoted .single 5) == some (some ⟨4, 7⟩) &&
            (← snapshot.quoted .back 9) == some (some ⟨8, 11⟩) &&
            (← snapshot.quoted .double 9) == some none &&
            (← snapshot.quoted .double 99) == none }]

end FfiTest
