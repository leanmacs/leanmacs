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
  group, each optional. The label, the annotation and the group are drawn
  by the display (`Editor/Completion/Displays.lean`); the kind is carried
  and not drawn (`docs/design/keymaps-and-modes.md`, "A prompt's
  sources").
- **A query** is the text typed so far and the view the prompt was asked
  from. What is added to it is a field here, never a new type.
- **What matching answers** (`Editor/Completion/Style.lean`): a `Hit`, the
  index of a candidate a style matched and the ranges of its text that
  matched (`Span`, byte offsets), and a `Listed`, a candidate as a
  prompt's listing holds it, with those ranges. The ranges travel with the
  candidate so a display can draw them, and the minibuffer display does,
  in `minibuffer.match` (`Editor/Completion/Displays.lean`).
- **What a prompt's sources answered**: `Answer`, what one named source
  answered with its category and whether it filtered already, and
  `Collected`, what all of a prompt's sources answered together, as the
  state is handed it (`EditorState.setCandidates`): the candidates a style
  matches, those filtered sources passed through, and the prompt's
  category.
- **What a source that answers later is** (`Reask`, `Later`) and what an
  open prompt holds of it while it answers (`Asking`), and the match a
  worker runs for a long list (`InFlight`): plain data, since the state
  holds them (`Editor/Completion/Later.lean` has how they are used).
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
  prompt asks (`Candidate.inGroup`). -/
  group : Option String := none
  deriving DecidableEq, Repr

/-- The candidate of `text`, with nothing beside it. -/
def Candidate.ofText (text : String) : Candidate :=
  { text }

/-- `candidate` as a prompt holds it when the source `source` answered it:
in its own group, or, with none, in the source's. -/
def Candidate.inGroup (candidate : Candidate) (source : String) : Candidate :=
  { candidate with group := candidate.group <|> some source }

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

/-- When a source that answers later is asked again
(`Editor/Completion/Later.lean`). -/
inductive Reask where
  /-- Never: it answers the same for any text, so it is asked once, with the
  initial text, and what it answered is matched as the text changes. -/
  | never
  /-- Whenever the text it was asked with is not the typed text: it depends
  on the text. The previous job is cancelled, and the new one waits `pause`
  milliseconds before it asks. -/
  | afterPause (pause : Nat)
  deriving DecidableEq, Repr

/-- Whether a source that answers so, asked with `asked`, is asked again now
that `typed` is typed. -/
def Reask.asksAgain : Reask → (asked typed : String) → Bool
  | .never, _, _ => false
  | .afterPause _, asked, typed => asked != typed

/-- How long the job of a source that answers so waits before it asks, in
milliseconds, when it is asked again. -/
def Reask.pause : Reask → Nat
  | .never => 0
  | .afterPause pause => pause

/-- How a source answers later: the registered job that answers it, and when
it is asked again. -/
structure Later where
  /-- The name of the registered job that answers: started with the order
  (`Completion.Order`), it posts its candidates in batches. -/
  job : String
  /-- When it is asked again. -/
  reask : Reask := .never
  deriving DecidableEq, Repr

/-- What an open prompt holds of a source that answers later: which source
it is, what was asked, and what has come in. -/
structure Asking where
  /-- The source's name: its candidates' group. -/
  source : String
  /-- Whether it has filtered already: its candidates are then listed as
  given, after the matches. -/
  filtered : Bool := false
  /-- How it answers. -/
  later : Later
  /-- The text the current ask was made with. -/
  askedFor : String
  /-- The ask's generation: 0 before the first, and one more at each. A
  batch of another generation is a stale job's, and is dropped. -/
  generation : Nat := 0
  /-- What is listed of it: the batches its current generation delivered,
  or, until that generation's first, the previous one's. -/
  answered : Array Candidate := #[]
  /-- Whether the current generation has delivered a batch or ended. -/
  fresh : Bool := false
  /-- Whether the current generation's job has ended. -/
  done : Bool := false
  deriving DecidableEq, Repr

/-- The match a worker is running for an open prompt: the text and the
revision of the candidates it lists, and the config generation it was
spawned under. -/
structure InFlight where
  /-- The text it matches. -/
  pattern : String
  /-- The revision of the prompt's candidates it matches. -/
  revision : Nat
  /-- The config generation it was spawned under: an install ends it. -/
  generation : Nat
  deriving DecidableEq, Repr

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
  /-- How it answers later, for a source that does: it then answered no
  candidates, and was not run. -/
  later : Option Later := none
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
  /-- The sources that answer later, in the order they were asked, none of
  them asked yet. -/
  asking : Array Asking := #[]
  deriving DecidableEq, Repr

end Editor.Completion
