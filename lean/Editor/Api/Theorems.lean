import Editor.Api
import Editor.Text.Model

/-!
# Theorems about the editor API

What is proved of the operations of `Editor/Api.lean`, on the text model.
They are here and not beside the operations, as `append_spec` is beside
`append` (`Editor/Command/Append.lean`, whose pattern the proofs follow), so
that the API itself imports no model: its cases (`Editor/Api/Cases.lean`)
are played on the model and on the real binding, and name neither.
`lake build` checks them, since `Editor.lean` imports this module.

## Inserting and deleting what was inserted

`replaceRange_insert_delete`: inserting a string at a character boundary of
a text and then deleting the range it occupies leaves the text's contents
as they were, two revisions on. `BufferId.insertAt` and
`BufferId.deleteRange` are `TextId.replaceRange` on the buffer's text, so
this is the statement for a buffer.

It is stated of the contents and not of the whole model: the model also
holds the text's edit log, its markers and what it keeps of its edits,
which the two edits add to, and those are theirs to say
(`Editor/Text/Model.lean`).

The steps:

- `TextModel.splice_append` (the model's): a splice over the middle of
  three parts replaces it. From it, `TextModel.splice_insert_delete`: the
  two splices give back the text.
- `TextModel.applyChanges_replacing`: what `Transaction.replacing` makes of
  a text is the splice of its range.
- `replaceRange_spec`: one `replaceRange` whose splice is accepted leaves
  the text holding the splice, at the next revision.
-/

namespace Editor

/-- `TextId.replaceRange` on a text that holds `content`, over a range whose
splice the model accepts as `made`: it succeeds, leaves that text holding
`made` at the next revision, and changes no other text and no snapshot. -/
theorem replaceRange_spec (model : TextModel) (id : TextId) (content : TextContent)
    (start stop : Nat) (s made : String) (live : model.texts[id.index]? = some (some content))
    (spliced : TextModel.splice content.contents start stop s = some made) :
    ((id.replaceRange start stop s).runModel model).1 = .ok () ∧
      ((id.replaceRange start stop s).runModel model).2.texts =
        model.texts.setIfInBounds id.index
          (some { contents := made, revision := content.revision + 1 }) ∧
      ((id.replaceRange start stop s).runModel model).2.snapshots = model.snapshots := by
  obtain ⟨startValid, stopValid, ordered⟩ := TextModel.splice_boundaries spliced
  have within : stop ≤ content.contents.utf8ByteSize := stopValid.le_utf8ByteSize
  have noBefore :
    (Transaction.replacing content.contents.utf8ByteSize start stop s).before = none := rfl
  have noAfter : (Transaction.replacing content.contents.utf8ByteSize start stop s).after = none :=
    rfl
  simp [TextId.replaceRange, TextModel.handle, noBefore, noAfter, TextModel.apply, TextModel.answer,
    TextModel.changed, TextModel.lookup, live, TextModel.isSelection, TextModel.selectionFits,
    TextModel.applyChanges_replacing _ _ _ _ startValid ordered within, spliced]

/-- Inserting `s` into a text at a character boundary and then deleting the
range it occupies, both with `TextId.replaceRange`, succeeds, leaves that
text holding what it held, two revisions on, and changes no other text and
no snapshot. -/
theorem replaceRange_insert_delete (model : TextModel) (id : TextId) (content : TextContent)
    (s : String) (position : Nat) (live : model.texts[id.index]? = some (some content))
    (boundary : (String.Pos.Raw.mk position).IsValid content.contents) :
    ((do
                id.replaceRange position position s
                id.replaceRange position (position + s.utf8ByteSize) "" : TextM Unit).runModel
            model).1 =
        .ok () ∧
      ((do
                id.replaceRange position position s
                id.replaceRange position (position + s.utf8ByteSize) "" : TextM Unit).runModel
            model).2.texts =
        model.texts.setIfInBounds id.index
          (some { contents := content.contents, revision := content.revision + 2 }) ∧
      ((do
                id.replaceRange position position s
                id.replaceRange position (position + s.utf8ByteSize) "" : TextM Unit).runModel
            model).2.snapshots =
        model.snapshots := by
  have both := TextModel.splice_insert_delete content.contents s position boundary
  cases inserted : TextModel.splice content.contents position position s with
  | none => simp [inserted] at both
  | some made =>
    simp only [inserted, Option.bind_some] at both
    obtain ⟨first, firstTexts, firstSnapshots⟩ :=
      replaceRange_spec model id content position position s made live inserted
    have inBounds : id.index < model.texts.size := by
      have found := live
      simp only [Array.getElem?_eq_some_iff] at found
      exact found.1
    have liveAfter :
      ((id.replaceRange position position s).runModel model).2.texts[id.index]? =
        some (some { contents := made, revision := content.revision + 1 }) := by
      rw [firstTexts]
      simp [inBounds]
    obtain ⟨second, secondTexts, secondSnapshots⟩ :=
      replaceRange_spec _ id _ position (position + s.utf8ByteSize) "" content.contents liveAfter
        both
    generalize ran : (id.replaceRange position position s).runModel model = outcome at *
    obtain ⟨result, after⟩ := outcome
    simp only at first firstTexts firstSnapshots
    subst first
    simp only [TextM.runModel_bind, ran, second, secondTexts, secondSnapshots, firstTexts,
      firstSnapshots, Array.setIfInBounds_setIfInBounds, true_and]

end Editor
