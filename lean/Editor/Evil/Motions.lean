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

/-- The table the move command looks a motion's name up in. -/
def motions : Array Vocabulary.Motion :=
  #[left, right, wordForward, wordBackward, wordEnd, bigwordForward, bigwordBackward, bigwordEnd]

end Editor.Evil
