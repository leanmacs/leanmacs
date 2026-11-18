import Editor.Command.Model
import Editor.Config.Registry
import Editor.Display
import Editor.Ex.Compiled
import Editor.InputScheme.Vim
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Job
import Editor.Keymap
import Editor.Layout
import Editor.Loop
import Editor.Loop.Driver
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.TabCommands
import Editor.TabCommands.Compiled
import Editor.Text
import Editor.WindowCommands.Compiled
import ModelTest.Support.Evil
import ModelTest.Support.Loop
import ModelTest.Support.States

/-!
# Model tests: support: Windows

The window and tab commands' maps, driver and what a check reads of the windows
and tabs. Shared by several test modules under `ModelTest/Editor/`; it holds no
checks of its own.
-/

namespace ModelTest

open Editor

/-- Active keymaps, for every view, that bind each key string of `table` to
the command name beside it, as config's `bindKey` binds one. -/
def windowMaps (table : List (String × String)) : EditorState → ViewId → List (Keymap Vim.Bound) :=
  fun _ _ => [Vim.Default.keymap (table.map fun (text, name) => (text, .command { name }))]

/-- What a step of the window checks is handed: evil's commands, the
minibuffer's, the ex line's and the window commands, `layout` as config's
layout, and `maps` as the active keymaps, none unless a check names them,
so the window commands are reached by the keys the Vim scheme that ships
binds. -/
def windowHanded (layout : Layout)
    (maps : EditorState → ViewId → List (Keymap Vim.Bound) := fun _ _ => []) :
    Loop.Keys Vim.Default.scheme :=
  { evilHanded (Ex.commands ++ WindowCommands.commands) with
    layout := some layout, maps }

/-- A driver of the window checks over `windowsUnder count layout`, with
config's layout `layout` already applied and the window `focus` focused, on
the editor's models in cells 16 pixels tall, so that the tiled area of the
frame of 640 by 480 is 640 by 464. -/
def windowDriver (count : Nat) (layout : Layout) (focus : Nat := 0)
    (handed : Loop.Keys Vim.Default.scheme := windowHanded layout) : Option EvilDriver :=
  let start : TextM EditorState := do
    let state ← windowsUnder count layout
    return { state with
        frame :=
          { state.frame with
            chosen := some layout, focused := ⟨focus⟩ } }
  (Loop.Driver.over handed (fun _ => none) start
      (.over { advance := 8, lineHeight := 16 })).toOption

/-- The window list, as indices, and the focus of `state`. -/
def windowOrder (state : EditorState) : List Nat × Nat :=
  (state.frame.windows.toList.map (·.index), state.frame.focused.index)

/-- The rectangles of `state`'s windows, each as its view's index and its
x, y, width and height. -/
def windowRects (state : EditorState) : List (Nat × Nat × Nat × Nat × Nat) :=
  state.rects.toList.map fun (view, rect) => (view.index, rect.x, rect.y, rect.width, rect.height)

/-- What a step of the tab checks is handed: `windowHanded`'s commands and
the tab commands, `layout` as config's layout, and `maps` as the active
keymaps. -/
def tabHanded (layout : Layout := Layout.default)
    (maps : EditorState → ViewId → List (Keymap Vim.Bound) := fun _ _ => []) :
    Loop.Keys Vim.Default.scheme :=
  { evilHanded (Ex.commands ++ WindowCommands.commands ++ TabCommands.commands) with
    layout := some layout, maps }

/-- The state of a driver of the tab checks over one window under the
default layout, `tab-rename` bound to `C-c r`, `tab-move-right` to `C-c m`
and `tab-move-left` to `C-c M`, once the keys `typed` name were pressed. -/
def tabsAfter (typed : String) : Option EvilDriver :=
  let maps :=
    windowMaps
      [("C-c r", TabCommands.renameName), ("C-c m", TabCommands.moveRightName),
        ("C-c M", TabCommands.moveLeftName)]
  (windowDriver 1 Layout.default (handed := tabHanded Layout.default maps)).map (evilFed · typed)

end ModelTest
