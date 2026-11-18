import Editor.Ffi.Fuzzy
import FfiTest.Check

/-!
# FFI tests: `Editor/Ffi/Fuzzy.lean`

The tests of `Editor/Ffi/Fuzzy.lean`: `fuzzyChecks`. The root module `FfiTest`
runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

/-- The checks of the fuzzy ranking's binding: a pattern and a list of
strings in, as words and one string, and the indices of the candidates the
pattern matches out, as words. Which candidates match and in what order are
the library's rules; these pin that the pattern, the candidates and the
answer cross. The first case is one the library's rules fix whatever a
matcher's scores: of `wq`, `edit` and `w` the pattern `w` matches the first
and the third, and the third is the pattern. -/
def fuzzyChecks (_ : Unit) : List Check :=
  [{ name := "a ranking crosses: the candidates a pattern matches, as their indices, best first",
     run := return (← Editor.Ffi.fuzzyRank "w" #["wq", "edit", "w"]) == #[2, 0] },
    { name :=
        "a candidate of two-byte characters between two of ASCII is cut where it ends: each is matched by a pattern of its own characters alone"
      run := do
        let candidates := #["ab", "éè", "cd"]
        return (← Editor.Ffi.fuzzyRank "b" candidates) == #[0] &&
            (← Editor.Ffi.fuzzyRank "éè" candidates) == #[1] &&
            (← Editor.Ffi.fuzzyRank "è" candidates) == #[1] &&
            (← Editor.Ffi.fuzzyRank "c" candidates) == #[2] &&
            (← Editor.Ffi.fuzzyRank "bé" candidates) == #[] },
    { name := "a pattern of two-byte characters crosses whole",
      run := return (← Editor.Ffi.fuzzyRank "日本" #["日x本", "日", "本日"]) == #[0] },
    { name := "an empty candidate crosses as a candidate, and an empty list as no candidates"
      run := do
        return (← Editor.Ffi.fuzzyRank "x" #["", "x", ""]) == #[1] &&
            (← Editor.Ffi.fuzzyRank "x" #[]) == #[] &&
            (← Editor.Ffi.fuzzyRank "" #[]) == #[] },
    { name := "the empty pattern answers every index, each once"
      run := do
        let ranked ← Editor.Ffi.fuzzyRank "" #["b", "", "a", "b"]
        return ranked.qsort (· < ·) == #[0, 1, 2, 3] },
    { name := "ten thousand candidates cross, and every index answered is one of theirs"
      run := do
        let candidates := (Array.range 10000).map fun index => s!"candidate-{index}"
        let ranked ← Editor.Ffi.fuzzyRank "date-99" candidates
        -- `candidate-99`, `candidate-199`, `candidate-990` and their like.
        return ranked.contains 99 && ranked.contains 9990 && !ranked.contains 98 &&
            ranked.all (· < 10000) &&
            (← Editor.Ffi.fuzzyRank "" candidates).size == 10000 }]

end FfiTest
