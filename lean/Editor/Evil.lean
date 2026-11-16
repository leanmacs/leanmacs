import Editor.Api
import Editor.Command.Call
import Editor.Vocabulary

/-!
# Evil

Vim's states, motions and commands written on the editor API
(`docs/design/keymaps-and-modes.md`, "The Vim scheme"). The Vim scheme
(`Editor/InputScheme/Vim.lean`) is the grammar: keys in, an invocation out,
with no editor API. This module is what those invocations run: programs
over the editor's port, which name no key. `Editor.lean` imports it and
the motions (`Editor/Evil/Motions.lean`), so config can call them, and can
hand the move command the vocabulary that ships.

Each command here is given its call (`Editor/Command/Call.lean`), and reads
what the input scheme reports of its view from it (`Call.report`): the
shape the selection has, whether a motion extends it, and where the head
may rest. None matches on a Vim state's name, so a state that config
registers is moved in by the same commands.

| Module | Holds |
|---|---|
| `Editor/Evil.lean` | The resting rule and the commands, each a function of its call |
| `Editor/Evil/Motions.lean` | The motions, as vocabulary entries, and their table (`Evil.motions`) |
| `Editor/Evil/Operators.lean` | The operators, as vocabulary entries, their table (`Evil.operators`), and the operate command |
| `Editor/Evil/Registers.lean` | The registers a yank and a deletion set |
| `Editor/Evil/Scroll.lean` | The commands that scroll a view, over the scroll policy of `Editor/Scroll.lean` |
| `Editor/Evil/Compiled.lean` | The commands' registrations, under the names the Vim scheme's invocations carry |

## The move command

`move motions` is the command a move runs: it is a function of the table it
looks the motion's name up in, so the caller supplies the vocabulary.

- **Its arguments are the name of the motion, a string, and the count**, a
  number, with 0 for none, as the Vim scheme lays a move out
  (`Editor/InputScheme/Vim.lean`, "Edits"). The count may be left out,
  which is no count, so a command of config's calls it with a name alone.
  A motion's argument, when it has one, is the string right after the
  name, before the count: `[.str "find-forward", .str "x", .nat 2]`.
- **It keeps what the motion hands back to be remembered** and says what
  it hands back to be said: the find it made as the last find
  (`setLastFind`, `Vocabulary.To.find`) and the search it made as the last
  search (`setLastSearch`, `Vocabulary.To.search`), also when the motion
  failed, as Vim keeps them, and its `said` in the echo area: a search's
  wrap warning or why it failed.
  A name with no entry says `<name>: no such motion` in the echo area and
  moves nothing.
- **A call that names no motion says so, apart from a name with no
  entry.** Run by its name, which hands a command no argument, or called
  with a first argument that is not a string, it says
  `move: no motion named` and what it expects (`noMotionNamed`), and moves
  nothing: the reader is told the call was malformed, not that a name was
  misspelt.
- **It reads the primary range of its target's selection**, asks the motion
  for the raw target from that range's head, rests the raw target by the
  rule of the call's report ("Where a cursor rests"), and places one range
  with the report's shape. Its head is the rested target. Its anchor is
  the anchor the range had where the report says a motion extends the
  selection (`selecting`: the visual states), and the new head otherwise.
- **It hands the motion the wanted column the window keeps, when that
  column still holds** (`Window.wanted`, `Editor/State.lean`, "The wanted
  column"): when the head is where the cursor was left when the column was
  kept. It then has the window keep what the motion hands back, with the
  new head (`ViewId.setWanted`): the motion's `wanted`, or its `unmoved`
  when the head came to rest where it started. Only here is it known
  whether the cursor moved, since the resting rule is applied here. What
  the column is is the motion's: `j` and `k` keep a display column, which
  they ask the display for (`Editor/Evil/Motions.lean`, "The wanted
  column"), and the move command passes it on unread.
- **It reads that column from the editor state when it is called**
  (`editorState`), as it reads the selection from its marker, and not from
  its call's window, which is the window as it was when the command was
  called (`Editor/Command/Call.lean`). So a command that calls it more
  than once with one call moves as that many keys do: down and then down
  across a shorter line lands in the column it started in.
- **Placing a marker is no edit**, so a motion is no step of the history.
- **One cursor.** No command makes a second range; this one reads the
  primary range and places one range.

## Entering a state

`enter` is the command a key that enters a Vim state runs, whichever state
it is: it reshapes the selection by what the scheme reports of the view,
which is the report of the state being entered, since a command sees the
scheme's state after its key (`Editor/Command/Call.lean`). The rule
(`docs/design/keymaps-and-modes.md`, "Vim states"):

1. The selection takes the report's shape.
2. Its two ends are kept where the report says a motion extends the
   selection (the visual states). Otherwise it is collapsed onto its head.
3. When the selection was exclusive and the new shape is not, which is an
   insert session ending, the head first steps back one cell, and stays
   where it is at the start of its line. This is Vim's escape.
4. The head is then put where the state lets it rest ("Where a cursor
   rests"), and so is the anchor where it is kept.

- **So entering a visual state from normal state changes nothing but the
  shape**: the selection is already one range with equal ends on the cell
  under the cursor, and the next motion moves its head alone. From one
  visual state to the other both ends are kept, so the columns survive
  line-wise selection.
- **The window keeps no wanted column once the selection is collapsed**
  (`ViewId.setWanted`), as Vim's escape resets it; entering a state that
  keeps both ends leaves it.
- **It ignores its count and its register.**
- **The command enters no state: its key does.** The scheme's state is
  changed only by the scheme, at a key: under the Vim scheme by a key
  bound to an edit that names a state (`Edit.enters`,
  `Editor/InputScheme/Vim.lean`). `enter` and the four commands that
  begin an insert ("Insert state") reshape the selection for the state
  their call's report says, and change nothing of the scheme. So each
  enters a state only when a key that enters it runs it. Run by its name,
  which no key ran, or by a key bound to its name alone, which enters no
  state, it is told the report of the state the view is already in
  (`Editor/Command/Call.lean`): the view stays in that state, the
  selection is reshaped for it, and nothing is said in the echo area.
- **It cannot say that it entered nothing.** It is not told the name it
  was run under, and nothing here knows which report a name stands for:
  that is the record of a Vim state, which the scheme alone reads, and no
  command matches on a state's name. That no key ran it does not decide
  it either: a command of config's run by its name may call `enter` with
  a report of its own, and a key bound to the name alone enters nothing.
- **No default key enters a state that keeps both ends from an insert
  session**, or with an anchor that is not on a cell, so rule 3 with both
  ends kept, and the anchor's part of rule 4, are pinned by calling
  `enter` with a report written by hand (`ModelTest.evilStateChecks`), as
  a state config registers would have it called.

## Insert state

Insert state is a state whose selection is exclusive: a bar between
characters. The commands here place the bar and insert at it; that what is
typed in one session is one step of the history is the loop's
(`Editor/Loop.lean`, "Insert sessions"), which leaves the buffer's undo
group open while the scheme reports the view as in a session. The one
command here that sets a boundary inside a session is an arrow key's
(`insertMove`, "Editing keys"), which sets it itself with
`BufferId.closeGroup`, as `Editor/Api.lean` ("Undo") says a command that
wants one does; no other sets or clears one.

- **Four commands begin an insert**, each by moving the head and then
  entering the state ("Entering a state"; `enterAt`), which makes the
  selection one bar there:

  | Command | Where the insert begins |
  |---|---|
  | `insert` | Before the cursor's cell: the head stays |
  | `append` | After the cursor's cell: one cell on, and not past where the line's content ends, so on an empty line the head stays |
  | `insertLineStart` | At the line's first character that is not a blank, which on a line of blanks only is where the content ends |
  | `appendLineEnd` | Where the line's content ends, before its line break |
- **Each begins an insert only when a key that enters insert state runs
  it** ("Entering a state"). Run by its name it moves the head as the
  table says and then rests it as the state the view is in lets a cursor
  rest: in normal state `insert` leaves the cursor where it is, and no
  insert begins.
- **`selfInsert`** is the command typed text runs: it inserts its first
  argument, a string, at the head of each range of its target's selection
  (`Target.insertAtSelections`, `Editor/Api.lean`), one transaction that
  carries the selection before and after. With no string it inserts
  nothing and says so.
- **The minibuffer's typing is the same command.** While a prompt is open
  the focused window is the minibuffer's, whose view the scheme reports as
  taking text, so a key that prints there yields the same invocation and
  the loop runs it with the minibuffer's window as its target.
- **Leaving insert state is `enter`**: rule 3 steps the head back one cell
  on its line.
- **Not built: a count before a key that begins an insert.** Vim repeats
  the inserted text, which is the replay of an insert session. The
  commands ignore their count and their register, and so do the two that
  open a line.

### Opening a line

`openBelow` and `openAbove` are Vim's `o` and `O` (`openLine`).

- **`openBelow`** inserts the buffer's line ending where the cursor's
  line's content ends, and the new line is after it. **`openAbove`**
  inserts it at the start of the cursor's line, and the new line is before
  it.
- **The line ending is read from the buffer** (`Buffer.lineEnding`), as
  `Target.insertLineBreak` reads it (`Editor/Api.lean`). They do not call
  that operation: their edit carries the selection from before the command
  (`Target.replaceCarrying`), so an undo of the session hands back the
  cursor the user saw.
- **Each begins an insert only when a key that enters insert state runs
  it.** It leaves one range of the shape its call's report says on the new
  line, put where the report's state lets a cursor rest (`settle`): under
  insert state's report a bar there, and the line and the text typed after
  it are one insert session, one step of the history. Run by its name in
  normal state it opens the line and the cursor rests on it.
- **A recorded departure**: opened below a last line with no line feed and
  then left with `<Escape>`, the new line is the empty last row, where a
  cursor cannot rest ("Where a cursor rests"), so the cursor rests on the
  line above, where Vim's is on the new line.

### Editing keys

The named keys of insert state that edit or move, each a command of its
call that acts on the primary range of its target's selection and names no
Vim state. Each follows Vim 9.1 with its default options:

| Key | Command | What it does |
|---|---|---|
| `<Backspace>` | `deleteBackward` | Deletes the cell before the bar (`previousCell`, so a carriage return and line feed, or a character of several bytes, goes whole). At a line's start it joins the line to the one above, and it deletes past where the insert began: Vim's `i_<BS>` under `backspace=indent,eol,start`. At the text's start it deletes nothing |
| `RET` | `newline` | Breaks the line at the bar with the buffer's own line ending (`Target.insertLineBreak`), as `o` and `O` read it. No indent: Vim's default is `noautoindent` |
| `TAB` | `insertTab` | Inserts a tab character: Vim's `noexpandtab` and `softtabstop=0` |
| `<ArrowLeft>`, `<ArrowRight>`, `<ArrowUp>`, `<ArrowDown>` | `insertMove motions` with `left`, `right`, `up`, `down` | The move command by that motion, with no count. Left and right stop at the line's start and where its content ends, so neither wraps (`whichwrap=b,s`); up and down keep the wanted column across short lines |

- **An arrow key that moves starts a new step of the history**, as Vim
  9.1's `ins-special-special` says: once the head moved, `insertMove` sets
  the boundary in the buffer's history (`BufferId.closeGroup`), so what was
  edited before the key and after it are undone separately. A move that
  fails, left at a line's start or up on the first line, gives the command
  up (`cannotMove`, said in the echo area where Vim beeps), so it sets no
  boundary and the loop puts the scheme back as it was before the key.
  Placing a marker is no edit, so closing the group after the move is the
  same as before it.
- **Backspace, Enter and Tab join the session's step.** Their keys are
  bound as commands that change no text for the grammar, so none becomes
  the last change.
- **Dot repeat replays the keys as Vim 9.1's does**
  (`Editor/InputScheme/Vim.lean`, "The last change";
  `Editor/Evil/Repeat.lean`). `<Backspace>`, `RET` and `TAB` are kept in
  the text recorded for the last change, in the order typed, and `.` runs
  them again: a `<Backspace>` deletes the cell before the bar, past where
  the insert began too, `RET` breaks the line with the buffer's line ending,
  and `TAB` inserts a tab. An arrow key that moved restarts the change as
  `i` once something is typed after it, with the text typed from there on:
  `ins-special-special`'s "only the last change can be redone and always
  behaves like an i command". With nothing typed after it, and when it did
  not move, the change is as it was.
- **Not built: the other keys of Vim's insert state** (`C-w`, `C-u`,
  `C-o`, `C-r`, `<Home>`, `<End>`, ...): they do nothing there.

## Where a cursor rests

A motion answers a position, its raw target, which the text port never
clamps (`Editor/Text.lean`). Where the head of a selection may stay after a
command is a rule of the view's state (`Rest`), applied to the raw target
(`rested`). The rule is read off what the input scheme reports of the view
(`restOf`), so nothing here names a Vim state.

| The report | Rule | Where the head may rest |
|---|---|---|
| An exclusive selection (insert state, the minibuffer) | `anywhere` | Any position, the text's end included |
| Not exclusive, not selecting (normal state) | `offLineBreak` | A cell of its line that is not the line break, or the line break of an empty line |
| Not exclusive, selecting (the visual states) | `onCell` | Any cell, a line break included |

For the two rules that are not `anywhere`, in order:

1. An empty text answers 0.
2. An offset at or past the text's length goes to the start of the last
   cell. So the head is never past the last cell, and never in the empty
   last row of a text that ends in a line feed, which has no cell.
3. An offset past its row's content, which is the position between a
   carriage return and its line feed, goes to where the content ends.
4. For `offLineBreak`, an offset on the line break of a row that has
   content goes back one cell.

- **A line break is a cell in a visual state**, because Vim's cursor may be
  one past the line there.
- **The empty last row is not a line for a cursor outside insert state.**
  Vim has no such line: its lines are ended by line breaks, not separated
  by them.
- **On a last row with no line feed a visual-state head stops on the last
  character**, where Vim's goes one past: there is no cell there for an
  inclusive range to cover.
- **The rule is applied after the motion and not inside it**, so a motion
  answers the raw target, which an operator needs.

Pinned by `ModelTest.evilRestChecks`, on the text model, and, on the
loop's driver under the Vim scheme that ships, the move command by
`ModelTest.evilMotionChecks` and entering a state by
`ModelTest.evilStateChecks`.

## Where an addition goes

| Addition | Where |
|---|---|
| A new motion | An entry in `Editor/Evil/Motions.lean`, and its row in `Evil.motions`; the key that names it is a row of the Vim scheme's default tables |
| A new command a Vim key runs | A function of its call here, or in a module of its own beside this one, and its registration in `Editor/Evil/Compiled.lean` |
| A new fact a command needs of the view's Vim state | A field of the scheme's report (`Editor/InputScheme.lean`), read from the call; nothing here matches on a state's name |
-/

namespace Editor.Evil

/-- Where the head of a selection may stay after a command. -/
inductive Rest where
  /-- Any position, the text's end included. -/
  | anywhere
  /-- Any cell, a line break included. -/
  | onCell
  /-- A cell of its line that is not the line break, or the line break of an
  empty line. -/
  | offLineBreak
  deriving DecidableEq, Repr

/-- The resting rule of a view, read off what the input scheme reports of
it: anywhere for an exclusive selection, on a cell where a motion extends
the selection, and off the line break otherwise. -/
def restOf (report : InputScheme.Report) : Rest :=
  if report.shape == .exclusive then .anywhere
  else if report.selecting then .onCell else .offLineBreak

/-- Where a head at `offset` of `text` rests under `rest` (the rule in the
module docs). Refused with `badPosition` for an offset below the text's
length that is not a position. -/
def rested (rest : Rest) (text : TextId) (offset : Nat) : TextM Nat := do
  if rest == .anywhere then
    return offset
  let length ← text.byteLength
  if length == 0 then
    return 0
  let cell ←
    if offset ≥ length then
      text.motion .previousCell length
    else
      pure offset
  let content ← text.motion .lineEnd cell
  let cell := min cell content
  -- On the line break: of a row with content when the row starts before it.
  if rest == .offLineBreak && cell == content && (← text.motion .lineStart cell) < cell then
    text.motion .previousCell cell
  else
    return cell

/-- One range of the shape the call's report says, with both ends at
`offset`: the cursor a command's edit carries as the one it leaves, before
it is rested. -/
def cursorAt (call : Call) (offset : Nat) : Selection :=
  { ranges := #[⟨offset, offset⟩], shape := call.report.shape }

/-- Leaves the selection of the call's window as one range of the shape the
call's report says, with both ends where a head at `offset` rests under the
report's rule: where a command that edits leaves its cursor. -/
def settle (call : Call) (offset : Nat) : TextM Unit := do
  call.target.select (cursorAt call (← rested (restOf call.report) call.target.buffer.text offset))

/-- The count a command's key compiles to (`Editor/InputScheme/Vim.lean`,
"Edits"), 0 where the call has none: the call's first argument, as the Vim
scheme lays out the call of a command that takes a count and nothing
before it. -/
def countOf (call : Call) : Nat :=
  match call.arguments with
  | .nat count :: _ => count
  | _ => 0

/-- What the move command says in the echo area for a name the vocabulary
has no motion of. -/
def noSuchMotion (name : String) : String :=
  s!"{name}: no such motion"

/-- What the move command says in the echo area when it is called with no
motion's name, which is when its first argument is not a string: the call
is malformed, which is another fault than a name the vocabulary has no
motion of (`noSuchMotion`), so it says what the command expects. -/
def noMotionNamed : String :=
  "move: no motion named (expects a motion's name, then an optional count)"

/-- What the operate command gives up with, or breaks off with, when the
motion called `name` could not be made, and what an arrow key of insert
state's gives up with when its move did not move the cursor. -/
def cannotMove (name : String) : String :=
  s!"{name} cannot move"

/-- What the command typed text runs says in the echo area when it is called
with no string to insert. -/
def noText : String :=
  "self-insert: no text to insert"

/-- The move command over the vocabulary `motions`, as it is called ("The
move command", in the module docs): its first argument names the motion and
its second is the count, 0 or left out for none. The head of the primary
range of the target's selection goes where the motion leads, rested by the
rule of the call's report, and the selection is one range of the report's
shape, from the anchor it had where the report says a motion extends the
selection, and with both ends on the new head otherwise. The wanted column
it hands the motion is the one the window keeps when this is called, read
from the editor state. A call that names no motion (`noMotionNamed`) and a
name with no motion (`noSuchMotion`) are each said in the echo area, and
nothing moves. -/
def move (motions : Array Vocabulary.Motion) (call : Call) : EditorM Unit := do
  let counted (rest : List Argument) : Option Nat :=
    match rest with
    | .nat count :: _ => if count == 0 then none else some count
    | _ => none
  let named : Option (String × Option String × Option Nat) :=
    match call.arguments with
    | .str name :: .str argument :: rest => some (name, some argument, counted rest)
    | .str name :: rest => some (name, none, counted rest)
    | _ => none
  let some (name, argument, count) := named | message noMotionNamed
  let some motion := motions.find? (·.name == name) | message (noSuchMotion name)
  let text := call.target.buffer.text
  let view := call.target.window.id
  let selection ← call.target.selection
  let some range := selection.ranges[selection.primary]? | throw .badSelection
  -- Read from the state, not from the call's window, which is the window as
  -- it was when the command was called: an earlier move of the same command
  -- has had the window keep another column since.
  let kept := ((← editorState).window? view).bind (·.wanted)
  -- The kept column holds only while the cursor is where it was kept.
  let wanted := (kept.filter (·.head == range.head)).map (·.column)
  let raw ← motion.target text { head := range.head, count, wanted, argument }
  let head ← rested (restOf call.report) text raw.head
  let anchor := if call.report.selecting then range.anchor else head
  call.target.select { ranges := #[⟨anchor, head⟩], shape := call.report.shape }
  let keeps := if head == range.head then raw.unmoved else raw.wanted
  discard <| view.setWanted (keeps.map fun column => { column, head })
  if let some find := raw.find then
    setLastFind find
  if let some search := raw.search then
    setLastSearch search
  if let some said := raw.said then
    message said

/-- Enters the Vim state the call's report says, with the head first put
where `place` leads from where it is ("Entering a state", in the module
docs): the selection of the target's window becomes one range of the shape
the report says, with both its ends kept where the report says a motion
extends the selection and collapsed onto its head otherwise. A head that
leaves an exclusive selection for another shape first steps back one cell
on its line, and each end kept is put where the report's state lets a
cursor rest. Once the selection is collapsed the window keeps no wanted
column. -/
def enterAt (place : TextId → Nat → TextM Nat) (call : Call) : EditorM Unit := do
  let text := call.target.buffer.text
  let report := call.report
  let selection ← call.target.selection
  let some range := selection.ranges[selection.primary]? | throw .badSelection
  let placed ← place text range.head
  let leavesInsert := selection.shape == .exclusive && report.shape != .exclusive
  let back ←
    if leavesInsert && (← text.motion .lineStart placed) < placed then
      text.motion .previousCell placed
    else
      pure placed
  let head ← rested (restOf report) text back
  let anchor ←
    if report.selecting then
      rested (restOf report) text range.anchor
    else
      pure head
  call.target.select { ranges := #[⟨anchor, head⟩], shape := report.shape }
  unless report.selecting do
    discard <| call.target.window.id.setWanted none

/-- The command that enters a Vim state, as it is called: the state the
call's report says is entered with the head where it is (`enterAt`). It
ignores its count and its register. It changes nothing of the input
scheme: run by its name, which no key ran, it is told the report of the
state the view is already in, and reshapes the selection for that state
("Entering a state", in the module docs). -/
def enter (call : Call) : EditorM Unit :=
  enterAt (fun _ head => pure head) call

/-- The command that begins an insert before the cursor's cell, as it is
called ("Insert state", in the module docs): the head stays where it is,
and the view's state is entered (`enter`), which makes the selection one
bar there. It ignores its count and its register. -/
def insert (call : Call) : EditorM Unit :=
  enter call

/-- The command that begins an insert after the cursor's cell, as it is
called: the head goes one cell on, and not past where its line's content
ends, so on an empty line it stays, and the view's state is entered there.
It ignores its count and its register. -/
def append (call : Call) : EditorM Unit :=
  enterAt
    (fun text head => do
      if head < (← text.motion .lineEnd head) then
        text.motion .nextCell head
      else
        pure head)
    call

/-- The command that begins an insert at the line's first character that is
not a blank, as it is called: the head goes there, which on a line of
blanks only is where the line's content ends, and the view's state is
entered there. It ignores its count and its register. -/
def insertLineStart (call : Call) : EditorM Unit :=
  enterAt (fun text head => text.motion .lineFirstNonBlank head) call

/-- The command that begins an insert at the line's end, as it is called:
the head goes to where the line's content ends, before its line break, and
the view's state is entered there. It ignores its count and its
register. -/
def appendLineEnd (call : Call) : EditorM Unit :=
  enterAt (fun text head => text.motion .lineEnd head) call

/-- Opens an empty line beside the line of the head of the primary range of
the target's selection, below it when `below` and above it otherwise, and
leaves one range of the shape the call's report says on the new line
("Opening a line", in the module docs): the buffer's line ending is
inserted where the line's content ends, or at the line's start, in one edit
that carries the selection from before the command, and the window keeps no
wanted column. -/
def openLine (below : Bool) (call : Call) : EditorM Unit := do
  let text := call.target.buffer.text
  let before ← call.target.selection
  let some range := before.ranges[before.primary]? | throw .badSelection
  let ending := call.target.buffer.lineEnding.text
  let start ← text.motion (if below then .lineEnd else .lineStart) range.head
  -- The new line is after the line break put below, and before the one put
  -- above.
  let bar := if below then start + ending.utf8ByteSize else start
  discard <| call.target.window.id.setWanted none
  call.target.replaceCarrying ⟨start, start⟩ ending before (cursorAt call bar)
  settle call bar

/-- The command that opens a line below the cursor's and begins an insert
on it, Vim's `o`, as it is called. It ignores its count and its register. -/
def openBelow (call : Call) : EditorM Unit :=
  openLine true call

/-- The command that opens a line above the cursor's and begins an insert
on it, Vim's `O`, as it is called. It ignores its count and its register. -/
def openAbove (call : Call) : EditorM Unit :=
  openLine false call

/-- The command typed text runs, as it is called ("Insert state", in the
module docs): its first argument, a string, is inserted at the head of each
range of the target's selection, as one transaction that carries the
selection before and the cursors after. Called with no string it inserts
nothing and says so in the echo area (`noText`). -/
def selfInsert (call : Call) : EditorM Unit := do
  match call.arguments with
  | .str text :: _ =>
    call.target.insertAtSelections text
  | _ =>
    message noText

/-- The command `<Backspace>` runs in insert state, as it is called
("Editing keys", in the module docs): the cell before the head of the
primary range of the target's selection is deleted, a line break or a
character of several bytes whole, as one transaction that carries the
selection before and the cursor after. At the text's start the extent is
empty and nothing changes. -/
def deleteBackward (call : Call) : EditorM Unit := do
  let selection ← call.target.selection
  let some range := selection.ranges[selection.primary]? | throw .badSelection
  -- At the text's start the cell before is none: the extent is empty.
  let start ← call.target.buffer.text.motion .previousCell range.head
  call.target.replaceExtents selection #[⟨start, range.head⟩] ""

/-- The command `RET` runs in insert state, as it is called: the line is
broken at the bar with the buffer's own line ending
(`Target.insertLineBreak`), with no indent. -/
def newline (call : Call) : EditorM Unit :=
  call.target.insertLineBreak

/-- The command `TAB` runs in insert state, as it is called: a tab character
is inserted at the bar. -/
def insertTab (call : Call) : EditorM Unit :=
  call.target.insertAtSelections "\t"

/-- The command an arrow key runs in insert state, as it is called ("Editing
keys", in the module docs): the move command over `motions` by the motion
`name`, with no count, and then, when the head moved, a boundary in the
buffer's history, so that what was edited before the key and after it are
two steps, as in Vim 9.1. A move that fails gives the command up with
`cannotMove`, so the scheme does not restart the last change for it. -/
def insertMove (motions : Array Vocabulary.Motion) (name : String) (call : Call) : EditorM Unit :=
  do
  let head (selection : Selection) := (selection.ranges[selection.primary]?).map (·.head)
  let before := head (← call.target.selection)
  move motions { call with arguments := [.str name, .nat 0] }
  if head (← call.target.selection) == before then
    giveUp (cannotMove name)
  discard <| call.target.window.buffer.closeGroup

end Editor.Evil
