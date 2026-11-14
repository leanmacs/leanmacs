import Editor.Api
import Editor.Command.Call
import Editor.Vocabulary

/-!
# Evil

Vim's states, motions and commands written on the editor API
(`docs/design/keymaps-and-modes.md`, "The Vim scheme"). The Vim scheme
(`Editor/InputScheme/Vim.lean`) is the grammar: keys in, an invocation out,
with no editor API. This module is what those invocations run: programs
over the editor's port, which name no key. `Editor.lean` imports it, so
config can call them.

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
  (`Editor/InputScheme/Vim.lean`, "Edits"). A name with no entry says
  `<name>: no such motion` in the echo area and moves nothing.
- **It reads the primary range of its target's selection**, asks the motion
  for the raw target from that range's head, rests the raw target by the
  rule of the call's report ("Where a cursor rests"), and places one range
  with the report's shape, whose two ends are the new head.
- **Placing a marker is no edit**, so a motion is no step of the history.
- **One cursor.** No command makes a second range; this one reads the
  primary range and places one range.

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

Pinned by `ModelTest.evilRestChecks`, on the text model, and the move
command by `ModelTest.evilMotionChecks`, on the loop's driver under the Vim
scheme that ships.

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

/-- The move command over the vocabulary `motions`, as it is called ("The
move command", in the module docs): its first argument names the motion and
its second is the count, 0 for none. The head of the primary range of the
target's selection goes where the motion leads, rested by the rule of the
call's report, and the selection is one range there, of the report's shape.
A name with no motion is said in the echo area, and nothing moves. -/
def move (motions : Array Vocabulary.Motion) (call : Call) : EditorM Unit := do
  let (name, count) :=
    match call.arguments with
    | .str name :: .nat count :: _ => (name, if count == 0 then none else some count)
    | .str name :: _ => (name, none)
    | _ => ("", none)
  let some motion := motions.find? (·.name == name) | message (noSuchMotion name)
  let text := call.target.buffer.text
  let selection ← call.target.selection
  let some range := selection.ranges[selection.primary]? | throw .badSelection
  let raw ← motion.target text { head := range.head, count }
  let head ← rested (restOf call.report) text raw.head
  call.target.select { ranges := #[⟨head, head⟩], shape := call.report.shape }

end Editor.Evil
