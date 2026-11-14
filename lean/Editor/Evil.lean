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
| `Editor/Evil/Compiled.lean` | The commands' registrations, under the names the Vim scheme's invocations carry |

## The move command

`move motions` is the command a move runs: it is a function of the table it
looks the motion's name up in, so the caller supplies the vocabulary.

- **Its arguments are the name of the motion, a string, and the count**, a
  number, with 0 for none, as the Vim scheme lays a move out
  (`Editor/InputScheme/Vim.lean`, "Edits"). The count may be left out,
  which is no count, so a command of config's calls it with a name alone.
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
  whether the cursor moved, since the resting rule is applied here.
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

## Insert state

Insert state is a state whose selection is exclusive: a bar between
characters. The commands here place the bar and insert at it; that what is
typed in one session is one step of the history is the loop's
(`Editor/Loop.lean`, "Insert sessions"), which leaves the buffer's undo
group open while the scheme reports the view as in a session. Nothing here
sets or clears a boundary.

- **Four commands begin an insert**, each by moving the head and then
  entering the state ("Entering a state"; `enterAt`), which makes the
  selection one bar there:

  | Command | Where the insert begins |
  |---|---|
  | `insert` | Before the cursor's cell: the head stays |
  | `append` | After the cursor's cell: one cell on, and not past where the line's content ends, so on an empty line the head stays |
  | `insertLineStart` | At the line's first character that is not a blank, which on a line of blanks only is where the content ends |
  | `appendLineEnd` | Where the line's content ends, before its line break |
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
  commands ignore their count and their register.
- **Not built: any other key in insert state** than `<Escape>` and the
  keys that print. `RET`, `<Backspace>`, `<Tab>` and the arrow keys are
  named keys, which print nothing, and do nothing there.

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
| A new command a Vim key runs | A function of its call here, and its registration in `Editor/Evil/Compiled.lean` |
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
selection, and with both ends on the new head otherwise. A call that names
no motion (`noMotionNamed`) and a name with no motion (`noSuchMotion`) are
each said in the echo area, and nothing moves. -/
def move (motions : Array Vocabulary.Motion) (call : Call) : EditorM Unit := do
  let named : Option (String × Option Nat) :=
    match call.arguments with
    | .str name :: .nat count :: _ => some (name, if count == 0 then none else some count)
    | .str name :: _ => some (name, none)
    | _ => none
  let some (name, count) := named | message noMotionNamed
  let some motion := motions.find? (·.name == name) | message (noSuchMotion name)
  let text := call.target.buffer.text
  let window := call.target.window
  let selection ← call.target.selection
  let some range := selection.ranges[selection.primary]? | throw .badSelection
  -- The kept column holds only while the cursor is where it was kept.
  let wanted := (window.wanted.filter (·.head == range.head)).map (·.column)
  let raw ← motion.target text { head := range.head, count, wanted }
  let head ← rested (restOf call.report) text raw.head
  let anchor := if call.report.selecting then range.anchor else head
  call.target.select { ranges := #[⟨anchor, head⟩], shape := call.report.shape }
  let keeps := if head == range.head then raw.unmoved else raw.wanted
  discard <| window.id.setWanted (keeps.map fun column => { column, head })

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
ignores its count and its register. -/
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

end Editor.Evil
