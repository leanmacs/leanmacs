import Editor.Restore.Indexed
import Editor.Text.Model
import ModelTest.Check

/-!
# Model tests: `Editor/Restore/Indexed.lean`

The model tests of `Editor/Restore/Indexed.lean`: `restoreOffsetChecks`, on
the text model. Which buffers are indexed and journalled, and a window's
jump list recorded, are pinned end to end by `ModelTest.journalReconcileChecks`
and `ModelTest.restoreChecks`. The root module `ModelTest` runs them; its
module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Restore

namespace RestoreIndexedTest

/-- The offset `Restore.offsetOf` puts `spot` at in a text holding
`content`, on the text model. -/
def offsetIn (content : String) (spot : Spot) : Option Nat :=
  let program : TextM Nat := do
    let text ← createText content
    Restore.offsetOf text spot
  (program.runModel {}).1.toOption

end RestoreIndexedTest

open RestoreIndexedTest in
/-- The checks of where a recorded spot is put back (`Restore.offsetOf`,
`Editor/Restore/Indexed.lean`), on the text model: a spot's column is in
bytes. -/
def restoreOffsetChecks : List Check :=
  [{  name := "a spot's byte column after a multi-byte character is that byte of its row"
      run := pure (offsetIn "é xy\nab" ⟨0, 3⟩ == some 3 && offsetIn "ab\né xy" ⟨1, 3⟩ == some 6) },
    { name := "a column past the row's content is clamped to its end, before the line break"
      run := pure (offsetIn "é x\nab" ⟨0, 99⟩ == some 4) },
    { name := "a column inside a multi-byte character is moved back to its start"
      run := pure (offsetIn "aé\n" ⟨0, 2⟩ == some 1 && offsetIn "éa\n" ⟨0, 1⟩ == some 0) },
    { name := "a row past the last is the last row"
      run := pure (offsetIn "é x\nab" ⟨7, 1⟩ == some 6) }]

end ModelTest
