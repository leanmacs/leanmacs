import Editor.Vocabulary

/-!
# Evil's motions

Vim's motions as vocabulary entries (`Editor/Vocabulary.lean`), each
composed from the text port's motion primitives (`Editor/Text.lean`), with
the display's move query where a column is the display's (`down`, `up`), and
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
| `down`, `up` | `rowsDown`, `rowsUp` to the line's start, then the display's position at the wanted column of that line | Rows. Stops at the last line and at the first |
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
    cursor's own when they are handed none, and keep it.
  - `line-end` keeps the line's end, also when it does not move.
  - `left` and `right` keep none when the cursor moves, and what was kept
    when it does not: Vim leaves the column alone when `h` or `l` fails.
  - Every other motion keeps none, also when the cursor does not move.
  - **The column is a display column, as Vim's is, and it is the
    display's.** `down` and `up` take the line they go to from the text
    port and ask the display, with the move query (`Display.linesFrom`),
    for the cursor's own x and for the position at an x of that line
    (`inLine`). What they keep is the x the display passed back
    (`WantedColumn.goal`), and nothing here computes with it: a tab's stop
    and a character's width are layout's.
  - **The display is asked about the line unwrapped** (`unwrapped`), so
    the column is one of the line and not of a visual row, whatever the
    view's width, and nothing of the view's rectangle is read: `j` and `k`
    are the same in a view that is not laid out. Each takes a snapshot of
    the text round its questions and releases it (`TextId.withSnapshot`,
    `Editor/Command.lean`).
  - **What they ask**: nothing of the display when they are handed the
    line's end; one question when they are handed a goal, which is every
    `j` or `k` after the first, and none when they then cannot move; two
    when they are handed none, and one when they then cannot move. A count
    asks no more: the text port goes to the line in one request.
  - **A cursor on a tab counts at the tab's first column**, where Vim's
    counts at its last: the x the display answers for a position is where
    its character starts. A recorded departure.
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

/-- The width a text is laid out at when a column of a line is asked for: a
width no line reaches, since it is wider than any machine word holds, which
the display takes for wider than any view (`Editor/Display/Contract.lean`).
At it a row of the display is a line of the text, and an x is counted from
the line's start. -/
def unwrapped : Nat :=
  2 ^ 64

/-- What the display answers of `position` in its line of `snapshot`, laid
out unwrapped: with no goal, the position's own x, as the goal passed back;
with one, the position at that x of the line, or the line's end past its
last character. A move of no lines, so the line is the position's. -/
def inLine (snapshot : SnapshotId) (position : Nat) (goal : Option Nat) : DisplayM Display.Moved :=
  Display.linesFrom { snapshot, width := unwrapped, position, lines := 0, goal }

/-- The motion called `name` by lines of the text, down when `down` and up
otherwise: `count` lines, 1 with no count, and no further than the last
line (`lastLine`) or the first. An operator takes the whole lines of both
ends. With no line to go to, on the last line going down and on the first
going up, it has failed.

The line it goes to is the text port's. The column on that line is the
display's ("The wanted column", in the module docs):

- handed the line's end, it goes to where the line's content ends and asks
  the display nothing;
- handed a goal, it asks the display for the position at that x of the
  line, and with no line to go to it asks nothing and stays;
- handed none, it first asks the display for the cursor's own x, and aims
  for that.

It keeps the column it aimed for: on a line that does not reach it the raw
target is where the line's content ends. -/
def vertical (name : String) (down : Bool) : Vocabulary.Motion :=
  { name
    reach := .lines
    target := fun text origin => do
      let head := origin.head
      let row := (← text.pointOf head .cells).row
      let last ← lastLine text
      let rows := min (origin.count.getD 1) (if down then last - row else row)
      let line ← text.motion (if down then .rowsDown rows 0 else .rowsUp rows 0) head
      match origin.wanted with
      | some .lineEnd =>
        return { head := ← text.motion .lineEnd line, wanted := some .lineEnd, failed := rows == 0 }
      | some (.goal x) =>
        if rows == 0 then
          return { head, wanted := some (.goal x), failed := true }
        let moved ← text.withSnapshot fun snapshot => inLine snapshot line (some x)
        return { head := moved.position, wanted := some (.goal x) }
      | none =>
        text.withSnapshot fun snapshot => do
            let own ← inLine snapshot head none
            if rows == 0 then
              return { head, wanted := some (.goal own.goal), failed := true }
            let moved ← inLine snapshot line (some own.goal)
            return { head := moved.position, wanted := some (.goal own.goal) } }

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
