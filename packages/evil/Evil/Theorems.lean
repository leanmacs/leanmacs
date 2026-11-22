import Editor.Api
import Editor.UndoTree.Theorems

/-!
# Theorems about evil

What is proved of evil's commands, on the text model. `lake build` checks
them, since `Editor.lean` imports this module.

## `x` then `u` restores the text

`Evil.deleteChar_undo`. What `x` and `u` are at the text port:

- **`x`** makes one edit, `TextId.replaceCarrying text extent "" before
  after`, for the extent of the cells it deletes (`Evil.deleteChar` is the
  operator `delete` over the motion `right`, `Evil/Operators.lean`),
  carrying the selection from before the command and the cursor it leaves.
- **`u`** is `BufferId.undo` (`Evil/Undo.lean`, `Editor/Api.lean`),
  which tells the buffer's tree the revision its text is at
  (`UndoTree.sync`) and undoes one step with the user's origin
  (`UndoTree.undo Origin.user`).

The commands' other requests place a marker and set a register, which
change no text. The dispatcher that answers a command's state requests is
`partial`, and no theorem is about it. So the statement is about these
three programs over the text port, as `replaceRange_insert_delete`
(`Editor/Api/Theorems.lean`) is about `TextId.replaceRange`.

In words: for every model in which the text holds `content`, every extent,
and every tree over that text that knew its revision and had nothing
pending, if the model accepts the deletion `x` makes, then the deletion
followed by one undo succeeds, the text holds exactly what it held, two
revisions on, and the selection handed back is the one from before the
deletion.

The hypotheses, and why each is there:

- **`accepted`**: when the store refuses the deletion, `x` did nothing and
  there is nothing to undo. The model accepts it whenever the extent is a
  range of the text and the two selections fit, which is what `x` builds;
  the checks of `x` run the same definitions on concrete texts
  (`EvilTest.evilRegisterChecks`, `EvilTest.evilUndoChecks`).
- **`over`, `told`, `settled`, `here`**: the tree is the text's, knows the
  text's revision, has no open group and is at one of its nodes. The loop
  leaves every buffer's tree so after each event in normal state.
- **`inStep`**: the model's log holds the text at every earlier revision,
  and its record of kept inverses has one slot a revision
  (`TextModel.InStep`, `Editor/Text/Model.lean`, which says where it comes
  from and what holds it).

It is `UndoTree.apply_undo` (`Editor/UndoTree/Theorems.lean`) for the
transaction `replaceCarrying` makes.

What is not proved: anything about the real binding, which the text
contract's inverse properties and the API's case for `replaceCarrying` hold
to the model.
-/

namespace Editor

/-- `x` then `u`, on the model: the deletion `x` makes, when the model
accepts it, and then one undo by the buffer's tree, which knew the text's
revision and had nothing pending, leave the text holding what it held, two
revisions on, and hand back the selection from before the deletion. -/
theorem Evil.deleteChar_undo (model : TextModel) (id : TextId) (content : TextContent)
    (extent : Extent) (before after : Selection) (revision : Nat) (tree : UndoTree)
    (node : UndoTree.Node) (live : model.texts[id.index]? = some (some content))
    (inStep : model.InStep id content.revision)
    (accepted :
      (model.apply id
            { Transaction.replacing content.contents.utf8ByteSize extent.start extent.stop "" with
              before := some before, after := some after }
            Origin.user).1 =
        .ok revision)
    (over : tree.text = id) (told : tree.head = content.revision)
    (settled : tree.base = content.revision) (here : tree.node? tree.current = some node) :
    ∃ moved final,
      ((do
                id.replaceCarrying extent "" before after
                let tree ← tree.sync
                tree.undo Origin.user : TextM (Option UndoTree.Moved)).runModel
            model) =
          (.ok (some moved), final) ∧
        final.texts[id.index]? =
          some (some { contents := content.contents, revision := content.revision + 2 }) ∧
        moved.selection = some (TextModel.normal before) := by
  obtain ⟨moved, final, ran, restored, selection⟩ :=
    UndoTree.apply_undo model id content _ Origin.user revision tree node live inStep accepted over
      told settled here
  refine ⟨moved, final, ?_, restored, selection⟩
  simp only [TextM.runModel_bind, TextM.runModel_apply] at ran
  simp only [TextId.replaceCarrying, TextM.runModel_bind, TextM.runModel_byteLength,
    TextM.runModel_apply, TextM.runModel_pure, TextModel.handle, TextModel.onSource,
    TextModel.onText, TextModel.lookup, live, TextModel.answer]
  generalize
    model.applyText id
      { Transaction.replacing content.contents.utf8ByteSize extent.start extent.stop "" with
        before := some before, after := some after }
      Origin.user =
    outcome at ran ⊢
  obtain ⟨_ | _, _⟩ := outcome
  · simp at ran
  · simpa using ran

end Editor
