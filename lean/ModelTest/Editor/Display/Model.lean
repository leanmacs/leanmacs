import Editor.Display
import Editor.Display.Model
import Editor.Program
import Editor.Scene
import Editor.Text
import ModelTest.Check
import ModelTest.Support.Display

/-!
# Model tests: `Editor/Display/Model.lean`

The model tests of `Editor/Display/Model.lean`: `displayChecks` and
`frameDisplayChecks`. The root module `ModelTest` runs them; its module doc says
what each shows.
-/

namespace ModelTest

open Editor

/-- The rows the display model over `texts` answers to `query`. -/
def shownBy (texts : List String) (query : Display.RowsQuery)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) :
    DisplayError ⊕ Array Display.Row :=
  answered ((Display.rowsShown query).runModel (displayOver texts cells)).1

/-- The checks of the display model that only it shows: what it recorded of
the scenes published to it. What it answers to the queries is the display
interface's contract (`displayFailures`). -/
def displayChecks : List Check :=
  [{
      name :=
        "the scenes published to the display model read back equal, in the order they were published",
      run := do
        let first := twoViews
        let second :=
          { twoViews with
            pending := "", echo := "" }
        let third :=
          { twoViews with
            views := #[], focused := none }
        let program : DisplayM Unit := do
          Display.publish first
          Display.publish second
          Display.publish third
        let (result, model) := program.runModel (displayOver [])
        return result matches .ok () && model.scenes == #[first, second, third] },
    { name := "a display model that nothing was published to has no scene"
      run := pure ((displayOver ["a"]).scenes == #[]) },
    { name :=
        "the layout rule in cells of 8 by 16: a width is cut down to whole cells, a height to whole rows, and a carriage return before a line feed is part of the break"
      run :=
        pure
          (shownBy ["abcdef\r\nxy"] { snapshot := ⟨0⟩, width := 39, height := 47, anchor := 0 }
                (cells := { advance := 8, lineHeight := 16 }) ==
              .inr #[⟨0, 4⟩, ⟨4, 6⟩] &&
            shownBy ["abcdef\r\nxy"] { snapshot := ⟨0⟩, width := 39, height := 48, anchor := 0 }
                (cells := { advance := 8, lineHeight := 16 }) ==
              .inr #[⟨0, 4⟩, ⟨4, 6⟩, ⟨8, 10⟩]) },
    { name := "a view narrower than a cell still shows one character a row"
      run :=
        pure
          (shownBy ["abc"] { snapshot := ⟨0⟩, width := 3, height := 32, anchor := 0 } (cells :=
              { advance := 8, lineHeight := 16 }) ==
            .inr #[⟨0, 1⟩, ⟨1, 2⟩]) },
    { name := "a carriage return that is not before a line feed is a character of its own"
      run :=
        pure
          (shownBy ["a\rb"] { snapshot := ⟨0⟩, width := 2, height := 2, anchor := 0 } ==
            .inr #[⟨0, 2⟩, ⟨2, 3⟩]) },
    { name :=
        "across a shorter line the position stops at its end, and the goal passed back brings it to the start's column again"
      run :=
        pure
          (movedBy [wrapping] 4 3 2 none == .inr ⟨9, 3⟩ &&
            movedBy [wrapping] 4 9 (-2) (some 3) == .inr ⟨3, 3⟩ &&
            movedBy [wrapping] 4 9 (-2) none == .inr ⟨2, 2⟩) },
    { name :=
        "a row a line wraps after holds no end-of-line position: aiming past it lands on its last character"
      run := pure (movedBy [wrapping] 4 9 1 (some 6) == .inr ⟨13, 6⟩) },
    { name := "the goal is in pixels: a column times the cells' advance"
      run :=
        pure
          (movedBy [wrapping] 32 3 2 none (cells := { advance := 8, lineHeight := 16 }) ==
            .inr ⟨9, 24⟩) },
    { name :=
        "a wide character is two cells: the position after 世 is two cells in, and a move that aims for either of its cells lands on it; 😀 is one cell"
      run :=
        pure
          (movedBy ["世b"] 10 3 0 none == .inr ⟨3, 2⟩ &&
            movedBy ["世b"] 10 3 0 (some 0) == .inr ⟨0, 0⟩ &&
            movedBy ["世b"] 10 3 0 (some 1) == .inr ⟨0, 1⟩ &&
            movedBy ["世b"] 10 0 0 (some 2) == .inr ⟨3, 2⟩ &&
            movedBy ["😀b"] 10 4 0 none == .inr ⟨4, 1⟩) },
    { name :=
        "a tab stops at a multiple of eight cells from its line's start, also after a wide character and on a later line"
      run :=
        pure
          (movedBy ["世\tb"] 20 4 0 none == .inr ⟨4, 8⟩ &&
            movedBy ["xyz\nabcdefghi\tb"] 20 14 0 none == .inr ⟨14, 16⟩ &&
            movedBy ["a\tb"] 160 2 0 none (cells := { advance := 8, lineHeight := 16 }) ==
              .inr ⟨2, 64⟩) },
    { name :=
        "a character is of the row its first cell is in, also when its second cell is past the width"
      run :=
        pure
          (shownBy ["ab世cd"] { snapshot := ⟨0⟩, width := 4, height := 3, anchor := 0 } ==
              .inr #[⟨0, 5⟩, ⟨5, 7⟩] &&
            shownBy ["abc世d"] { snapshot := ⟨0⟩, width := 4, height := 3, anchor := 0 } ==
              .inr #[⟨0, 6⟩, ⟨6, 7⟩]) }]

/-- The checks of a request of the window through the display interface,
on its model. -/
def frameDisplayChecks : List Check :=
  [{  name :=
        "a frame request is recorded by the model in order and changes no answer of rows, a move or the heights"
      run := do
        let query : Display.RowsQuery := { snapshot := ⟨0⟩, width := 2, height := 4, anchor := 0 }
        let move : Display.MoveQuery :=
          { snapshot := ⟨0⟩, width := 2, position := 0, lines := 1, goal := none }
        let ask : DisplayM _ := do
          return (← Display.rowsShown query, ← Display.linesFrom move, ← Display.heights)
        let program : DisplayM _ := do
          Display.askFrame .enterFullscreen
          Display.askFrame .minimise
          let answers ← ask
          Display.askFrame .leaveFullscreen
          return answers
        let (asked, model) := program.runModel (displayOver ["abcd"])
        let (unasked, plain) := ask.runModel (displayOver ["abcd"])
        return asked.toOption == unasked.toOption && asked.toOption.isSome &&
            model.asked == #[.enterFullscreen, .minimise, .leaveFullscreen] &&
            plain.asked.isEmpty &&
            model.scenes.isEmpty }]

end ModelTest
