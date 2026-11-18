import Editor.Completion.Candidate
import Editor.Completion.Style
import Editor.Fuzzy
import Editor.Fuzzy.Model
import Editor.Program

/-!
# Model tests: support: Completion

Candidates and completion styles written as data: a prompt's candidates from
their texts (`offered`) and the hits a style answers over the fuzzy model
(`styled`), with `ranked`, which runs a program over the fuzzy port against the
fuzzy model. Shared by several test modules under `ModelTest/Editor/`; it holds
no checks of its own.
-/

namespace ModelTest

open Editor

/-- Runs a program over the fuzzy port against the fuzzy model: its
value. The model has no state. -/
def ranked {α : Type} (program : FuzzyM α) : α :=
  (Program.run (port := fuzzyPort) FuzzyModel.handle program ()).1

/-- A candidate of each of `texts`, in order, with nothing beside it: how
the checks write a prompt's candidates. -/
def offered (texts : Array String) : Array Completion.Candidate :=
  texts.map Completion.Candidate.ofText

/-- The hits a style answers for `text` among `candidates`, run over the
fuzzy model. -/
def styled (style : Completion.Style) (text : String) (candidates : Array String) :
    Array Completion.Hit :=
  ranked (style.hits text candidates)

end ModelTest
