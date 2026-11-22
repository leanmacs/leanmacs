import Editor.Api
import Editor.Command.Call
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Keymap
import Editor.Layout
import Editor.Loop.Driver
import Editor.Package
import Editor.Test.Driver
import Editor.Test.Editing
import Editor.Test.Ex
import Editor.Test.Keys
import Editor.Test.Minibuffer
import Editor.Test.States

/-!
# The test kit: Windows

Stand-ins for the window and tab commands a check of the core needs,
written over the core's API (`ViewId.split`, `ViewId.focus`,
`ViewId.arrange`, `ViewId.newTab`, `changeTab`; `Editor/Api.lean`), so a
check whose subject is the core's frame, its layouts or what is kept of
them makes windows and tabs without naming the packages `window-commands`
and `tab-commands`. Each command is registered under a name of the kit's
own, which starts `test-`, so none is taken for a package's.

- **`splitName`**, **`splitVerticallyName`**: a new window above, or left
  of, the call's window, focused.
- **`focusNextName`**: the next window of the frame's list, wrapping,
  focused.
- **`widerName`**, **`zoomName`**, **`edgeLeftName`**, **`floatName`**: one
  arrangement of the call's window (`Arrange`): a column wider, zoomed,
  docked at the left edge, floating.
- **`newTabName`**: a new tab after the tab in view, its one window on the
  call's window's buffer, focused.
- **`nextTabName`**, **`previousTabName`**: the tab after, or before, the
  tab in view, wrapping.
- **`closeTabName`**: the tab in view closed, with every window of it.
- **`renameTabName`**: the tab in view named by the call's first argument,
  a string.

A command the frame refuses gives up with the refusal's sentence
(`orGiveUp`), as a package's does.

`Windows.package` registers them all, as a package named `test-windows`.

## The drivers' generic half

What the window and tab checks, the packages' and the core's, are driven
through, on the test scheme (`Editor/InputScheme/Test.lean`), taking the
commands and the key table it is handed, so it names no package:

- **`handedOver`**: what a step is handed: the commands it is given under
  their names, with the kit's minibuffer's and the kit's editing commands
  (a printable key types), a layout as config's, and as active keymaps the
  kit's minibuffer's mode's, in the minibuffer's view, then the table it is
  given and `ownKeys` (`C-x` runs the command named `ex`, `C-u` empties the
  minibuffer's input), bound in every view as config's `bindKey` binds one.
- **`windowDriverOver`**: a driver over a number of windows under a layout,
  in cells 16 pixels tall.
- **`countedFed`**: keys pressed, a run of digit keys before a key of the
  table handed to that key's command as its count.
- **`windowOrder`**, **`windowRects`**: what a check reads of the windows.
- **`Windows.table`**, **`Windows.handed`**, **`Windows.fed`**,
  **`Windows.ran`**: the stand-ins on tmux's and Vim's keys under `C-w`,
  for a check of the core that needs windows and tabs made by key
  (`ModelTest.tabBarChecks`), and a stand-in run by name.

It holds no checks. It is pinned by the checks that run on it; what the
packages' own commands do is theirs to check.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import").
-/

namespace Editor.Test.Windows

open Editor

/-- The stand-in that splits the call's window, the new one above. -/
def splitName : String :=
  "test-window-split"

/-- The stand-in that splits the call's window, the new one to the left. -/
def splitVerticallyName : String :=
  "test-window-split-vertically"

/-- The stand-in that focuses the next window of the frame. -/
def focusNextName : String :=
  "test-window-focus-next"

/-- The stand-in that makes the call's window a column wider. -/
def widerName : String :=
  "test-window-wider"

/-- The stand-in that zooms the call's window. -/
def zoomName : String :=
  "test-window-zoom"

/-- The stand-in that docks the call's window at the left edge. -/
def edgeLeftName : String :=
  "test-window-edge-left"

/-- The stand-in that floats the call's window. -/
def floatName : String :=
  "test-window-float"

/-- The stand-in that opens a new tab. -/
def newTabName : String :=
  "test-tab-new"

/-- The stand-in that goes to the next tab. -/
def nextTabName : String :=
  "test-tab-next"

/-- The stand-in that goes to the previous tab. -/
def previousTabName : String :=
  "test-tab-previous"

/-- The stand-in that closes the tab in view. -/
def closeTabName : String :=
  "test-tab-close"

/-- The stand-in that names the tab in view. -/
def renameTabName : String :=
  "test-tab-rename"

/-- Splits the call's window by `placement` and focuses the new window. -/
def split (placement : Placement) (call : Call) : EditorM Unit := do
  let made ← orGiveUp (← call.target.window.id.split placement)
  orGiveUp (← made.focus)

/-- Focuses the next window of the frame's list after the call's,
wrapping; nothing where there is none. -/
def focusNext (call : Call) : EditorM Unit := do
  if let some view := (← editorState).cycled call.target.window.id true 0 then
    orGiveUp (← view.focus)

/-- Makes the change `change` on the call's window. -/
def arranging (change : Arrange) (call : Call) : EditorM Unit := do
  orGiveUp (← call.target.window.id.arrange change)

/-- Opens a new tab after the tab in view, its one window on the call's
window's buffer, and focuses it. -/
def newTab (call : Call) : EditorM Unit := do
  let made ← orGiveUp (← call.target.window.id.newTab)
  orGiveUp (← made.focus)

/-- Selects the tab `forward` of the tab in view, or the one before it,
wrapping. -/
def stepTab (forward : Bool) (_ : Call) : EditorM Unit := do
  let frame := (← editorState).frame
  let size := frame.tabs.size
  orGiveUp (← changeTab (.select ((frame.tabIndex + (if forward then 1 else size - 1)) % size)))

/-- Closes the tab in view, with every window of it. -/
def closeTab (_ : Call) : EditorM Unit := do
  orGiveUp (← changeTab (.close (← editorState).frame.tabIndex))

/-- Names the tab in view by the call's first argument, a string; an empty
one, or anything else, goes back to the generated label. -/
def renameTab (call : Call) : EditorM Unit := do
  let name :=
    match call.arguments with
    | .str text :: _ => if text.isEmpty then none else some text
    | _ => none
  orGiveUp (← changeTab (.rename (← editorState).frame.tabIndex name))

/-- The kit's stand-ins for the window and tab commands (the module
docs), as a package named `test-windows`. -/
def package : Package :=
  { name := "test-windows"
    setup := do
      commandWith splitName (split { before := true })
      commandWith splitVerticallyName (split { axis := .columns, before := true })
      commandWith focusNextName focusNext
      commandWith widerName (arranging (.resize .columns true 1))
      commandWith zoomName (arranging .zoom)
      commandWith edgeLeftName (arranging (.edge .left))
      commandWith floatName (arranging .float)
      commandWith newTabName newTab
      commandWith nextTabName (stepTab true)
      commandWith previousTabName (stepTab false)
      commandWith closeTabName closeTab
      commandWith renameTabName renameTab }

end Editor.Test.Windows

namespace Editor.Test

open Editor

/-- The keys every driver of the window and tab checks has beside its
table: `C-x` runs the command named `ex`, the kit's ex line's or the ex
package's, whichever the driver is handed, and `C-u` empties the
minibuffer's input (the kit's `minibuffer-delete-to-start`). -/
def windowOwnKeys : List (String × String) :=
  [("C-x", ExLine.name), ("C-u", Test.Minibuffer.deleteToStartName)]

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

/-- A driver of the window checks handed `handed`, over
`windowsUnder count layout`, with config's layout `layout` already applied
and the window `focus` focused, on the editor's models in cells 16 pixels
tall, so that the tiled area of the frame of 640 by 480 is 640 by 464. -/
def windowDriverOver (handed : Loop.Keys TestScheme.scheme) (count : Nat) (layout : Layout)
    (focus : Nat := 0) : Option TestDriver :=
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

/-- The window list, as indices, and the focus of `state`. -/
def windowOrder (state : EditorState) : List Nat × Nat :=
  (state.frame.windows.toList.map (·.index), state.frame.focused.index)

/-- The rectangles of `state`'s windows, each as its view's index and its
x, y, width and height. -/
def windowRects (state : EditorState) : List (Nat × Nat × Nat × Nat × Nat) :=
  state.rects.toList.map fun (view, rect) => (view.index, rect.x, rect.y, rect.width, rect.height)

namespace Windows

/-- The keys of the stand-ins, under `C-w` as tmux's and Vim's are: `C-w s`
splits, `C-w z` zooms, `C-w c` opens a tab, `C-w n` and `C-w p` go to the
next and the previous, and `C-w &` closes the tab in view. -/
def table : List (String × String) :=
  [("C-w s", splitName), ("C-w z", zoomName), ("C-w c", newTabName), ("C-w n", nextTabName),
    ("C-w p", previousTabName), ("C-w &", closeTabName)]

/-- What a step of a check on the stand-ins is handed (`handedOver`): the
kit's ex line's commands and the stand-ins, and the keys of `table`. -/
def handed (layout : Layout := Layout.default) : Loop.Keys TestScheme.scheme :=
  handedOver (exLinePackage.registered.commands ++ package.registered.commands) layout table

/-- `driver` once the keys `typed` names were pressed, a count before a key
of `table` handed to its stand-in (`countedFed`). -/
def fed (driver : TestDriver) (typed : String) : TestDriver :=
  countedFed table driver typed

/-- `driver` once the command `name` has run with `arguments`, as a step of
its own. -/
def ran (driver : TestDriver) (name : String) (arguments : List Argument := []) : TestDriver :=
  (driver.stepped (driver.loop.invoke driver.handed { command := name, arguments })).1

end Windows

end Editor.Test
