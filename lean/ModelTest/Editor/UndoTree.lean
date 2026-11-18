import Editor.Text
import Editor.UndoTree
import ModelTest.Check

/-!
# Model tests: `Editor/UndoTree.lean`

The model tests of `Editor/UndoTree.lean`: `undoTreeChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the undo tree's pure operations alone, which ask nothing of
a text: being told a revision, and the boundary. What the tree does to a
text is in `UndoTreeCases.cases`, run against the text model below. -/
def undoTreeChecks : List Check :=
  [{
      name :=
        "an undo tree told a revision has it in its open group, and told one that is not after the last it knew it is unchanged",
      run := do
        let tree := UndoTree.new ⟨0⟩ 3
        let told := tree.record 5
        return !tree.pending && told.pending && told.head == 5 && told.base == 3 &&
            told.record 5 == told &&
            told.record 4 == told &&
            tree.record 3 == tree &&
            tree.record 0 == tree },
    { name :=
        "a boundary with nothing pending makes no node, and with something pending makes one whose parent is where the text was"
      run := do
        let tree := UndoTree.new ⟨0⟩ 3
        let closed := (tree.record 5).close
        let made : UndoTree.NodeId := ⟨1⟩
        return tree.close == tree && closed.nodes.size == 2 && closed.current == made &&
            !closed.pending &&
            closed.node? made ==
              some { parent := some UndoTree.root, cross := some ⟨4, 5⟩, state := ⟨5⟩ } &&
            closed.node? UndoTree.root ==
              some { parent := none, children := #[made], next := some made, state := ⟨3⟩ } &&
            closed.close == closed },
    { name :=
        "an undo tree nobody edited is saved where it is; told an edit it is modified; marked saved it is not, there or at a state named to it; and the state it is in is named by the revision that put it there: the one the tree was made at, or the one it was told"
      run := do
        let tree := UndoTree.new ⟨0⟩ 3
        let told := tree.record 5
        let elsewhere : UndoTree.State := ⟨4⟩
        return !tree.isModified && tree.state == ⟨3⟩ && told.isModified && told.state == ⟨5⟩ &&
            !told.markSaved.isModified &&
            !(told.markSaved told.state).isModified &&
            (tree.markSaved told.state).isModified &&
            (told.markSaved elsewhere).isModified &&
            (told.markSaved.record 6).isModified &&
            !(tree.markSaved.markSaved).isModified },
    { name :=
        "a boundary does not change whether an undo tree is modified: saved where the text is, the saved state is the state of the new node; saved anywhere else, it stays, and is no node's"
      run := do
        let told := (UndoTree.new ⟨0⟩ 3).record 5
        let closed := told.markSaved.close
        let behind := told.markSaved.record 6
        return told.isModified && told.close.isModified && !told.markSaved.isModified &&
            !closed.isModified &&
            closed.saved == some told.state &&
            (closed.node? closed.current).map (·.state) == some told.state &&
            behind.isModified &&
            behind.close.isModified &&
            behind.close.saved == some told.state &&
            behind.close.nodes.all (·.state != told.state) },
    { name :=
        "a state has one name, whether or not a boundary has been set since it was taken: the state taken at the end of an open group is the state of the node a boundary makes of it, so a tree marked saved at it after the boundary is unmodified, and one that was told a further edit before the boundary is not"
      run := do
        let told := (UndoTree.new ⟨0⟩ 3).record 5
        let taken := told.state
        let closed := told.close
        let further := (told.record 6).close
        return closed.state == taken && !(closed.markSaved taken).isModified &&
            further.state != taken &&
            (further.markSaved taken).isModified }]

end ModelTest
