import Editor.Invocation
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
  by the display (`packages/completion/Completion/Displays.lean`); the kind is carried
  and not drawn (`docs/design/keymaps-and-modes.md`, "A prompt's
  sources").
- **A query** is the text typed so far and the view the prompt was asked
  from, with the place names are read from (`Place`): the directory a
  name that is not absolute is read under, and the home directory; and the
  context the command that opened the prompt hands its sources
  (`Query.context`), plain arguments. What is added to it is a field here,
  never a new type.
- **What matching answers** (`Editor/Completion/Style.lean`): a `Hit`, the
  index of a candidate a style matched and the ranges of its text that
  matched (`Span`, byte offsets), and a `Listed`, a candidate as a
  prompt's listing holds it, with those ranges. The ranges travel with the
  candidate so a display can draw them, and the minibuffer display does,
  in `minibuffer.match` (`packages/completion/Completion/Displays.lean`).
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
  /-- What reveals it, when it is hidden: with `some p` it is listed only
  while the typed text after its source's separator (`Reask.after`) starts
  with `p`. The source decides, as data, as the file source hides a name
  that starts with `.` until a `.` is typed (`Editor/Completion/Paths.lean`).
  It is filtered where a listing is made (`Candidates.answering`,
  `Editor/State.lean`), so a style is handed only what is shown. -/
  hiddenUntil : Option String := none
  /-- Whether it is a prefix to go on from rather than an answer: accepting
  it puts its text in the minibuffer and keeps the prompt open, as Doom's
  `vertico-directory-enter` goes into a directory (`acceptPrompt`,
  `Editor/Api.lean`). Generic data, which the file source sets on a
  directory. (`partial` is a keyword, hence the name.) -/
  isPartial : Bool := false
  deriving DecidableEq, Repr

/-- The candidate of `text`, with nothing beside it. -/
def Candidate.ofText (text : String) : Candidate :=
  { text }

/-- `candidate` as a prompt holds it when the source `source` answered it:
in its own group, or, with none, in the source's. -/
def Candidate.inGroup (candidate : Candidate) (source : String) : Candidate :=
  { candidate with group := candidate.group <|> some source }

/-- A range of a candidate's text, or of a buffer's text: UTF-8 byte
offsets, `stop` excluded, as a scene's decorations count them. -/
structure Span where
  /-- The offset of its first byte. -/
  start : Nat
  /-- The offset just past its last byte. -/
  stop : Nat
  deriving DecidableEq, Repr

/-- Where a name that is not absolute is read from, for a source that reads
paths: the asking view's directory (`EditorState.directoryOf`), and the home
directory, which a host may not know. -/
structure Place where
  /-- What a name that is not absolute is read under. -/
  directory : Option System.FilePath := none
  /-- The home directory, which `~` names. -/
  home : Option System.FilePath := none
  deriving DecidableEq, Repr

/-- What a source is asked. -/
structure Query where
  /-- The text typed so far. -/
  text : String
  /-- The view the prompt was asked from. -/
  view : ViewId
  /-- The region being completed, for a source asked at point
  (`Editor/Completion/AtPoint.lean`); none for a prompt. -/
  region : Option Span := none
  /-- Snapshots of the open buffers' texts, the asking view's first, when a
  source that answers later reads them (`Later.readsTexts`); none
  otherwise. -/
  texts : Array SnapshotId := #[]
  /-- Where a name that is not absolute is read from (`Place`), filled where
  the query is made from the state, or given by the command that opened the
  prompt (`prompt`, `Editor/Api.lean`). -/
  place : Place := {}
  /-- What the command that opened the prompt hands its sources: plain
  arguments a source reads, such as the command that lists a workspace's
  files (`Editor/Workspace/FindFile.lean`). Empty for every other prompt,
  and for a session at point. -/
  context : List Argument := []
  deriving DecidableEq, Repr

/-- A source an at-point source names to complete its region from: by its
name, or every source of a category. It is data, so a reply can carry it. -/
inductive Named where
  /-- The source registered under `name`. -/
  | source (name : String)
  /-- Every source registered in `category`. -/
  | category (category : String)
  deriving DecidableEq, Repr

/-- Why an at-point source is asked. -/
inductive Occasion where
  /-- A key asked for completion: `C-SPC`, `C-n` or `C-p`. -/
  | key
  /-- The character `char`, one of the source's triggers, was typed. -/
  | trigger (char : Char)
  /-- Typing paused for `ms` milliseconds, the source's own pause. -/
  | pause (ms : Nat)
  deriving DecidableEq, Repr

/-- What an at-point source is asked: the view, the cursor's byte offset in
its buffer's text, and why it is asked. -/
structure Spot where
  /-- The view asked from. -/
  view : ViewId
  /-- The cursor's byte offset. -/
  offset : Nat
  /-- Why it is asked. -/
  occasion : Occasion := .key
  deriving DecidableEq, Repr

/-- What an at-point source answers: the region of the text to replace, byte
offsets with `start ≤ offset ≤ stop`, and the sources to complete it from,
in order. -/
structure Region where
  /-- The offset of the region's first byte. -/
  start : Nat
  /-- The offset just past the region's last byte. -/
  stop : Nat
  /-- The sources its candidates come from. -/
  sources : List Named
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
  through that the style does not match. -/
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
  /-- Whenever the text through its last `separator` changes: it answers for
  that part of the text, as a file source answers a directory. It is asked
  again at once, and an answer for another part is not listed
  (`Reask.answers`). -/
  | beforeLast (separator : Char)
  deriving DecidableEq, Repr

/-- `text` through its last `separator`, or `""` when it has none. -/
def Reask.before (separator : Char) (text : String) : String :=
  let chars := text.toList
  String.ofList (chars.take (chars.length - (chars.reverse.takeWhile (· != separator)).length))

/-- Whether a source that answers so, asked with `asked`, is asked again now
that `typed` is typed. -/
def Reask.asksAgain : Reask → (asked typed : String) → Bool
  | .never, _, _ => false
  | .afterPause _, asked, typed => asked != typed
  | .beforeLast separator, asked, typed => before separator asked != before separator typed

/-- How long the job of a source that answers so waits before it asks, in
milliseconds, when it is asked again. -/
def Reask.pause : Reask → Nat
  | .never => 0
  | .afterPause pause => pause
  | .beforeLast _ => 0

/-- Whether what a source that answers so answered for `answeredFor` is
listed while `typed` is typed: always, but for a source asked again by the
part before its separator, whose answer is listed only for the same part.
So a source that waits for a pause keeps its previous answer listed until
its next one, and a directory's entries are never listed under another. -/
def Reask.answers : Reask → (answeredFor typed : String) → Bool
  | .beforeLast separator, answeredFor, typed =>
    before separator answeredFor == before separator typed
  | _, _, _ => true

/-- The part of `typed` a source that answers so matches its hidden
candidates against (`Candidate.hiddenUntil`): after the last separator for
a source asked again by the part before it, and the whole text otherwise. -/
def Reask.after : Reask → String → String
  | .beforeLast separator, typed =>
    String.ofList (typed.toList.drop (before separator typed).length)
  | _, typed => typed

/-- How a source answers later: the registered job that answers it, and when
it is asked again. -/
structure Later where
  /-- The name of the registered job that answers: started with the order
  (`Completion.Order`), it posts its candidates in batches. -/
  job : String
  /-- When it is asked again. -/
  reask : Reask := .never
  /-- Whether its job reads the open buffers' texts: the asking command then
  takes a snapshot of each, which its query carries (`Query.texts`). -/
  readsTexts : Bool := false
  deriving DecidableEq, Repr

/-- What an open prompt holds of a source that answers later: which source
it is, what was asked, and what has come in. -/
structure Asking where
  /-- The source's name: its candidates' group. -/
  source : String
  /-- Whether it has filtered already: its candidates are then listed as
  given, after the matches, with the style's ranges where it matches. -/
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
  /-- The text `answered` was asked for: set at a generation's first batch,
  or at its end when it delivered none. It is not `askedFor`, which changes
  at the re-ask while `answered` is still the previous answer. -/
  answeredFor : Option String := none
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
  candidates are listed as given, in its order, none dropped, with the
  style's ranges where it matches. -/
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
  /-- The region the sources were asked to complete, for a session at
  point; none for a prompt. -/
  region : Option Span := none
  /-- The snapshots taken for the sources that read the open buffers'
  texts, the asking view's first; none when no source does. -/
  texts : Array SnapshotId := #[]
  /-- The place the sources were asked with (`Query.place`), for the jobs of
  the sources that answer later. -/
  place : Place := {}
  /-- The context the sources were asked with (`Query.context`), for the jobs
  of the sources that answer later. -/
  context : List Argument := []
  deriving DecidableEq, Repr

end Editor.Completion
