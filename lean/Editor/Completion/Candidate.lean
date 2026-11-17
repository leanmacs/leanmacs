import Editor.Scene

/-!
# A completion candidate, and the query a source is asked

The plain data of completion (`Editor/Completion.lean`): what a source is
asked (`Query`) and what it answers (`Candidate`). It is apart from the
source itself, which is a program over the editor's port, because the
editor state holds candidates (`Editor/State.lean`, "Prompts") and holds
no program.

- **A candidate** is the text accepting it gives, with what a display may
  show beside it: a label shown in its place, an annotation, a kind and a
  group, each optional. Only the text is read today: the label, the
  annotation, the kind and the group are carried and not drawn
  (`docs/design/keymaps-and-modes.md`, "A prompt's sources").
- **A query** is the text typed so far and the view the prompt was asked
  from. What is added to it is a field here, never a new type.
-/

namespace Editor.Completion

/-- What a source answers: one thing the answer may be chosen from. -/
structure Candidate where
  /-- What accepting it gives: the prompt's answer when it is chosen. -/
  text : String
  /-- What a display shows in its place; `none` for its text. -/
  label : Option String := none
  /-- A note a display shows beside it. -/
  annotation : Option String := none
  /-- What it is, as a word the source chooses. -/
  kind : Option String := none
  /-- The group it is listed under; `none` takes its source's name when a
  prompt asks (`Candidate.inGroup`, `Editor/Completion.lean`). -/
  group : Option String := none
  deriving DecidableEq, Repr

/-- The candidate of `text`, with nothing beside it. -/
def Candidate.ofText (text : String) : Candidate :=
  { text }

/-- What a source is asked. -/
structure Query where
  /-- The text typed so far. -/
  text : String
  /-- The view the prompt was asked from. -/
  view : ViewId
  deriving DecidableEq, Repr

end Editor.Completion
