import Editor.Marks
import ModelTest.Check

/-!
# Model tests: `Editor/Marks.lean`

The model tests of `Editor/Marks.lean`: `markRuleChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The edit that replaced the bytes from `start` up to `stop` of the text
before, as a patch carries one. Of its points only the column `stop` is at
is read: `stopColumn`, 0 for an edit that stops at a row's start. -/
def markEdit (start stop : Nat) (inserted : Nat := 0) (stopColumn : Nat := 0) : Edit :=
  { old := { start, stop, startPoint := ⟨0, 0⟩, stopPoint := ⟨0, stopColumn⟩ }
    new := { start, stop := start + inserted, startPoint := ⟨0, 0⟩, stopPoint := ⟨0, 0⟩ } }

/-- The line of a mark held by marker 0 of text 0, from `start` up to `stop`. -/
def markLine (start stop : Nat) (last : Bool := false) : Marks.Line :=
  { marker := ⟨⟨0⟩, 0⟩, start, stop, last }

/-- A tree over text 0 with `nodes` nodes, each the child of the one before,
at the node `current`. -/
def markTree (nodes current : Nat) : UndoTree :=
  let made :=
    (List.range (nodes - 1)).foldl (fun tree revision => (tree.record (revision + 1)).close)
      (UndoTree.new ⟨0⟩ 0)
  { made with current := ⟨current⟩ }

/-- The marks `a` at row 1 and `b` at row 3, as a boundary keeps them. -/
def markBoundary : Array Marks.At :=
  #[{ char := 'a', row := 1, column := 2 }, { char := 'b', row := 3, column := 0 }]

/-- The checks of the rules of marks across edits and undo. -/
def markRuleChecks : List Check :=
  [{  name := "a deletion of a line with its line break removes the line"
      run :=
        return (markLine 4 8).removedBy (markEdit 4 8) && (markLine 4 8).removedBy (markEdit 0 12) &&
            (markLine 4 8).removedBy (markEdit 4 8 3) },
    { name := "a deletion that leaves the line break or a character of the line keeps the line"
      run :=
        return !(markLine 4 8).removedBy (markEdit 4 7) && !(markLine 4 8).removedBy (markEdit 5 8) &&
            !(markLine 4 8).removedBy (markEdit 0 6) && !(markLine 4 8).removedBy (markEdit 4 4 5) },
    { name :=
        "an edit from a row's start that stops inside a later row keeps the row, as the first line of a linewise change or a charwise delete is kept, and removes the rows after it it takes whole"
      run :=
        return !(markLine 0 2).removedBy (markEdit 0 5 (stopColumn := 1)) &&
            (markLine 2 4).removedBy (markEdit 0 5 (stopColumn := 1)) &&
            !(markLine 4 6).removedBy (markEdit 0 5 (stopColumn := 1)) &&
            (markLine 0 2).removedBy (markEdit 0 4) },
    { name := "the last row is removed only with the line break before it"
      run :=
        return (markLine 4 7 true).removedBy (markEdit 3 7) &&
            !(markLine 4 7 true).removedBy (markEdit 4 7) &&
            !(markLine 0 3 true).removedBy (markEdit 0 3) },
    { name := "a line is removed in a patch when one of its edits removes it"
      run :=
        return (markLine 4 8).removedIn { since := 0, revision := 1, edits := #[markEdit 0 1, markEdit 4 9] } &&
            !(markLine 4 8).removedIn { since := 0, revision := 1, edits := #[markEdit 0 1, markEdit 5 9] } },
    { name := "a node made since the history last looked keeps the marks at the last boundary"
      run :=
        let history : Marks.History := { boundary := markBoundary }
        let (restored, after) := history.follow (markTree 2 1)
        return restored.isEmpty && after.saved == #[(⟨1⟩, markBoundary)] && after.nodes == 2 &&
            after.current == ⟨1⟩ },
    { name := "an undo across a node puts back the marks it kept, and keeps the marks at the boundary for the redo"
      run :=
        let made : Marks.History := { boundary := markBoundary }
        let (_, history) := made.follow (markTree 2 1)
        let erased : Array Marks.At := #[{ char := 'b', row := 2, column := 0 }]
        let (restored, undone) := { history with boundary := erased }.follow (markTree 2 0)
        let (again, redone) := { undone with boundary := markBoundary }.follow (markTree 2 1)
        return restored == markBoundary && undone.saved == #[(⟨1⟩, erased)] && undone.current == ⟨0⟩ &&
            again == erased && redone.saved == #[(⟨1⟩, markBoundary)] },
    { name := "a move across more than one edge, or none, puts back nothing"
      run :=
        let made : Marks.History := { boundary := markBoundary, nodes := 3, current := ⟨2⟩ }
        let (far, moved) := made.follow (markTree 3 0)
        let (still, same) := made.follow (markTree 3 2)
        return far.isEmpty && moved.current == ⟨0⟩ && still.isEmpty && same == made },
    { name := "a tree with fewer nodes than the history saw is another tree: what was kept is dropped"
      run :=
        let made : Marks.History := { nodes := 3, current := ⟨2⟩, saved := #[(⟨1⟩, markBoundary)] }
        let (restored, after) := made.follow (markTree 1 0)
        return restored.isEmpty && after.saved.isEmpty && after.nodes == 1 }]

end ModelTest
