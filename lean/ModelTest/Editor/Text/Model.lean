import Editor.Program
import Editor.Text
import Editor.Text.Model
import ModelTest.Check

/-!
# Model tests: `Editor/Text/Model.lean`

The model tests of `Editor/Text/Model.lean`: `textModelStepChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- Whether every live text of `model` is in step (`TextModel.InStep`) at
the revision it is at. -/
def allInStep (model : TextModel) : Bool :=
  (List.range model.texts.size).all fun index =>
    match model.texts[index]? with
    | some (some content) => decide (model.InStep ⟨index⟩ content.revision)
    | _ => true

/-- The check of the premise the theorems about undo take of the text model
(`TextModel.InStep`), for the requests no lemma covers. -/
def textModelStepChecks : List Check :=
  [{  name :=
        "every live text of the text model is in step after each request of a sequence, each of which is accepted: a text made, an insertion, a deletion, a transaction with selections, an applied inverse, a drop of inverses, a forgotten revision, a marker, a copy, and the release of another text; and a model whose log is short a revision is not in step"
      run :=
        pure <|
          let text : TextId := ⟨0⟩
          let steps : List (TextM Unit) :=
            [discard <| createText "héllo", text.insert 6 " wörld", text.delete 0 1,
              discard <|
                text.apply
                  { Transaction.replacing 12 0 0 "X" with
                    before := some { ranges := #[⟨0, 0⟩] }, after := some { ranges := #[⟨1, 1⟩] } }
                  Origin.user,
              discard <| text.applyInverse 3 3 Origin.user, text.dropInverses 1 2, text.forget 1,
              discard <| text.mark (.anchor { offset := 0, bias := .before }), discard <| text.copy,
              discard <| createText "other", (⟨2⟩ : TextId).release]
          let (held, model) :=
            steps.foldl
              (fun (held, model) step =>
                let (result, model) := step.runModel model
                (held && result.isOk && allInStep model, model))
              (true, ({} : TextModel))
          held && model.texts.size == 3 &&
            !allInStep { model with logs := model.logs.map fun log => { log with past := #[] } } }]

end ModelTest
