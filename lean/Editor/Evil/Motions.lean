import Editor.Vocabulary

/-!
# Evil's motions

Vim's motions as vocabulary entries (`Editor/Vocabulary.lean`), each
composed from the text port's motion primitives (`Editor/Text.lean`), and
the table the move command looks names up in (`motions`). The names are the
ones the Vim scheme's default tables bind keys to
(`Editor/InputScheme/Vim/Default.lean`): a name is changed in its row there
and in its entry here together. Nothing here names a key.

Each entry answers the raw target, which the move command then rests by the
view's state (`Editor/Evil.lean`, "Where a cursor rests"). What a count
means, and what a motion does when it cannot go the whole way, is Vim's
(`docs/design/keymaps-and-modes.md`, "Motions as built"):

| Motion | Composed from | Count |
|---|---|---|
| `left`, `right` | `previousCell`, `nextCell`, stopped at the line's start and at where its content ends | Repeats. Goes as far as the line allows |
| `word-forward`, `word-backward`, `word-end` and the three `bigword` names | `nextWordStart`, `previousWordStart`, `nextWordEnd` of a word or a WORD | Repeats. Stops when the position no longer changes |
| `line-start` | `lineStart` | None is ever given: a `0` after a digit is part of the count. A count is ignored |
| `line-first-non-blank` | `lineFirstNonBlank` | Ignored, as Vim documents |
| `line-end` | `rowsDown (count - 1)`, then `lineEnd` | The end of the line `count - 1` lines below. With fewer lines below it goes to the last line's end. On the last line with a count above 1 it does not move, which is Vim's failed motion |

- **The last line** (`lastLine`) is the last row a cursor may rest in
  outside insert state: the row before the empty last row of a text that
  ends in a line feed, and the last row otherwise.

- **What a word is is the text port's** (`Editor/Text.lean`): a run of word
  characters or of punctuation, or the line break of an empty line; a WORD
  is a run of characters that are not blank. It is Vim's on ASCII and not
  beyond it, which is recorded and pinned with the text port and not here.
- **Where there is no word further on**, the raw target is the text's end,
  which an operator wants; the cursor then rests on the last character.

- **A count is bounded by the text.** A motion that repeats stops when it
  can go no further, and each turn is a request of the text port, which
  the interrupt guards, so a count far past a large text can be stopped.

Pinned by `ModelTest.evilMotionChecks`, by key, under the Vim scheme that
ships.
-/

namespace Editor.Evil

/-- Where `step` leads from `head` of `text`, taken `count` times, or until
`past` says the position reached is as far as the motion may go, or until
a step moves no further. -/
def stepped (text : TextId) (step : Motion) (count : Nat) (past : Nat → Bool) (head : Nat) :
    TextM Nat := do
  let mut head := head
  for _ in [0:count] do
    if past head then
      break
    let next ← text.motion step head
    if next == head then
      break
    head := next
  return head

/-- One cell back, `count` times, 1 with no count, and no further than the
line's start. -/
def left : Vocabulary.Motion :=
  { name := "left"
    target := fun text origin => do
      let start ← text.motion .lineStart origin.head
      return {
          head := ← stepped text .previousCell (origin.count.getD 1) (· ≤ start) origin.head } }

/-- One cell on, `count` times, 1 with no count, and no further than where
the line's content ends: the raw target may be the line break, where an
operator's range stops. -/
def right : Vocabulary.Motion :=
  { name := "right"
    target := fun text origin => do
      let stop ← text.motion .lineEnd origin.head
      return { head := ← stepped text .nextCell (origin.count.getD 1) (· ≥ stop) origin.head } }

/-- The motion called `name` that takes `step` `count` times, 1 with no
count, and stops when a step moves no further: where the text has no such
place further on, the primitive answers the text's end going forward and 0
going back, and answers it again from there. -/
def repeating (name : String) (step : Motion) : Vocabulary.Motion :=
  { name
    target := fun text origin =>
      return { head := ← stepped text step (origin.count.getD 1) (fun _ => false) origin.head } }

/-- To the start of the next word. -/
def wordForward : Vocabulary.Motion :=
  repeating "word-forward" (.nextWordStart .word)

/-- To the start of the word before. -/
def wordBackward : Vocabulary.Motion :=
  repeating "word-backward" (.previousWordStart .word)

/-- To the end of the next word. -/
def wordEnd : Vocabulary.Motion :=
  repeating "word-end" (.nextWordEnd .word)

/-- To the start of the next WORD. -/
def bigwordForward : Vocabulary.Motion :=
  repeating "bigword-forward" (.nextWordStart .bigWord)

/-- To the start of the WORD before. -/
def bigwordBackward : Vocabulary.Motion :=
  repeating "bigword-backward" (.previousWordStart .bigWord)

/-- To the end of the next WORD. -/
def bigwordEnd : Vocabulary.Motion :=
  repeating "bigword-end" (.nextWordEnd .bigWord)

/-- The last line of `text`, as a row: the last row a cursor may rest in
outside insert state. A text that ends in a line feed has an empty last row
with no cell, which is no line: the last line is then the row before it.
It is row 0 for the empty text and for a text that is one line feed. -/
def lastLine (text : TextId) : TextM Nat := do
  let rows ← text.rowCount
  if rows > 1 && (← text.offsetOf ⟨rows - 1, 0⟩) == (← text.byteLength) then
    return rows - 2
  return rows - 1

/-- To the line's start, whatever the count: a `0` typed after a digit is
part of a count, so none is ever given. -/
def lineStart : Vocabulary.Motion :=
  { name := "line-start"
    target := fun text origin => return { head := ← text.motion .lineStart origin.head } }

/-- To the line's first character that is not a blank, or to where its
content ends when it has none, whatever the count. -/
def lineFirstNonBlank : Vocabulary.Motion :=
  { name := "line-first-non-blank"
    target := fun text origin => return { head := ← text.motion .lineFirstNonBlank origin.head } }

/-- To where the content ends of the line `count - 1` lines below, of this
line with no count, and of the last line when the text has fewer below.
From the last line with a count above 1 it does not move, which is Vim's
failed motion. The raw target is the line break, or the text's end. -/
def lineEnd : Vocabulary.Motion :=
  { name := "line-end"
    target := fun text origin => do
      let count := origin.count.getD 1
      let row := (← text.pointOf origin.head .cells).row
      let last ← lastLine text
      if count > 1 && row ≥ last then
        return { head := origin.head }
      let below ← text.motion (.rowsDown (min (count - 1) (last - row)) 0) origin.head
      return { head := ← text.motion .lineEnd below } }

/-- The table the move command looks a motion's name up in. -/
def motions : Array Vocabulary.Motion :=
  #[left, right, wordForward, wordBackward, wordEnd, bigwordForward, bigwordBackward, bigwordEnd,
    lineStart, lineFirstNonBlank, lineEnd]

end Editor.Evil
