import Editor.Fold
import Editor.Test.Models
import ModelTest.Check

/-!
# Model tests: `Editor/Fold.lean`

The model tests of `Editor/Fold.lean`: `foldChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- A foldable range keyed `key` over the bytes `start` to `stop`. -/
def foldable (key : String) (start stop : Nat) (folded : Bool := true) : Foldable :=
  { start, stop, key, text := s!"[{key}]", folded }

/-- `range` covering the rows `first` to `last`. -/
def coveredAt (range : Foldable) (first last : Nat) : Fold.Covered :=
  (range, first, last)

/-- The keys of `covered`, in order. -/
def coveredKeys (covered : Array Fold.Covered) : Array String :=
  covered.map (·.1.key)

/-- Rows 2 to 4 folded (`a`) and rows 7 to 8 folded (`b`), of a text whose
last row is 9. -/
def twoFolds : Array Fold.Covered :=
  #[coveredAt (foldable "a" 4 10) 2 4, coveredAt (foldable "b" 14 17) 7 8]

/-- The checks of the pure functions over foldable ranges
(`Editor/Fold.lean`). -/
def foldChecks : List Check :=
  [{  name :=
        "declaring again keeps the toggled state of a surviving key in both directions, a new key takes its declared state, and a dropped key is gone"
      run :=
        pure <|
          let old := #[foldable "a" 0 2 false, foldable "b" 3 5 true, foldable "gone" 6 7 true]
          let declared :=
            #[foldable "b" 10 12 false, foldable "a" 8 9 true, foldable "new" 1 2 true]
          Fold.merge old declared ==
              #[foldable "b" 10 12 true, foldable "a" 8 9 false, foldable "new" 1 2 true] &&
            Fold.merge #[] declared == declared },
    { name :=
        "the shown folds are the folded ranges in order of start: of nested ones the outer, of two with one start the longer, and one whose first row a shown one covers is dropped, its later rows shown"
      run :=
        pure <|
          let outer := coveredAt (foldable "outer" 2 20) 1 5
          let inner := coveredAt (foldable "inner" 6 9) 2 3
          let unfolded := coveredAt (foldable "open" 0 1 false) 0 0
          let overlap := coveredAt (foldable "overlap" 15 30) 5 7
          let later := coveredAt (foldable "later" 31 33) 8 8
          let same := coveredAt (foldable "same" 2 4) 1 1
          coveredKeys (Fold.shown #[inner, outer, unfolded]) == #["outer"] &&
            coveredKeys (Fold.shown #[same, outer]) == #["outer"] &&
            coveredKeys (Fold.shown #[later, overlap, outer]) == #["outer", "later"] &&
            coveredKeys (Fold.shown #[unfolded]) == #[] },
    { name :=
        "a step counts a shown fold as one row: one step onto a fold lands on its first row, one more past it, counts cross two folds, and up mirrors this"
      run :=
        pure <|
          Fold.stepRows twoFolds 1 1 9 true == 2 && Fold.stepRows twoFolds 2 1 9 true == 5 &&
            Fold.stepRows twoFolds 3 1 9 true == 5 &&
            Fold.stepRows twoFolds 1 3 9 true == 6 &&
            Fold.stepRows twoFolds 1 4 9 true == 7 &&
            Fold.stepRows twoFolds 1 5 9 true == 9 &&
            Fold.stepRows twoFolds 5 1 9 false == 2 &&
            Fold.stepRows twoFolds 9 1 9 false == 7 &&
            Fold.stepRows twoFolds 9 4 9 false == 2 &&
            Fold.stepRows twoFolds 4 0 9 true == 2 &&
            Fold.stepRows #[] 1 3 9 true == 4 },
    { name :=
        "a step stops at the last row and at 0, and a fold that reaches the last row is not stepped past"
      run :=
        pure <|
          let atEnd := #[coveredAt (foldable "end" 10 20) 3 5]
          Fold.stepRows atEnd 2 1 5 true == 3 && Fold.stepRows atEnd 3 1 5 true == 3 &&
            Fold.stepRows atEnd 4 2 5 true == 3 &&
            Fold.stepRows atEnd 2 9 5 true == 3 &&
            Fold.stepRows atEnd 1 9 5 false == 0 &&
            Fold.stepRows atEnd 5 1 5 false == 2 },
    { name :=
        "a toggle at a row unfolds the outermost folded range holding it, and with none folded folds the innermost; off every range it acts on none"
      run :=
        pure <|
          let outer (folded : Bool) := coveredAt (foldable "outer" 2 20 folded) 1 5
          let inner (folded : Bool) := coveredAt (foldable "inner" 6 9 folded) 2 3
          Fold.toggleTarget #[inner true, outer true] 2 == some ("outer", false) &&
            Fold.toggleTarget #[inner true, outer false] 2 == some ("inner", false) &&
            Fold.toggleTarget #[inner false, outer false] 2 == some ("inner", true) &&
            Fold.toggleTarget #[inner false, outer false] 4 == some ("outer", true) &&
            Fold.toggleTarget #[inner false, outer true] 4 == some ("outer", false) &&
            Fold.toggleTarget #[inner true, outer true] 7 == none },
    { name :=
        "the shown fold that holds a row, and the one a row starts, are found over the shown folds alone"
      run :=
        pure <|
          coveredKeys ((Fold.cover twoFolds 3).toArray) == #["a"] &&
            coveredKeys ((Fold.cover twoFolds 8).toArray) == #["b"] &&
            (Fold.cover twoFolds 5).isNone &&
            coveredKeys ((Fold.startsAt twoFolds 2).toArray) == #["a"] &&
            (Fold.startsAt twoFolds 3).isNone },
    { name :=
        "a range covers the rows that hold a byte of it, a line feed being the row's it ends, an empty range its start's row, and offsets past the end the last row"
      run :=
        pure <|
          let rows (folds : Array Foldable) : Option (Array (Nat × Nat)) :=
            onTextModel do
              let text ← createText "ab\ncd\nef\ngh"
              return (← Fold.coveredOf text folds).map (·.2)
          rows #[foldable "x" 3 6] == some #[(1, 1)] &&
            rows #[foldable "x" 3 7] == some #[(1, 2)] &&
            rows #[foldable "x" 4 4] == some #[(1, 1)] &&
            rows #[foldable "x" 9 40] == some #[(3, 3)] &&
            rows #[foldable "x" 40 50] == some #[(3, 3)] &&
            rows #[] == some #[] },
    { name :=
        "a range's rows are those of its bytes when an offset is inside a character: é is two bytes"
      run :=
        pure <|
          onTextModel
              (do
                let text ← createText "é\nab"
                return (← Fold.coveredOf text #[foldable "x" 1 2]).map (·.2)) ==
            some #[(0, 0)] },
    { name := "a foldable range's fold in the scene is its range and its placeholder"
      run :=
        pure <|
          let range : Foldable :=
            { start := 2, stop := 9, key := "k", text := "summary"
              decorations := #[{ start := 0, stop := 3, face := ⟨"fold.summary"⟩ }] }
          range.toFold ==
            { start := 2, stop := 9, text := "summary"
              decorations := #[{ start := 0, stop := 3, face := ⟨"fold.summary"⟩ }] } }]

end ModelTest
