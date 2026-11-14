import Editor.InputScheme
import Editor.Text

/-!
# Evil

Vim's states, motions and commands written on the editor API
(`docs/design/keymaps-and-modes.md`, "The Vim scheme"). The Vim scheme
(`Editor/InputScheme/Vim.lean`) is the grammar: keys in, an invocation out,
with no editor API. This module is what those invocations run: programs
over the editor's port, which name no key. `Editor.lean` imports it, so
config can call them.

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

Pinned by `ModelTest.evilRestChecks`, on the text model.
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

end Editor.Evil
