import Editor.Text.Model

/-!
# A command: append to a text

The first command, and the pattern later ones follow. A command is an
ordinary definition at `EditorM`, written in `do` notation over the port's
operations. It is one source: tests run it against the pure model
(`ModelTest.commandProperties`), and the `editor` executable runs the same
value against the real binding.

## A theorem about a command

A theorem about a command is stated about `EditorM.runModel`: what the command
returns and what model it leaves, for every model that meets the hypotheses.
`lake build` checks it, since `Editor.lean` imports this module.

The proof follows one pattern. Unfold the command, and let `simp` take it
apart with the port's lemmas (`Program.run_bind` under
`EditorM.runModel_bind`, and one lemma for each operation, in
`Editor/Text/Model.lean`). What is left is about the model alone: here, that
the text is there (`live`) and that a splice at the end of a text is an
append (`TextModel.splice_end`).

A theorem is symbolic. `rfl` and `decide` do not evaluate a run of the model
on concrete strings, so a concrete case is a test, in `ModelTest`.
-/

namespace Editor

/-- Appends `s` to the end of `text`: reads it, then inserts at its length in
bytes, which is the offset just past its last character. -/
def append (text : TextId) (s : String) : EditorM Unit := do
  let old ← text.read
  text.insert old.utf8ByteSize s

/-- `append` on a text that holds `contents` succeeds, leaves that text
holding `contents ++ s`, and changes no other text. -/
theorem append_spec (model : TextModel) (id : TextId) (contents s : String)
    (live : model.texts[id.index]? = some contents) :
    (append id s).runModel model =
      (.ok (), { model with texts := model.texts.setIfInBounds id.index (contents ++ s) }) := by
  simp [append, TextModel.handle, TextModel.edit, live, TextModel.splice_end]

end Editor
