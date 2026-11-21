import Editor.Command.Call
import Editor.Command.Model
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Display
import Editor.Ex
import Editor.Ex.Compiled
import Editor.InputScheme.Test
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
import Editor.Test.Driver
import Editor.Test.Editing
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Minibuffer
import Editor.Test.States
import Editor.Text
import Editor.WindowCommands.Compiled

/-!
# Model tests: support: Windows

The window and tab commands' keys, driver and what a check reads of the
windows and tabs, on the test scheme (`Editor/InputScheme/Test.lean`): the
checks press keys of a table of their own (`windowTable`, `tabTable`),
bound in every view as config's `bindKey` binds one, so they name no scheme
package's states or tables. That a scheme's own tables run these commands
on its keys is that scheme's package's to check. Shared by several test
modules under `ModelTest/Editor/`; it holds no checks of its own.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The keys of the window checks: each key string, and the name of the
window command (`Editor/WindowCommands.lean`) it runs. The spellings are
Vim's `CTRL-W` commands', which the checks' names say. -/
def windowTable : List (String × String) :=
  [("C-w s", "window-split"), ("C-w S", "window-split"), ("C-w C-s", "window-split"),
    ("C-w v", "window-split-vertically"), ("C-w C-v", "window-split-vertically"),
    ("C-w C-n", "window-new"), ("C-w C-c", "window-close"), ("C-w q", "window-quit"),
    ("C-w C-q", "window-quit"), ("C-w o", "window-only"), ("C-w C-o", "window-only"),
    ("C-w h", "window-focus-left"), ("C-w C-h", "window-focus-left"),
    ("C-w <ArrowLeft>", "window-focus-left"), ("C-w <Backspace>", "window-focus-left"),
    ("C-w j", "window-focus-down"), ("C-w C-j", "window-focus-down"),
    ("C-w <ArrowDown>", "window-focus-down"), ("C-w k", "window-focus-up"),
    ("C-w C-k", "window-focus-up"), ("C-w <ArrowUp>", "window-focus-up"),
    ("C-w l", "window-focus-right"), ("C-w C-l", "window-focus-right"),
    ("C-w <ArrowRight>", "window-focus-right"), ("C-w C-w", "window-focus-next"),
    ("C-w W", "window-focus-previous"), ("C-w t", "window-focus-top"),
    ("C-w C-t", "window-focus-top"), ("C-w b", "window-focus-bottom"),
    ("C-w C-b", "window-focus-bottom"), ("C-w C-p", "window-focus-last"),
    ("C-w x", "window-exchange"), ("C-w C-x", "window-exchange"), ("C-w r", "window-rotate"),
    ("C-w C-r", "window-rotate"), ("C-w R", "window-rotate-back"), ("C-w =", "window-balance"),
    ("C-w +", "window-taller"), ("C-w -", "window-shorter"), ("C-w >", "window-wider"),
    ("C-w <", "window-narrower"), ("C-w z", "window-zoom"), ("C-w m", "window-promote"),
    ("C-w M", "window-demote"), ("C-w ,", "window-main-more"), ("C-w .", "window-main-fewer"),
    ("C-w H", "window-edge-left"), ("C-w J", "window-edge-bottom"), ("C-w K", "window-edge-top"),
    ("C-w L", "window-edge-right"), ("C-w F", "window-float")]

/-- The keys of the tab checks: tmux's under `C-w`, each with the name of
the tab command (`Editor/TabCommands.lean`) it runs; `C-w 1` to `C-w 9` go
to the tab of that number. -/
def tabTable : List (String × String) :=
  [("C-w n", TabCommands.nextName), ("C-w p", TabCommands.previousName),
      ("C-w c", TabCommands.newName), ("C-w &", TabCommands.closeName),
      ("C-w w", TabCommands.switchName)] ++
    (List.range 9).map fun index => (s!"C-w {index + 1}", TabCommands.selectName (index + 1))

/-- The keys every driver of the window and tab checks has beside its
table: `C-x` opens the ex line, and `C-u` empties the minibuffer's input
(the kit's `minibuffer-delete-to-start`). -/
def windowOwnKeys : List (String × String) :=
  [("C-x", Ex.name), ("C-u", Test.Minibuffer.deleteToStartName)]

/-- What a step of the window and tab checks is handed: the commands
`commands` under their names, with the kit's minibuffer's and the kit's
editing commands (a printable key types), `layout` as config's layout, and
as active keymaps the kit's minibuffer's mode's, in the minibuffer's view,
then `table` and `windowOwnKeys`, bound in every view. -/
def handedOver (commands : Array Config.Registration) (layout : Layout)
    (table : List (String × String)) : Loop.Keys TestScheme.scheme :=
  let registry :=
    (({} : Config.Registry).replace .compiled
          Test.Minibuffer.package.registered.commands).replaceModes
      .compiled Test.Minibuffer.package.registered.modes
  let own : Keymap TestScheme.scheme.Binding :=
    Keymap.ofList ((table ++ windowOwnKeys).map fun (text, name) => (keys text, invoke name))
  { maps := fun state view => registry.activeMaps TestScheme.scheme state view ++ [own]
    command? := fun name =>
      match (Test.Minibuffer.package.registered.commands ++ commands).findRev? (·.name == name) with
      | some { action := .call run, .. } =>
        some fun call => do
          run call
          return none
      | _ => (editingDispatched.find? (·.1 == name)).map (·.2)
    layout := some layout }

/-- What a step of the window checks is handed (`handedOver`): the ex
line's commands and the window commands, and the keys of `windowTable`,
then `more`. -/
def windowHanded (layout : Layout) (more : List (String × String) := []) :
    Loop.Keys TestScheme.scheme :=
  handedOver (Ex.package.registered.commands ++ WindowCommands.package.registered.commands) layout
    (windowTable ++ more)

/-- A driver of the window checks over `windowsUnder count layout`, with
config's layout `layout` already applied and the window `focus` focused, on
the editor's models in cells 16 pixels tall, so that the tiled area of the
frame of 640 by 480 is 640 by 464. -/
def windowDriver (count : Nat) (layout : Layout) (focus : Nat := 0)
    (handed : Loop.Keys TestScheme.scheme := windowHanded layout) : Option TestDriver :=
  let start : TextM EditorState := do
    let state ← windowsUnder count layout
    return { state with
        frame :=
          { state.frame with
            chosen := some layout, focused := ⟨focus⟩ } }
  (Loop.Driver.over handed (fun _ => none) start
      (.over { advance := 8, lineHeight := 16 })).toOption

/-- `driver` once the keys `typed` names were pressed, with a count before
a key of `table` handed to its command: a run of digit keys right before a
key string of `table` is the count of that command's call, its first
argument, as a scheme that has counts lays a count out, and the command is
then run by name; every other key is pressed. -/
def countedFed (table : List (String × String)) (driver : TestDriver) (typed : String) :
    TestDriver :=
  let pressed (driver : TestDriver) (tokens : List String) : TestDriver :=
    if tokens.isEmpty then driver else keysFed driver (" ".intercalate tokens)
  let isDigits (token : String) : Bool := !token.isEmpty && token.all Char.isDigit
  let (driver, digits, pending) :=
    (typed.splitOn " ").filter (!·.isEmpty) |>.foldl
      (fun (driver, digits, pending) token =>
        if pending.isEmpty && isDigits token then (driver, digits ++ [token], pending)
        else
          let pending := pending ++ [token]
          let text := " ".intercalate pending
          match table.find? (·.1 == text) with
          | some (_, name) =>
            if digits.isEmpty then (pressed driver pending, [], [])
            else
              let count := ("".intercalate digits).toNat!
              ((driver.stepped
                    (driver.loop.invoke driver.handed
                      { command := name, arguments := [.nat count] })).1,
                [], [])
          | none =>
            if table.any fun (keys, _) => keys.startsWith (text ++ " ") then
              (driver, digits, pending)
            else (pressed (pressed driver digits) pending, [], []))
      (driver, [], [])
  pressed (pressed driver digits) pending

/-- `driver` once the keys `typed` names were pressed, a count before a
window or a tab key handed to its command (`countedFed`). -/
def windowFed (driver : TestDriver) (typed : String) : TestDriver :=
  countedFed (windowTable ++ tabTable) driver typed

/-- The window list, as indices, and the focus of `state`. -/
def windowOrder (state : EditorState) : List Nat × Nat :=
  (state.frame.windows.toList.map (·.index), state.frame.focused.index)

/-- The rectangles of `state`'s windows, each as its view's index and its
x, y, width and height. -/
def windowRects (state : EditorState) : List (Nat × Nat × Nat × Nat × Nat) :=
  state.rects.toList.map fun (view, rect) => (view.index, rect.x, rect.y, rect.width, rect.height)

/-- What a step of the tab checks is handed (`handedOver`): `windowHanded`'s
commands and the tab commands, and the keys of `windowTable` and
`tabTable`, then `more`. -/
def tabHanded (layout : Layout := Layout.default) (more : List (String × String) := []) :
    Loop.Keys TestScheme.scheme :=
  handedOver
    (Ex.package.registered.commands ++ WindowCommands.package.registered.commands ++
      TabCommands.package.registered.commands)
    layout (windowTable ++ tabTable ++ more)

/-- The keys the tab checks bind beside the tables: `tab-rename` on
`C-c r`, `tab-move-right` on `C-c m` and `tab-move-left` on `C-c M`. -/
def tabOwnKeys : List (String × String) :=
  [("C-c r", TabCommands.renameName), ("C-c m", TabCommands.moveRightName),
    ("C-c M", TabCommands.moveLeftName)]

/-- The state of a driver of the tab checks over one window under the
default layout, with `tabOwnKeys` bound, once the keys `typed` name were
pressed. -/
def tabsAfter (typed : String) : Option TestDriver :=
  (windowDriver 1 Layout.default (handed := tabHanded Layout.default tabOwnKeys)).map
    (windowFed · typed)

end ModelTest
