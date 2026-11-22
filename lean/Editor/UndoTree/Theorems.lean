import Editor.Text.Model
import Editor.UndoTree

/-!
# Theorems about the undo tree

What is proved of the undo tree (`Editor/UndoTree.lean`) on the text model.
They are here and not beside the tree, which imports the text port and no
model. `lake build` checks them, since `Editor.lean` imports this module
through `packages/evil/Evil/Theorems.lean`.

- `UndoTree.undo_pending`: one undo by a tree whose open group holds an
  edit, on a model that accepts that group's inverse, is made: the tree
  closes the group, crosses the edge back, and what the inverse left of the
  texts is what is left.
- `UndoTree.apply_undo`: any transaction the model accepts of a text in
  step (`TextModel.InStep`, `Editor/Text/Model.lean`), and then a tree that
  knew the text's revision and had nothing pending is told the new revision
  (`UndoTree.sync`) and undoes one step: the undo is made, the text holds
  what it held before the transaction, two revisions on, and the selection
  handed back is the one the transaction carried as the selection before
  it.

`Evil.deleteChar_undo` (`packages/evil/Evil/Theorems.lean`) is the second for the
transaction evil's `x` makes.

Nothing here is about the real binding: the text contract's inverse
properties and the undo tree's cases (`Editor/UndoTree/Cases.lean`), run
against the model and the binding, hold the two to each other.
-/

namespace Editor

/-- One undo by a tree whose open group holds an edit, on a model that
accepts the inverse of that group: the undo is made, what the inverse left
of the texts is what is left, and the selection handed back is the
inverse's. -/
theorem UndoTree.undo_pending (tree : UndoTree) (node : UndoTree.Node) (origin : Origin)
    (model after : TextModel) (inverted : Inverted) (content : TextContent)
    (pending : tree.base < tree.head) (here : tree.node? tree.current = some node)
    (inverse :
      model.applyInverse tree.text (tree.base + 1) tree.head origin = (.ok inverted, after))
    (liveAfter : after.texts[tree.text.index]? = some (some content))
    (reached : tree.head ≤ content.revision) :
    ∃ moved final,
      (tree.undo origin).runModel model = (.ok (some moved), final) ∧
        final.texts = after.texts ∧ moved.selection = inverted.selection := by
  have inNodes : tree.current.index < tree.nodes.size := by
    have found := here
    simp only [UndoTree.node?, Array.getElem?_eq_some_iff] at found
    exact found.1
  have notPast : ¬content.revision < tree.head := by omega
  have notNew : tree.current.index ≠ tree.nodes.size := Nat.ne_of_lt inNodes
  simp [UndoTree.undo, UndoTree.close, UndoTree.pending, pending, UndoTree.crossEdge,
    UndoTree.node?, Array.getElem?_push, Array.getElem_push, Array.size_modify, inNodes, inverse,
    TextModel.dropInverses, TextModel.onText, TextModel.lookup, liveAfter, notPast, notNew]
  exact ⟨_, _, ⟨rfl, rfl⟩, rfl, rfl⟩

/-- A transaction the model accepts, and then one undo by a tree that knew
the text's revision and had nothing pending: the undo is made, the text
holds what it held before the transaction, and the selection handed back is
the one the transaction carried as the selection before it. -/
theorem UndoTree.apply_undo (model : TextModel) (id : TextId) (content : TextContent)
    (transaction : Transaction) (origin : Origin) (revision : Nat) (tree : UndoTree)
    (node : UndoTree.Node) (live : model.texts[id.index]? = some (some content))
    (inStep : model.InStep id content.revision)
    (accepted : (model.apply id transaction origin).1 = .ok revision) (over : tree.text = id)
    (told : tree.head = content.revision) (settled : tree.base = content.revision)
    (here : tree.node? tree.current = some node) :
    ∃ moved after,
      ((do
                let _ ← id.apply transaction origin
                let tree ← tree.sync
                tree.undo Origin.user : TextM (Option UndoTree.Moved)).runModel
            model) =
          (.ok (some moved), after) ∧
        after.texts[id.index]? =
          some (some { contents := content.contents, revision := content.revision + 2 }) ∧
        moved.selection = transaction.before.map TextModel.normal := by
  obtain ⟨text, runs, applied⟩ :=
    TextModel.apply_accepted model id content transaction origin revision live accepted
  obtain ⟨undone, inverted, restored⟩ :=
    TextModel.apply_applyInverse model id content transaction origin Origin.user revision live
      inStep accepted
  rw [applied] at inverted
  have inTexts : id.index < model.texts.size := by
    have found := live
    simp only [Array.getElem?_eq_some_iff] at found
    exact found.1
  -- The tree once told the revision the transaction produced.
  let synced : UndoTree :=
    { tree with
      head := content.revision + 1, state := ⟨content.revision + 1⟩ }
  have pending : synced.base < synced.head := by simp [synced, settled]
  have hereSynced : synced.node? synced.current = some node := here
  have inverse :
    (model.changed id content text runs origin none
            (transaction.before.map TextModel.normal,
              transaction.after.map TextModel.normal)).applyInverse
        synced.text (synced.base + 1) synced.head Origin.user =
      (.ok ⟨content.revision + 2, transaction.before.map TextModel.normal⟩, undone) := by
    simpa [synced, over, settled] using inverted
  have liveAfter :
    undone.texts[synced.text.index]? =
      some (some { contents := content.contents, revision := content.revision + 2 }) := by
    simpa [synced, over] using restored
  obtain ⟨moved, final, ran, texts, selection⟩ :=
    UndoTree.undo_pending synced node Origin.user _ undone _ _ pending hereSynced inverse liveAfter
      (by simp [synced])
  refine ⟨moved, final, ?_, ?_, ?_⟩
  · simp [TextModel.applyText_plain _ _ _ _ _ live, applied, UndoTree.sync, UndoTree.record,
      TextModel.handle, TextModel.onSource, TextModel.onText, TextModel.lookup, TextModel.changed,
      TextModel.answer, inTexts, over, told]
    simpa [synced, TextModel.changed, over] using ran
  · rw [texts]
    exact restored
  · exact selection

end Editor
