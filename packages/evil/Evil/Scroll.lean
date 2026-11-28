import Evil

/-!
# Evil's scroll commands

The commands that scroll a view, each a function of its call
(`Evil.lean`): Vim's `C-d`, `C-u`, `C-f` and `C-b`, which move the
view and its cursor by rows, and `z t`, `z z` and `z b`, which put the
cursor's row at the top, in the middle and at the bottom of the view. Where
a view's scroll anchor goes is the policy of `Editor/Scroll.lean`; a
command here asks it and places the anchor (`Target.scrollTo`,
`Editor/Api.lean`). It asks the display through its view's area
(`Target.onArea`), so nothing of layout is kept here.

They are evil's commands and not the loop's: the four that move the cursor
rest it by what the input scheme reports of the view and keep a visual
selection's other end, which they read from their call's report, as the
move command does.

## Scrolling by rows

`scroll amount down` is the command `C-d` and `C-u` run, with half a view,
and `C-f` and `C-b`, with a view. The anchor and the cursor move by the
same number of rows.

- **How many rows** (`Scroll.Amount.rows`). Half a view is half the rows
  the view fits and at least one, or the count when one was typed. A view
  is the rows the view fits, times the count when one was typed. The count
  is the call's first argument, 0 for none, as the Vim scheme lays a
  command's call out.
- **The anchor going down** moves that many rows, and no further than
  where the text's last row is the last row shown; it never moves up. **The
  anchor going up** moves that many rows and stops at the text's first row
  (`Scroll.down`, `Scroll.up`).
- **The cursor** moves that many visual rows (`Display.linesFrom` from the
  head of the primary range, with no goal, so it keeps its x), stops at
  the text's first and last row, and is then rested by the rule of the
  call's report (`rested`, `restOf`), as a motion's target is. The
  selection is one range of the report's shape. Its other end is kept
  where the report says a motion extends the selection, so the command
  extends a visual selection. The window then keeps no wanted column, as
  after every motion but the vertical ones.
- **A cursor the move leaves in the empty last row** of a text that ends
  in a line break, in a state where no cursor rests there, goes one row
  back up at the same x: a second move, with the goal the first passed
  back. Without it the resting rule would put the cursor on the last
  line's last character and lose the column, on every file that ends in a
  line feed.
- **After it the cursor is among the rows shown.** Where neither the
  anchor nor the cursor stopped, both moved the same rows. Where one
  stopped, the loop's follow holds it at the next scene
  (`Editor/Loop.lean`, "Following the cursor"), with the scroll margin,
  which a command here does not read.
- **At the text's end** going down moves the anchor until the text's last
  row is the last row shown, then the cursor alone, until it is on the
  last line. There it changes nothing and says nothing. **At the start**
  going up does the same, upwards.
- **A view that shows no row**: nothing moves and nothing is said. So in a
  frame of no height, which every headless run that does not resize has,
  the commands do nothing.
- **They are commands and not motions**, so an operator's key before one
  is dropped, as in Vim. They change no text, so they are not the last
  change and `.` does not replay one.
- **A command that does not run to its end leaves the anchor and the
  selection as they were**: the loop keeps and restores both markers. One
  that is interrupted leaves the snapshot `Target.onArea` took
  (`Editor/Api.lean`, "Scrolling").

Where this departs from Vim. Vim's column is its documentation
(`scroll.txt`, `'scroll'`, `'startofline'`) as remembered: it was not read
again for this, and no check runs Vim.

| | Vim | Here |
|---|---|---|
| The unit | Lines of the buffer | Visual rows, so a wrapped line is scrolled through row by row |
| A count before `C-d` | Sets the `scroll` option, which later `C-d` and `C-u` use | Is the rows of this one command |
| The column | The first non-blank, under `startofline`, which Vim sets and Neovim does not | Kept, as Neovim's default |
| On the last line, or the first | Beeps | Nothing |
| A text shorter than its view | Moves the cursor half the window's height | Half the text's rows: how many rows fit a view that is not full is not asked (`Editor/Scroll.lean`) |
| A text that ends in a line feed | No row after the last line | The empty row the display lays out after it is the last row shown |
| `C-f` and `C-b` | Keep two lines of the page before in view and put the cursor on the new page's first line | The anchor moves a whole view and the cursor keeps its row of the view |

## Scrolling to the cursor's row

`scrollLineTo place` is the command `z t`, `z z` and `z b` run: it places
the anchor so that the cursor's row is the first row shown, the middle one
or the last (`Scroll.lineTo`), and does nothing else.

- **The middle** is the middle row of those the view fits, the upper of
  the two when it fits an even number: the third of five, and the third of
  six.
- **In a view that shows its whole text `z z` shows it from its first
  row**, wherever the cursor is, so no row that fits is hidden. That is
  Vim's view where the cursor's row is above the view's middle. It departs
  from Vim in a view its text fills exactly, or nearly, with the cursor
  below the view's middle, where Vim scrolls: how many rows such a view
  has room for is not asked (`Editor/Scroll.lean`, "A view that shows its
  whole text"). `z b` there shows the text from its first row too, and
  `z t` shows from the cursor's row, past the text's end.
- **The text, the selection and the wanted column are not touched.** It
  ignores its count and its register: Vim's count is a line number, which
  is not built.
- **At the text's start** the anchor stops at the first row, so `z z` and
  `z b` cannot put a cursor near the start in the middle or at the bottom,
  as in Vim. **At its end** `z t` and `z z` show past the text's end, as
  Vim does.
- **It works from the rows the view fits, not the rows it shows.** After
  `z t` on the last line the view shows one row; with that as the view's
  rows `z b` would do nothing. So `G`, `z t`, `z b` comes back to the view
  `G` left.
- **With a scroll margin set** the follow before the next scene moves the
  anchor again to hold it (`Editor/Loop.lean`, "Following the cursor"), so
  `z t` with a margin of two leaves two rows above the cursor's row, as
  Vim's does with `scrolloff`. In a view that shows its whole text the
  margin is held as set, and not at half the text's rows.
- **A view that shows no row**: nothing moves and nothing is said.

Pinned by `EvilTest.evilScrollChecks`, by key, on the loop's driver over the
editor's models under the Vim scheme that ships, and the keys through the
grammar by `EvilTest.vimDefaultChecks`.
-/

namespace Editor.Evil

/-- The command that scrolls the call's view by rows, as it is called
("Scrolling by rows", in the module docs): `amount` of the view, half of it
or all of it, with the call's count, down when `down` and up otherwise. The
view's scroll anchor and the head of the primary range of its selection
move by that many visual rows, the anchor no further than where the text's
last row is the last row shown, or its first row the first. The head is
rested by the rule of the call's report, and the selection is one range of
the report's shape, from the anchor it had where the report says a motion
extends the selection. The window then keeps no wanted column. In a view
that shows no row nothing moves. -/
def scroll (amount : Scroll.Amount) (down : Bool) (call : Call) : EditorM Unit := do
  discard <|
      call.target.onArea fun area => do
        let fits ← area.fits
        if fits == 0 then
          return
        let rows := amount.rows (countOf call) fits
        let anchor ← call.target.anchor
        let selection ← call.target.selection
        let some range := selection.ranges[selection.primary]? | throw .badSelection
        let placed ←
          if down then
            Scroll.down area anchor.offset rows fits
          else
            Scroll.up area anchor.offset rows fits
        if let some offset := placed then
          call.target.scrollTo offset
        let move (position : Nat) (lines : Int) (goal : Option Nat) : EditorM Display.Moved :=
          Display.linesFrom
            { snapshot := area.snapshot, width := area.width, across := area.padding.across,
              gutter := area.padding.gutter
              position, lines, goal, folds := area.folds }
        let moved ← move range.head (if down then (rows : Int) else -(rows : Int)) none
        let text := call.target.buffer.text
        let rule := restOf call.report
        let length ← text.byteLength
        -- The empty last row of a text that ends in a line break is no line
        -- for a cursor that cannot rest anywhere: one row back up, at the
        -- same x.
        let moved ←
          if
              rule != .anywhere && moved.position == length && length > 0 &&
                (← text.motion .lineStart length) == length then
            move length (-1) (some moved.goal)
          else
            pure moved
        let head ← rested rule text moved.position
        let start := if call.report.selecting then range.anchor else head
        call.target.select { ranges := #[⟨start, head⟩], shape := call.report.shape }
        discard <| call.target.window.id.setWanted none

/-- The command that scrolls the call's view to its cursor's row, as it is
called ("Scrolling to the cursor's row", in the module docs): the view's
scroll anchor is placed so that the row of the head of the primary range of
its selection is at `place`, the first row shown, the middle one or the
last. The text, the selection and the wanted column are left as they are,
and it ignores its count and its register. In a view that shows no row
nothing moves. -/
def scrollLineTo (place : Scroll.Place) (call : Call) : EditorM Unit := do
  discard <|
      call.target.onArea fun area => do
        let selection ← call.target.selection
        let some range := selection.ranges[selection.primary]? | throw .badSelection
        if let some offset← Scroll.lineTo place area range.head then
          call.target.scrollTo offset

end Editor.Evil
