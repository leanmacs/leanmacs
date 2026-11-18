import ContractTest.Check
import ContractTest.Support.Displays
import Editor.Display
import Editor.Display.Recorder
import Editor.Scene
import Editor.Text
import Editor.Text.Real

/-!
# Contract tests: `Editor/Display/Recorder.lean`

The tests of `Editor/Display/Recorder.lean`: `recorderChecks`, what only the
recorder shows. The root module `ContractTest` runs them; its module doc says
what each shows.
-/

namespace ContractTest

open Editor

/-- What only the recorder shows: what it keeps of a publish, and that it
reads the table it was given as the table is when it is asked. -/
def recorderChecks : List Check :=
  [{  name :=
        "the recorder has no scene before a publish, and the scene published after one, counted"
      run := do
        let (recorder, _, _) ← recorderOver { advance := 1, lineHeight := 1 } #[]
        let before ← recorder.last?
        let published ← (Display.publish emptyScene).runWith recorder.handle
        return before.isNone && published matches .ok () && (← recorder.last?) == some emptyScene &&
            (← recorder.published) == 1 },
    { name :=
        "a query of a snapshot released from the table the recorder reads is refused with noSuchSnapshot"
      run := do
        let (recorder, table, snapshots) ← recorderOver { advance := 1, lineHeight := 1 } #["ab"]
        let snapshot := snapshots[0]?.getD ⟨0⟩
        let query : Display.RowsQuery := { snapshot, width := 4, height := 1, anchor := 0 }
        let before ← (Display.rowsShown query).runWith recorder.handle
        discard <| table.release snapshot
        let after ← (Display.rowsShown query).runWith recorder.handle
        return (match before with
            | .ok rows => rows == #[⟨0, 2⟩]
            | .error _ => false) &&
            match after with
            | .error .noSuchSnapshot => true
            | _ => false }]

end ContractTest
