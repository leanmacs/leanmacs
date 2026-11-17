import Editor.Text.Model

/-!
# A command: append to a text

The first command, and the pattern later ones follow. It is an ordinary
definition at `TextM`, the text port's programs, written in `do` notation
over the port's operations, and a command at `EditorM` uses it as it uses
any of them. It is one source: tests run it against the pure model
(`ModelTest.commandProperties`), and the `editor` executable runs the same
value against the real binding.

## A theorem about a command

A theorem about a command is stated about `TextM.runModel`: what the command
returns and what model it leaves, for every model that meets the hypotheses.
`lake build` checks it, since `Editor.lean` imports this module.

The proof follows one pattern. Unfold the command, and let `simp` take it
apart with the port's lemmas (`Program.run_bind` under
`TextM.runModel_bind`, and one lemma for each operation, in
`Editor/Text/Model.lean`). What is left is about the model alone: here, how
the model finds a text (`TextModel.lookup`), that the text is there (`live`)
and that a splice at the end of a text is an append
(`TextModel.splice_end`).

A theorem is symbolic. `rfl` and `decide` do not evaluate a run of the model
on concrete strings, so a concrete case is a test, in `ModelTest`.
-/

namespace Editor

/-- Appends `s` to the end of `text`: reads it, then inserts at its length in
bytes, which is the offset just past its last character. -/
def append (text : TextId) (s : String) : TextM Unit := do
  let old ← text.read
  text.insert old.utf8ByteSize s

/-- `append` on a text that holds `content` succeeds, leaves that text holding
`content.contents ++ s` at the next revision, and changes no other text and
no snapshot.

It is three facts, about the result, the texts and the snapshots, and not
one equation between models: the model also holds each text's edit log,
which the append adds an entry to, and what that entry is is the log's
business and not this command's. -/
theorem append_spec (model : TextModel) (id : TextId) (content : TextContent) (s : String)
    (live : model.texts[id.index]? = some (some content)) :
    ((append id s).runModel model).1 = .ok () ∧
      ((append id s).runModel model).2.texts =
        model.texts.setIfInBounds id.index
          (some { contents := content.contents ++ s, revision := content.revision + 1 }) ∧
      ((append id s).runModel model).2.snapshots = model.snapshots := by
  simp [append, TextModel.handle, TextModel.onText, TextModel.edit, TextModel.changed,
    TextModel.lookup, live, TextModel.splice_end]

end Editor
