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
- **What matching answers** (`Editor/Completion/Style.lean`): a `Hit`, the
  index of a candidate a style matched and the ranges of its text that
  matched (`Span`, byte offsets), and a `Listed`, a candidate as a
  prompt's listing holds it, with those ranges. The ranges travel with the
  candidate so a display can draw them; nothing draws them yet.
- **What a prompt's sources answered**: `Answer`, what one named source
  answered with its category and whether it filtered already, and
  `Collected`, what all of a prompt's sources answered together, as the
  state is handed it (`EditorState.setCandidates`): the candidates a style
  matches, those filtered sources passed through, and the prompt's
  category.
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

/-- A range of a candidate's text: UTF-8 byte offsets, `stop` excluded, as
a scene's decorations count them. -/
structure Span where
  /-- The offset of its first byte. -/
  start : Nat
  /-- The offset just past its last byte. -/
  stop : Nat
  deriving DecidableEq, Repr

/-- What a style answers for one candidate it matched: its index among the
candidates it was handed, and the ranges of its text that matched. -/
structure Hit where
  /-- The candidate's index. -/
  index : Nat
  /-- The ranges of its text that matched, ascending and apart. -/
  ranges : Array Span := #[]
  deriving DecidableEq, Repr

/-- The hit of the candidate at `index`, with no ranges. -/
def Hit.ofIndex (index : Nat) : Hit :=
  { index }

/-- A candidate as a prompt's listing holds it: the candidate, with the
ranges of its text that matched. -/
structure Listed where
  /-- The candidate. -/
  candidate : Candidate
  /-- The ranges of its text that matched; none for a candidate passed
  through unmatched. -/
  ranges : Array Span := #[]
  deriving DecidableEq, Repr

/-- `candidate` as a listing holds it, with `ranges`. -/
def Listed.of (candidate : Candidate) (ranges : Array Span := #[]) : Listed :=
  { candidate, ranges }

/-- The listed candidate's text: what accepting it gives. -/
def Listed.text (listed : Listed) : String :=
  listed.candidate.text

/-- What one named source answered a prompt: its category, whether it has
filtered for the query already, and its candidates. -/
structure Answer where
  /-- The source's category. -/
  category : String
  /-- Whether the source has filtered for the query already, so its
  candidates are listed in its order and not matched. -/
  filtered : Bool := false
  /-- What it answered. -/
  candidates : Array Candidate
  deriving DecidableEq, Repr

/-- What a prompt's sources answered, as the state is handed it: the
candidates a style matches, those filtered sources passed through, and
the prompt's category. -/
structure Collected where
  /-- The candidates a style matches, in the order they came in. -/
  all : Array Candidate := #[]
  /-- The candidates filtered sources answered, listed after the matches in
  the order they came in. -/
  passed : Array Candidate := #[]
  /-- The prompt's category: its first source's, or none. -/
  category : Option String := none
  deriving DecidableEq, Repr

end Editor.Completion
