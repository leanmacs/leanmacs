import Editor.Completion.AtPoint
import Editor.Completion.Later
import Std.Data.HashSet

/-!
# Words from the open buffers

The first completion source that ships for completion at point (the
core's `lean/Editor/Completion/AtPoint.lean`): the words of the open
buffers, as Vim's `C-n` and Emacs's dabbrev complete. It answers later,
as a job, so gathering words never holds a key
(`docs/design/concurrency.md`, "Prompts").

## The rule

- **A word** is a maximal run of word characters (`wordCharacter`, the
  core's `lean/Editor/Text.lean`: letters, digits, `_` and every
  character past ASCII), as Vim's `iskeyword` goes by default. `Words.of` lists a text's words in order, each once,
  leaving out a run that overlaps the region being completed, so the text
  typed is never a candidate of its own.
- **The order** (`Words.ordered`) is Vim's `C-n` order: the asking buffer's
  words after the region, then those before it, wrapping round, then each
  other open buffer's from its start, in the order the buffers were last
  used. A word is listed once, at its first place.
- **The word before the cursor** (`Words.startBefore`) is the run of word
  characters that ends at the cursor: the region the at-point source
  answers.

## The source and its job

- `Words.source` answers later, from the job `words`
  (`Words.job`, `Words.gather`), and is asked once (`Reask.never`): what it
  gathers is matched as the text changes. It reads the open buffers' texts
  (`Later.readsTexts`), so the command that asks takes a snapshot of each,
  the asking buffer's first, and its query carries them.
- **The job reads each snapshot** (`JobRequest.snapshot`) and posts one
  batch a buffer, in `ordered`'s order, each word once across the batches.
  A snapshot read as `none`, released because the session closed, is passed
  over.
- **The at-point source** `AtPoint.words` answers the word before the
  cursor, completed from the sources of the category `word`. On a pause it
  answers only when that word holds `least` characters or more (2 by
  default), as Doom's `corfu-auto` does; on a key it answers even an empty
  word, so asking with nothing before the cursor lists every word. It asks
  by itself after a pause of `pause` milliseconds, 240 by default. Config
  tunes it by defining it again under its name: `defineAtPoint
  (Completion.AtPoint.words (pause := 100))`.

Pinned by `AtPointTest.wordsChecks` (`AtPointTest/AtPoint/Words.lean`), on
the job model and the editor's models, which also runs the at-point
sources' contract over every at-point source that ships, under the
sentences of the core's `ModelTest.atPointContractChecks`.
-/

namespace Editor.Completion

namespace Words

/-- The category of the words of the open buffers: the sources the at-point
source `words` completes from. -/
def category : String :=
  "word"

/-- The name of the job that gathers the words. -/
def job : String :=
  "words"

/-- The runs of word characters of `text`, each its text and its byte range,
in order. -/
def runs (text : String) : Array (String × Span) :=
  let (found, current, _) :=
    text.foldl
      (fun (found, current, offset) char =>
        let next := offset + char.utf8Size
        if wordCharacter char then
          match current with
          | some (word, start) => (found, some (word.push char, start), next)
          | none => (found, some (char.toString, offset), next)
        else
          match current with
          | some (word, start) => (found.push (word, { start, stop := offset }), none, next)
          | none => (found, none, next))
      ((#[] : Array (String × Span)), (none : Option (String × Nat)), 0)
  match current with
  | some (word, start) => found.push (word, { start, stop := text.utf8ByteSize })
  | none => found

/-- Whether the ranges `run` and `skip` overlap. -/
def overlaps (run skip : Span) : Bool :=
  run.start < skip.stop && skip.start < run.stop

/-- `words` with each word kept once, at its first place. -/
def distinct (words : Array String) : Array String :=
  (words.foldl
      (fun (kept, seen) word =>
        if seen.contains word then (kept, seen) else (kept.push word, seen.insert word))
      ((#[] : Array String), (∅ : Std.HashSet String))).1

/-- The words of `text`, in order, each once: its maximal runs of word
characters, less a run that overlaps `skip`. -/
def «of» (text : String) (skip : Option Span := none) : Array String :=
  distinct
    ((runs text).filterMap fun (word, run) => if skip.any (overlaps run) then none else some word)

/-- The words of each of `texts`, in Vim's `C-n` order: the first text's
words after `region`, then those before it, then each other text's from its
start, each word once, at its first place. With no region the first text's
are taken from its start too. -/
def ordered (texts : Array String) (region : Option Span) : Array String :=
  let first :=
    match texts[0]?, region with
    | some text, some region =>
      let kept := (runs text).filter fun (_, run) => !overlaps run region
      (kept.filter (·.2.start ≥ region.stop)).map (·.1) ++
        (kept.filter (·.2.stop ≤ region.start)).map (·.1)
    | some text, none => (runs text).map (·.1)
    | none, _ => #[]
  distinct (first ++ (texts.extract 1 texts.size).flatMap fun text => (runs text).map (·.1))

/-- The start of the run of word characters of `text` that ends at the byte
offset `offset`: `offset` itself when the character before it is no word
character. -/
def startBefore (text : String) (offset : Nat) : Nat :=
  (runs text).foldl
    (fun found (_, run) => if run.start < offset && offset ≤ run.stop then run.start else found)
    offset

/-- The job of the source `words`: reads each snapshot of the query's texts
(`JobRequest.snapshot`), passing over one read as `none`, and delivers one
batch a buffer, in `ordered`'s order with the query's region in the first,
each word once across the batches. -/
def gather (query : Query) (deliver : Array Candidate → JobM Unit) : JobM Unit := do
  let mut seen : Std.HashSet String := ∅
  let mut index := 0
  for snapshot in query.texts do
    let first := index == 0
    index := index + 1
    let some text ← readSnapshot snapshot | continue
    let words := if first then ordered #[text] query.region else ordered #[text] none
    let fresh := words.filter (!seen.contains ·)
    seen := fresh.foldl (·.insert ·) seen
    deliver (fresh.map Candidate.ofText)

/-- The completion source `words`: the words of the open buffers, answered
later by the job `words`, asked once, reading the open buffers' texts. -/
def source : Source :=
  { name := "words", category, candidates := fun _ => pure #[]
    later := some { job, reask := .never, readsTexts := true } }

/-- The completion sources the words ship as. -/
def shipped : Array Source :=
  #[source]

end Words

/-- The at-point source `words`: the word before the cursor, the run of word
characters that ends there (`Words.startBefore`, read on the cursor's line),
completed from the sources of the category `word`. On a pause it answers only
when that word holds `least` characters or more; on a key and a trigger,
even an empty word. It asks by itself after a pause of `pause`
milliseconds. -/
def AtPoint.words (pause : Nat := 240) (least : Nat := 2) : AtPoint :=
  { name := "words", pause := some pause
    ask := fun spot => do
      let .ok target ← spot.view.target | return none
      let text := target.buffer.text
      let lineStart ← text.motion .lineStart spot.offset
      let line ← text.slice lineStart spot.offset
      let start := lineStart + Words.startBefore line line.utf8ByteSize
      if spot.occasion matches .pause _ then
        if (← text.slice start spot.offset).length < least then
          return none
      return some { start, stop := spot.offset, sources := [.category Words.category] } }

/-- The at-point sources that ship. -/
def AtPoint.shipped : Array AtPoint :=
  #[AtPoint.words]

end Editor.Completion
