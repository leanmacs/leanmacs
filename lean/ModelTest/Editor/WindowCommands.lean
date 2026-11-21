import Editor.Command.Model
import Editor.Config.Packages
import Editor.Display
import Editor.Display.Model
import Editor.Floating
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Layout
import Editor.Loop
import Editor.Loop.Driver
import Editor.ModeLine
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Test.Editing
import Editor.Test.States
import Editor.Text
import Editor.Text.Model
import Editor.WindowCommands
import Editor.WindowCommands.Compiled
import ModelTest.Check
import ModelTest.Support.Windows

/-!
# Model tests: `Editor/WindowCommands.lean`

The model tests of `Editor/WindowCommands.lean`: `windowCommandChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The state of the window driver over `count` windows under `layout`,
`focus` focused, once the keys `typed` name were pressed. -/
def windowsAfter (count : Nat) (layout : Layout) (typed : String) (focus : Nat := 0) :
    Option EditorState :=
  (windowDriver count layout focus).map fun driver => (windowFed driver typed).loop.state

/-- The checks of the window commands (`Editor/WindowCommands.lean`), by
key, on the loop's driver over the editor's models, under the test scheme
with the keys of the checks' own table (`windowTable`,
`ModelTest/Support/Windows.lean`) and the kit's minibuffer's, the ex line's
and the window commands handed; a count before a key is its command's
first argument (`windowFed`): Vim 9.1's `C-w` behaviours under the manual split layout,
resizes among them, the reorders, zoom and resizes under master-and-stack,
focus by direction under the three layouts, and the refusals in the echo
area. -/
def windowCommandChecks : List Check :=
  let manual (count : Nat) (typed : String) (focus : Nat := 0) : Option EditorState :=
    windowsAfter count Layout.manual typed focus
  let edged := Layout.edge .left 25 Layout.default
  let floatsOf (state : EditorState) : List Nat := state.frame.floats.toList.map (·.view.index)
  [{  name :=
        "criterion 4, by key: C-w F on a stack window floats it, pinned, centred in the tiled area, focused; C-w F again puts it back at the end of the list; C-w C-w reaches the float and leaves it, which stays; C-w C-c closes it and the focus goes back to the window focused before it"
      run :=
        pure <|
          let after (typed : String) : Option EditorState := windowsAfter 3 Layout.default typed 1
          match after "C-w j C-w F", after "C-w j C-w F C-w F", after "C-w j C-w F C-w C-w",
            after "C-w j C-w F C-w C-w C-w C-w C-w C-w", after "C-w j C-w F C-w C-c" with
          | some floated, some back, some left, some round, some closed =>
            windowOrder floated == ([0, 1], 2) && floatsOf floated == [2] &&
              floated.frame.floats.map (·.pinned) == #[true] &&
              floated.rect? ⟨2⟩ == some { x := 128, y := 116, width := 384, height := 232 } &&
              floated.wellFormed &&
              windowOrder back == ([0, 1, 2], 2) &&
              floatsOf back == [] &&
              windowOrder left == ([0, 1], 0) &&
              floatsOf left == [2] &&
              round.frame.focused == ⟨2⟩ &&
              windowOrder closed == ([0, 1], 1) &&
              floatsOf closed == [] &&
              closed.wellFormed
          | _, _, _, _, _ => false },
    { name :=
        "C-w h from a float reaches the tile wholly left of it; C-w s and C-w o from a float are refused, and the echo area says a floating window is not in the layout; C-w F on the last tile is refused, and the echo area says it cannot leave the tiles"
      run :=
        pure <|
          -- Main is 30 percent wide, and the float narrowed to 10 percent
          -- of 640 is 64 wide at 288, right of main and over the stack.
          let narrow := Layout.masterStack { share := 30 }
          match windowsAfter 3 narrow "C-w F 1 0 C-w < C-w h" 2,
            windowsAfter 2 Layout.default "C-w F C-w s" 1,
            windowsAfter 2 Layout.default "C-w F C-w o" 1,
            windowsAfter 1 Layout.default "C-w F" with
          | some reached, some split, some only, some last =>
            reached.frame.focused == ⟨0⟩ && floatsOf reached == [2] &&
              (reached.frame.floating? ⟨2⟩).map (·.share.width) == some 10 &&
              split.echo ==
                s!"{WindowCommands.splitName}: {(LayoutRefusal.floating ⟨1⟩).describe}" &&
              split.echo == "window-split: a floating window is not in the layout" &&
              only.echo == s!"{WindowCommands.onlyName}: a floating window is not in the layout" &&
              windowOrder only == ([0], 1) &&
              floatsOf only == [1] &&
              last.echo == "window-float: the last tiled window cannot leave the tiles" &&
              windowOrder last == ([0], 0)
          | _, _, _, _ => false },
    { name :=
        "C-w o from main closes every other window, floats among them: a pinned float, and a transient float anchored to a tile that closes with it"
      run :=
        pure <|
          let start : TextM EditorState := do
            let state ← windowsUnder 3 Layout.default
            withFloats { state with frame := { state.frame with chosen := some Layout.default } }
                [(.window ⟨2⟩, false), (.frame, true)]
          match
            (Loop.Driver.over (windowHanded Layout.default) (fun _ => none) start
                (.over { advance := 8, lineHeight := 16 })).toOption with
          | none => false
          | some driver =>
            let only := (windowFed driver "C-w o").loop.state
            windowOrder only == ([0], 0) && floatsOf only == [] && only.windows.size == 1 &&
              only.echo == "" &&
              only.wellFormed },
    { name :=
        "criterion 3, by key: under a layout with a left edge, C-w H docks the window at the left edge, in its strip, focused; C-w l and C-w h move between it and main; C-w C-c closes it and the strip goes; docked again, C-w m makes it main; C-w H again moves it back to the end of the list"
      run :=
        pure <|
          let after (typed : String) : Option EditorState := windowsAfter 2 edged typed 1
          match after "C-w H", after "C-w H C-w l", after "C-w H C-w l C-w h",
            after "C-w H C-w C-c", after "C-w H C-w m", after "C-w H C-w H" with
          | some docked, some right, some left, some closed, some promoted, some back =>
            windowOrder docked == ([0], 1) && docked.frame.docked == #[(⟨1⟩, .left)] &&
              windowRects docked == [(0, 160, 0, 480, 464), (1, 0, 0, 158, 464)] &&
              docked.wellFormed &&
              right.frame.focused == ⟨0⟩ &&
              left.frame.focused == ⟨1⟩ &&
              windowOrder closed == ([0], 0) &&
              closed.frame.docked == #[] &&
              windowRects closed == [(0, 0, 0, 640, 464)] &&
              windowOrder promoted == ([1, 0], 1) &&
              promoted.frame.docked == #[] &&
              windowOrder back == ([0, 1], 1) &&
              back.frame.docked == #[] &&
              windowRects back == [(0, 0, 0, 318, 464), (1, 320, 0, 320, 464)]
          | _, _, _, _, _, _ => false },
    { name :=
        "C-w L under a layout with no right edge is refused, and the echo area says so with the command's name; C-w H on the last tile is refused with lastTile"
      run :=
        pure <|
          match windowsAfter 2 edged "C-w L" 1, windowsAfter 1 edged "C-w H" with
          | some refused, some last =>
            refused.echo == s!"{WindowCommands.edgeRightName}: the layout has no right edge" &&
              windowOrder refused == ([0, 1], 1) &&
              refused.frame.docked == #[] &&
              last.echo == s!"{WindowCommands.edgeLeftName}: {LayoutRefusal.lastTile.describe}" &&
              windowOrder last == ([0], 0)
          | _, _ => false },
    { name :=
        "C-w o from a docked window is refused, as Emacs refuses a side window as the only window, and the echo area says why; from main it closes every other window, the docked one too; C-w b and C-w t reach the docked window and main, and C-w p goes back to the docked window"
      run :=
        pure <|
          let after (typed : String) : Option EditorState := windowsAfter 3 edged typed 2
          match after "C-w H C-w o", after "C-w H C-w l C-w o", after "C-w H C-w t",
            after "C-w H C-w t C-w b", after "C-w H C-w l C-w C-p" with
          | some refused, some only, some top, some bottom, some back =>
            refused.echo == s!"{WindowCommands.onlyName}: {(LayoutRefusal.atEdge ⟨2⟩).describe}" &&
              windowOrder refused == ([0, 1], 2) &&
              refused.frame.docked == #[(⟨2⟩, .left)] &&
              windowOrder only == ([0], 0) &&
              only.frame.docked == #[] &&
              only.wellFormed &&
              top.frame.focused == ⟨0⟩ &&
              bottom.frame.focused == ⟨2⟩ &&
              back.frame.focused == ⟨2⟩
          | _, _, _, _, _ => false },
    { name :=
        "criterion 1, C-w s: two windows on the same buffer with equal markers at first, the new one above and focused, and the windows of the column equal in height; three from one window at 640 by 464 give four rows of 116, the upper three less the divider below them"
      run :=
        pure <|
          let split := (windowDriver 1 Layout.manual).map (windowFed · "C-w s")
          match split, manual 1 "C-w s C-w s C-w s" with
          | some split, some thrice =>
            let state := split.loop.state
            windowOrder state == ([1, 0], 1) &&
              windowRects state == [(1, 0, 0, 640, 230), (0, 0, 232, 640, 232)] &&
              state.windows.all (·.buffer == ⟨0⟩) &&
              selectionOf split ⟨1⟩ == selectionOf split ⟨0⟩ &&
              (selectionOf split ⟨1⟩).isSome &&
              (windowRects thrice).map (·.2.2.2.2) == [114, 114, 114, 116] &&
              thrice.wellFormed
          | _, _ => false },
    { name :=
        "criterion 1, C-w v: the new window on the left and focused; two give three columns equal to a pixel; under a column split, C-w s then C-w v, the heights do not change"
      run :=
        pure <|
          match manual 1 "C-w v", manual 1 "C-w v C-w v", manual 1 "C-w s C-w v" with
          | some once, some twice, some under =>
            windowOrder once == ([1, 0], 1) &&
              windowRects once == [(1, 0, 0, 318, 464), (0, 320, 0, 320, 464)] &&
              windowRects twice ==
                [(2, 0, 0, 211, 464), (1, 213, 0, 211, 464), (0, 426, 0, 214, 464)] &&
              windowRects under ==
                [(2, 0, 0, 318, 230), (1, 320, 0, 320, 230), (0, 0, 232, 640, 232)]
          | _, _, _ => false },
    { name :=
        "criterion 1, C-w C-n (Vim's CTRL-W n): a new window above, focused, on a new empty buffer with no file; the old window keeps its buffer"
      run :=
        pure <|
          match (windowDriver 1 Layout.manual).map (windowFed · "C-w C-n") with
          | none => false
          | some driver =>
            let state := driver.loop.state
            let made := state.window? ⟨1⟩
            windowOrder state == ([1, 0], 1) &&
              windowRects state == [(1, 0, 0, 640, 230), (0, 0, 232, 640, 232)] &&
              (state.window? ⟨0⟩).map (·.buffer) == some ⟨0⟩ &&
              made.any (·.buffer != ⟨0⟩) &&
              (made.bind fun window => state.buffer? window.buffer).any fun buffer =>
                buffer.file.isNone &&
                  (driver.model.texts.texts[buffer.text.index]?).join.map (·.contents) == some "" },
    { name :=
        "criterion 1 and 5, C-w C-c (Vim's CTRL-W c): the window leaves the list and the tree, and the windows of its column are equal again; on the last window it is refused, and the echo area says why"
      run :=
        pure <|
          match manual 1 "C-w s C-w s C-w C-c", manual 1 "C-w C-c" with
          | some closed, some last =>
            windowOrder closed == ([1, 0], 1) &&
              windowRects closed == [(1, 0, 0, 640, 230), (0, 0, 232, 640, 232)] &&
              closed.wellFormed &&
              windowOrder last == ([0], 0) &&
              last.echo == s!"{WindowCommands.closeName}: {LayoutRefusal.onlyWindow.describe}"
          | _, _ => false },
    { name :=
        "C-w q: with several windows it closes the window as C-w C-c does; on the last window it asks the editor to quit"
      run :=
        pure <|
          match manual 1 "C-w s C-w q", manual 1 "C-w q" with
          | some closed, some last =>
            windowOrder closed == ([0], 0) && !closed.quitting && last.quitting
          | _, _ => false },
    { name :=
        "C-w o: every other window is closed, and the window it was run in takes the whole tiled area; with one window it says so"
      run :=
        pure <|
          match manual 1 "C-w s C-w v C-w o", manual 1 "C-w o" with
          | some only, some alone =>
            windowOrder only == ([2], 2) && windowRects only == [(2, 0, 0, 640, 464)] &&
              only.wellFormed &&
              alone.echo == WindowCommands.alreadyOnly
          | _, _ => false },
    { name :=
        "criterion 1 and 4, C-w h j k l under manual splits: in a 2 by 2 grid each direction reaches the neighbour and at an edge nothing changes; in a column beside a row, left from the column reaches the top of the row; a count of 2 goes two windows"
      run :=
        pure <|
          let grid :=
            Splits.split .rows 1 1 (.split .columns 1 1 .tile .tile)
              (.split .columns 1 1 .tile .tile)
          let beside := Splits.split .columns 1 1 (.split .rows 1 1 .tile .tile) .tile
          let row := Splits.even .columns 3
          let focus (count : Nat) (tree : Splits) (typed : String) (start : Nat := 0) :
            Option Nat :=
            (windowsAfter count (.splits tree) typed start).map (·.frame.focused.index)
          focus 4 grid "C-w l" == some 1 && focus 4 grid "C-w l C-w j" == some 3 &&
            focus 4 grid "C-w l C-w j C-w h" == some 2 &&
            focus 4 grid "C-w l C-w j C-w h C-w k" == some 0 &&
            focus 4 grid "C-w h C-w k" == some 0 &&
            (windowsAfter 4 (.splits grid) "C-w h").any (·.echo.isEmpty) &&
            focus 3 beside "C-w l" == some 2 &&
            focus 3 beside "C-w h" 2 == some 0 &&
            focus 3 beside "C-w j" == some 1 &&
            focus 3 row "2 C-w l" == some 2 },
    { name :=
        "criterion 1, C-w C-w (Vim's CTRL-W w) and C-w W: the next and the previous window in the tree's order, the last wrapping to the first and the first to the last; with a count, the Nth window"
      run :=
        pure <|
          let focus (typed : String) : Option Nat := (manual 3 typed).map (·.frame.focused.index)
          focus "C-w C-w" == some 1 && focus "C-w C-w C-w C-w C-w C-w" == some 0 &&
            focus "3 C-w C-w" == some 2 &&
            focus "C-w W" == some 2 &&
            focus "2 C-w W" == some 1 },
    { name :=
        "the selected window's mode line follows the focus: from view 0 of three, C-w C-w moves mode-line.active to view 1's row and again to view 2's, and the other two rows are in mode-line.inactive; three more come back to view 0"
      run :=
        pure <|
          let faces (typed : String) : Option (Array (Option FaceName)) :=
            (windowDriver 3 Layout.default).bind fun driver =>
              (windowFed driver typed).model.display.scenes.back?.map (·.views.map (·.statusFace))
          let active := some ModeLine.activeFace
          let inactive := some ModeLine.inactiveFace
          faces "C-w C-w" == some #[inactive, active, inactive] &&
            faces "C-w C-w C-w C-w" == some #[inactive, inactive, active] &&
            faces "C-w C-w C-w C-w C-w C-w" == some #[active, inactive, inactive] },
    { name := "criterion 1, C-w t and C-w b: the first and the last window of the tree's order"
      run :=
        pure <|
          (manual 3 "C-w b").map (·.frame.focused.index) == some 2 &&
            (manual 3 "C-w b C-w t").map (·.frame.focused.index) == some 0 },
    { name :=
        "criterion 1, C-w C-p (Vim's CTRL-W p): after C-w s it goes back to the window split, and again forth; with no last window it is refused, and the echo area says why"
      run :=
        pure <|
          match manual 1 "C-w s C-w C-p", manual 1 "C-w s C-w C-p C-w C-p", manual 1 "C-w C-p" with
          | some back, some forth, some missing =>
            back.frame.focused == ⟨0⟩ && forth.frame.focused == ⟨1⟩ &&
              missing.echo ==
                s!"{WindowCommands.lastName}: {LayoutRefusal.noPreviousWindow.describe}"
          | _, _, _ => false },
    { name :=
        "criterion 1, C-w =: every split back to its slot counts, so a column beside a column gives equal columns, and equal rows in each"
      run :=
        pure <|
          let tree :=
            Splits.split .columns 7 3 (.split .rows 1 4 .tile .tile) (.split .rows 2 1 .tile .tile)
          (windowsAfter 4 (.splits tree) "C-w =").map windowRects ==
            some
              [(0, 0, 0, 318, 230), (1, 0, 232, 318, 232), (2, 320, 0, 320, 230),
                (3, 320, 232, 320, 232)] },
    { name :=
        "C-w x exchanges the window with the next and puts the focus in the other window; C-w r and C-w R rotate a row of windows, the focus staying in its window"
      run :=
        pure <|
          let row := Layout.splits (Splits.even .columns 3)
          (manual 3 "C-w x").map windowOrder == some ([1, 0, 2], 1) &&
            (windowsAfter 3 row "C-w r").map windowOrder == some ([2, 0, 1], 0) &&
            (windowsAfter 3 row "C-w R").map windowOrder == some ([1, 2, 0], 0) },
    { name :=
        "criterion 3, by key under master-and-stack from views 0, 1 and 2 focused on 2: C-w m makes 2 main, C-w M demotes it again, C-w r rotates the stack and C-w R back; C-w z leaves one view in the scene, the focused one, over the tiled area, and C-w z again gives the three views and master-and-stack back"
      run :=
        pure <|
          let after (typed : String) : Option (List Nat × Nat) :=
            (windowsAfter 3 Layout.default typed 2).map windowOrder
          let scene (typed : String) : Option (List (Nat × Rect) × Layout) :=
            (windowDriver 3 Layout.default 2).bind fun driver =>
              let driver := windowFed driver typed
              driver.model.display.scenes.back?.map fun scene =>
                (scene.views.toList.map fun view => (view.id.index, view.rect),
                  driver.loop.state.frame.layout)
          let tiled : Rect := { x := 0, y := 0, width := 640, height := 464 }
          after "C-w m" == some ([2, 0, 1], 2) && after "C-w m C-w M" == some ([0, 2, 1], 2) &&
            after "C-w m C-w M C-w r" == some ([0, 1, 2], 2) &&
            after "C-w m C-w M C-w r C-w R" == some ([0, 2, 1], 2) &&
            scene "C-w z" == some ([(2, tiled)], .monocle) &&
            (scene "C-w z C-w z").map (fun (views, layout) => (views.map (·.1), layout)) ==
              some ([0, 1, 2], Layout.default) },
    { name :=
        "resize by key under master-and-stack: C-w > on main makes the share 55 and on a stack window 45, with a count 60; C-w , and C-w . change main's count"
      run :=
        pure <|
          let layout (typed : String) (focus : Nat := 0) : Option Layout :=
            (windowsAfter 2 Layout.default typed focus).map (·.frame.layout)
          layout "C-w >" == some (.masterStack { share := 55 }) &&
            layout "C-w >" 1 == some (.masterStack { share := 45 }) &&
            layout "2 C-w >" == some (.masterStack { share := 60 }) &&
            layout "C-w <" == some (.masterStack { share := 45 }) &&
            layout "C-w ," == some (.masterStack { count := 2 }) &&
            layout "C-w , C-w ." == some Layout.default },
    { name :=
        "while zoomed, by key: under master-and-stack C-w , leaves the one view shown and C-w z then shows two windows in main, and C-w > then C-w z shows main wider; under manual splits C-w = then C-w z shows the rows balanced"
      run :=
        pure <|
          let rects (layout : Layout) (count : Nat) (typed : String) :
            Option (List (Nat × Nat × Nat × Nat × Nat)) :=
            (windowsAfter count layout typed).map windowRects
          rects Layout.default 3 "C-w z C-w ," == some [(0, 0, 0, 640, 464)] &&
            rects Layout.default 3 "C-w z C-w , C-w z" ==
              some [(0, 0, 0, 318, 230), (1, 0, 232, 318, 232), (2, 320, 0, 320, 464)] &&
            rects Layout.default 2 "C-w z C-w > C-w z" ==
              some [(0, 0, 0, 350, 464), (1, 352, 0, 288, 464)] &&
            rects (.splits (.split .rows 7 3 .tile .tile)) 2 "C-w z C-w = C-w z" ==
              some [(0, 0, 0, 640, 230), (1, 0, 232, 640, 232)] },
    { name :=
        "resize by key under manual splits, after C-w s at 640 by 464: C-w + makes the focused top row 5 percent of the extent taller and C-w - shorter, with a count 10 percent; on the bottom row C-w + grows it and shrinks the top; C-w > in a tree of rows only, and C-w + and C-w - under master-and-stack on the left, are refused, and the echo area says why"
      run :=
        pure <|
          let heights (typed : String) : Option (List Nat) :=
            (manual 1 typed).map fun state => (windowRects state).map (·.2.2.2.2)
          let rowsRefused := (LayoutRefusal.notResizable .rows).describe
          heights "C-w s C-w +" == some [253, 209] && heights "C-w s C-w -" == some [206, 256] &&
            heights "C-w s 2 C-w +" == some [276, 186] &&
            heights "C-w s C-w j C-w +" == some [206, 256] &&
            heights "C-w s C-w j C-w -" == some [253, 209] &&
            (windowsAfter 2 Layout.default "C-w +").map (·.echo) ==
              some s!"{WindowCommands.tallerName}: {rowsRefused}" &&
            (windowsAfter 2 Layout.default "C-w -").map (·.echo) ==
              some s!"{WindowCommands.shorterName}: {rowsRefused}" &&
            match manual 1 "C-w s C-w >" with
            | none => false
            | some wider =>
              (windowRects wider).map (·.2.2.2.2) == [230, 232] &&
                wider.echo ==
                  s!"{WindowCommands.widerName}: {(LayoutRefusal.notResizable .columns).describe}" },
    { name :=
        "criterion 4, by key: under master-and-stack C-w l from main reaches the top of the stack, C-w j walks it and C-w h comes back to main; under monocle no window is in any direction and the focus stays"
      run :=
        pure <|
          let focus (layout : Layout) (typed : String) : Option Nat :=
            (windowsAfter 3 layout typed).map (·.frame.focused.index)
          focus Layout.default "C-w l" == some 1 && focus Layout.default "C-w l C-w j" == some 2 &&
            focus Layout.default "C-w l C-w j C-w h" == some 0 &&
            focus .monocle "C-w l" == some 0 &&
            focus .monocle "C-w j" == some 0 },
    { name :=
        "window-close, window-only and window-quit on the minibuffer's view, by a config's binding that holds there, over two windows: each is refused with ofMinibuffer, the echo area says why under the command's name, no window is closed, and the prompt stays open"
      run :=
        pure <|
          let table :=
            [("C-w C-c", WindowCommands.closeName), ("C-w o", WindowCommands.onlyName),
              ("C-w q", WindowCommands.quitName)]
          let refused (typed name : String) : Bool :=
            match (windowDriver 2 Layout.manual 0).map (windowFed · s!"C-x {typed}") with
            | none => false
            | some driver =>
              let state := driver.loop.state
              state.prompt.isSome && (windowOrder state).1 == [0, 1] && !state.quitting &&
                state.echo == s!"{name}: {(LayoutRefusal.ofMinibuffer ⟨0⟩).describe}"
          table.all fun (typed, name) => refused typed name },
    { name :=
        "the window-commands package registers the commands WindowCommands.names lists, in that order, and no other"
      run :=
        pure
          ((WindowCommands.package.registered.commands.map (·.name)).toList ==
              WindowCommands.names &&
            !WindowCommands.names.isEmpty) }]

end ModelTest
