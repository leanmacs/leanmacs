import Editor.Vocabulary

/-!
# Evil's motions

Vim's motions as vocabulary entries (`Editor/Vocabulary.lean`), each
composed from the text port's motion primitives (`Editor/Text.lean`), and
the table the move command looks names up in (`motions`). The names are the
ones the Vim scheme's default tables bind keys to
(`Editor/InputScheme/Vim/Default.lean`): a name is changed in its row there
and in its entry here together. Nothing here names a key.

`Editor.lean` imports this module, so config can name the entries and the
table: a command of config's hands the move command the vocabulary that
ships, or that vocabulary with motions of its own added
(`ConfigTest.evilChecks`). Nothing here names the registry.

Each entry answers the raw target, which the move command then rests by the
view's state (`Editor/Evil.lean`, "Where a cursor rests"). What a count
means, and what a motion does when it cannot go the whole way, is Vim's
(`docs/design/keymaps-and-modes.md`, "Motions as built"):

| Motion | Composed from | Count |
|---|---|---|
| `left`, `right` | `previousCell`, `nextCell`, stopped at the line's start and at where its content ends | Repeats. Goes as far as the line allows |
| `down`, `up` | `rowsDown`, `rowsUp` with the wanted column | Rows. Stops at the last line and at the first |
| `word-forward`, `word-backward`, `word-end` and the three `bigword` names | `nextWordStart`, `previousWordStart`, `nextWordEnd` of a word or a WORD | Repeats. Stops when the position no longer changes |
| `line-start` | `lineStart` | None is ever given: a `0` after a digit is part of the count. A count is ignored |
| `line-first-non-blank` | `lineFirstNonBlank` | Ignored, as Vim documents |
| `line-end` | `rowsDown (count - 1)`, then `lineEnd` | The end of the line `count - 1` lines below. With fewer lines below it goes to the last line's end. On the last line with a count above 1 it does not move, which is Vim's failed motion |
| `first-line`, `last-line` | `offsetOf` of the row's start, then `lineFirstNonBlank` | The line number, from 1, stopped at the last line. With none: the first line, and the last |

What each says of itself for an operator (`Editor/Vocabulary.lean`,
"Motions"; what an operator then takes is `Editor/Evil/Operators.lean`):

| Motion | Reach | Where it leads an operator, where that is not its target | Fails |
|---|---|---|---|
| `left`, `right` | exclusive | | Never |
| `down`, `up` | lines | | On the last line, and on the first. A count past the text stops there and does not fail |
| `word-forward`, `bigword-forward` | exclusive | The last step stops where its line's content ends, and from an empty line goes to the next line's start. For an operator that replaces, on a cell that is neither a blank nor a line break: the end of the word, inclusive | Never |
| `word-backward`, `bigword-backward` | exclusive | | When a step is asked of it at the text's start: where it starts, and where it has come to rest on an empty first line with steps left over, which is the one failure here that comes after the motion moved |
| `word-end`, `bigword-end` | inclusive | | Never |
| `line-start` | exclusive | | Never |
| `line-first-non-blank` | exclusive | On a line of blanks only, the line's last blank | Never |
| `line-end` | inclusive | | With a count above 1 on the last line |
| `first-line`, `last-line` | lines | | Never |

- **The last line** (`lastLine`) is the last row a cursor may rest in
  outside insert state: the row before the empty last row of a text that
  ends in a line feed, and the last row otherwise.
- **The wanted column** (`Editor/Vocabulary.lean`, "Motions"; where it is
  kept is `Editor/State.lean`, "The wanted column"):
  - `down` and `up` aim for the column they are handed, or for the
    cursor's own column in cells when they are handed none, and keep it.
  - `line-end` keeps the line's end, also when it does not move.
  - `left` and `right` keep none when the cursor moves, and what was kept
    when it does not: Vim leaves the column alone when `h` or `l` fails.
  - Every other motion keeps none, also when the cursor does not move.
  - It counts cells, where Vim's counts display columns: a recorded
    departure, which shows with a tab or a wide character before the
    cursor.
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

/-- Where a motion along the line leads, `head` being its raw target: no
wanted column is kept when the cursor moves, and the one that was kept is
kept when the cursor comes to rest where it was, as Vim leaves it when `h`
or `l` fails. -/
def along (origin : Vocabulary.From) (head : Nat) : Vocabulary.To :=
  { head, unmoved := origin.wanted }

/-- One cell back, `count` times, 1 with no count, and no further than the
line's start. -/
def left : Vocabulary.Motion :=
  { name := "left"
    target := fun text origin => do
      let start ← text.motion .lineStart origin.head
      return along origin
          (← stepped text .previousCell (origin.count.getD 1) (· ≤ start) origin.head) }

/-- One cell on, `count` times, 1 with no count, and no further than where
the line's content ends: the raw target may be the line break, where an
operator's range stops. -/
def right : Vocabulary.Motion :=
  { name := "right"
    target := fun text origin => do
      let stop ← text.motion .lineEnd origin.head
      return along origin (← stepped text .nextCell (origin.count.getD 1) (· ≥ stop) origin.head) }

/-- The motion called `name` that takes `step` `count` times, 1 with no
count, and stops when a step moves no further: where the text has no such
place further on, the primitive answers the text's end going forward and 0
going back, and answers it again from there. -/
def repeating (name : String) (step : Motion) (reach : Vocabulary.Reach := .exclusive) :
    Vocabulary.Motion :=
  { name
    reach
    target := fun text origin =>
      return { head := ← stepped text step (origin.count.getD 1) (fun _ => false) origin.head } }

/-- The motion called `name` to the start of the word of `kind` before,
`count` times, 1 with no count, and no further than the text's start. It
has failed, as Vim's does, when a step is asked of it at the text's start:
when it starts there, and when it has come to rest on an empty first line
with steps left over. Come to rest at the start of a first line that has
content, it has not. -/
def backward (name : String) (kind : WordKind) : Vocabulary.Motion :=
  { name
    target := fun text origin => do
      let mut head := origin.head
      let mut failed := false
      for _ in [0:origin.count.getD 1] do
        if head == 0 then
          failed := origin.head == 0 || (← text.byteLength) > 0 && (← text.motion .lineEnd 0) == 0
          break
        head ← text.motion (.previousWordStart kind) head
      return { head, failed } }

/-- The motion called `name` to the start of the next word of `kind`,
`count` times, 1 with no count. Under an operator its last step is another
(`taken`), which is Vim's special case for a word motion with an operator:
it stops where its line's content ends, so the last word of a line is taken
with the blanks after it and not the line break; and from an empty line it
goes to the next line's start, so that line is what is taken.

For an operator that puts an insert in place of what it takes, on a cell
that is neither a blank (a space or a tab) nor a line break, it leads to
the end of the word instead, and is taken inclusively: Vim's `cw`, which
changes a word and leaves the blanks after it. The word under the cursor
counts as the first of a count, also when the cursor is on its last cell,
which it is when the next word's start is not after the next word's end;
then `count - 1` word ends on. -/
def forward (name : String) (kind : WordKind) : Vocabulary.Motion :=
  let step : Motion := .nextWordStart kind
  let wordEnd : Motion := .nextWordEnd kind
  { name
    target := fun text origin =>
      return { head := ← stepped text step (origin.count.getD 1) (fun _ => false) origin.head }
    taken := fun replaces text origin => do
      let head := origin.head
      if replaces && head < (← text.motion .lineEnd head) then
        let cell ← text.slice head (← text.motion .nextCell head)
        unless cell == " " || cell == "\t" do
          let stop ← text.motion wordEnd head
          let first := if (← text.motion step head) ≤ stop then head else stop
          return {
              head := ← stepped text wordEnd (origin.count.getD 1 - 1) (fun _ => false) first
              reach := .inclusive }
      let last ← stepped text step (origin.count.getD 1 - 1) (fun _ => false) head
      let stop ← text.motion .lineEnd last
      if last < (← text.byteLength) && (← text.motion .lineStart last) == stop then
        return { head := ← text.motion .nextCell last, reach := .exclusive }
      return { head := min (← text.motion step last) stop, reach := .exclusive } }

/-- To the start of the next word. -/
def wordForward : Vocabulary.Motion :=
  forward "word-forward" .word

/-- To the start of the word before. -/
def wordBackward : Vocabulary.Motion :=
  backward "word-backward" .word

/-- To the end of the next word. An operator takes that end's cell. -/
def wordEnd : Vocabulary.Motion :=
  repeating "word-end" (.nextWordEnd .word) .inclusive

/-- To the start of the next WORD. -/
def bigwordForward : Vocabulary.Motion :=
  forward "bigword-forward" .bigWord

/-- To the start of the WORD before. -/
def bigwordBackward : Vocabulary.Motion :=
  backward "bigword-backward" .bigWord

/-- To the end of the next WORD. An operator takes that end's cell. -/
def bigwordEnd : Vocabulary.Motion :=
  repeating "bigword-end" (.nextWordEnd .bigWord) .inclusive

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
content ends when it has none, whatever the count. Under an operator, on a
line of blanks only, it leads to the line's last blank, which is where
Vim's cursor goes: the operator takes the blanks before it and not that
one. -/
def lineFirstNonBlank : Vocabulary.Motion :=
  { name := "line-first-non-blank"
    target := fun text origin => return { head := ← text.motion .lineFirstNonBlank origin.head }
    taken := fun _ text origin => do
      let first ← text.motion .lineFirstNonBlank origin.head
      let stop ← text.motion .lineEnd origin.head
      if first == stop && (← text.motion .lineStart origin.head) < stop then
        return { head := ← text.motion .previousCell stop, reach := .exclusive }
      return { head := first, reach := .exclusive } }

/-- To where the content ends of the line `count - 1` lines below, of this
line with no count, and of the last line when the text has fewer below.
From the last line with a count above 1 it does not move, which is Vim's
failed motion. The raw target is the line break, or the text's end. It
keeps the line's end as the wanted column, also when it does not move, so
the vertical motions after it stay at line ends. An operator takes it
through the cell at its target (`inclusive`), which on a line break is no
cell more; where it does not move for want of a line below it has failed. -/
def lineEnd : Vocabulary.Motion :=
  { name := "line-end"
    reach := .inclusive
    target := fun text origin => do
      let count := origin.count.getD 1
      let row := (← text.pointOf origin.head .cells).row
      let last ← lastLine text
      if count > 1 && row ≥ last then
        return { head := origin.head, wanted := some .lineEnd, failed := true }
      let below ← text.motion (.rowsDown (min (count - 1) (last - row)) 0) origin.head
      return { head := ← text.motion .lineEnd below, wanted := some .lineEnd } }

/-- The motion called `name` by lines of the text, down when `down` and up
otherwise: `count` lines, 1 with no count, and no further than the last
line (`lastLine`) or the first. It aims for the wanted column it is handed,
or for the cursor's own column, counted in cells, when it is handed none,
and keeps the column it aimed for: on a row with fewer cells the raw
target is where the row's content ends. An operator takes the whole lines
of both ends. With no line to go to, on the last line going down and on the
first going up, it has failed. -/
def vertical (name : String) (down : Bool) : Vocabulary.Motion :=
  { name
    reach := .lines
    target := fun text origin => do
      let point ← text.pointOf origin.head .cells
      let last ← lastLine text
      let rows := min (origin.count.getD 1) (if down then last - point.row else point.row)
      let column := origin.wanted.getD (.cells point.column)
      let to (cells : Nat) : Motion := if down then .rowsDown rows cells else .rowsUp rows cells
      let head ←
        match column with
        | .cells cells =>
          text.motion (to cells) origin.head
        | .lineEnd =>
          text.motion .lineEnd (← text.motion (to 0) origin.head)
      return { head, wanted := some column, failed := rows == 0 } }

/-- Down by lines of the text. -/
def down : Vocabulary.Motion :=
  vertical "down" true

/-- Up by lines of the text. -/
def up : Vocabulary.Motion :=
  vertical "up" false

/-- The motion called `name` to a line: with a count, the line of that
number, from 1, or the last line (`lastLine`) when the text has fewer; with
none, the last line when `last` and the first otherwise. It goes to the
line's first character that is not a blank, which is Vim's default. An
operator takes the whole lines of both ends. -/
def toLine (name : String) (last : Bool) : Vocabulary.Motion :=
  { name
    reach := .lines
    target := fun text origin => do
      let final ← lastLine text
      let row :=
        match origin.count with
        | some line => min (line - 1) final
        | none => if last then final else 0
      return { head := ← text.motion .lineFirstNonBlank (← text.offsetOf ⟨row, 0⟩) } }

/-- To the first line, or to the line a count numbers. -/
def firstLine : Vocabulary.Motion :=
  toLine "first-line" false

/-- To the last line, or to the line a count numbers. -/
def lastLineMotion : Vocabulary.Motion :=
  toLine "last-line" true

/-- The table the move command looks a motion's name up in: one entry for
each name the Vim scheme's default tables bind a key to. -/
def motions : Array Vocabulary.Motion :=
  #[left, down, up, right, wordForward, wordBackward, wordEnd, bigwordForward, bigwordBackward,
    bigwordEnd, lineStart, lineFirstNonBlank, lineEnd, firstLine, lastLineMotion]

end Editor.Evil
