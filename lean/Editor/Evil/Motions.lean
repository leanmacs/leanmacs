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

- **A count is bounded by the text.** A motion that repeats stops when it
  can go no further, and each turn is a request of the text port, which
  the interrupt guards, so a count far past a large text can be stopped.

Pinned by `ModelTest.evilMotionChecks`, by key, under the Vim scheme that
ships.
-/

namespace Editor.Evil

/-- Where `step` leads from `head` of `text`, taken `count` times, or until
it reaches `bound`, when `past` says a position is at the bound or beyond
it, or until it moves no further. -/
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

/-- The table the move command looks a motion's name up in. -/
def motions : Array Vocabulary.Motion :=
  #[left, right]

end Editor.Evil
