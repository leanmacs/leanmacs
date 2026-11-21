import Editor.Api
import Editor.Command.Call
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Package
import Editor.Setup
import Editor.Test.Loop
import Editor.Text

/-!
# The kit's editing commands: a stand-in for a scheme's, on the test scheme

A stand-in for the editing commands an input scheme's package registers,
such as evil's (`Editor/Evil/Compiled.lean`), which no core test and no
other package's test may import. It is written over the core's API alone
(`Editor/Api.lean`), for the test scheme (`Editor/InputScheme/Test.lean`):
a test whose subject is the core, or a feature that is not a scheme, types
text and moves the cursor with these, and drives no key of a real scheme.

- **`self-insert`** is the test scheme's name for a printable key
  (`TestScheme.selfInsert`): its argument, a text, inserted at the
  selections of the call's view.
- **`edit-newline`** inserts a line break in the buffer's line ending, and
  **`edit-delete-backward`** removes each selected range, or, of a bar, the
  character before it.
- **The moves**, `edit-left`, `edit-right`, `edit-up`, `edit-down`,
  `edit-line-start`, `edit-buffer-start` and `edit-buffer-end`, move each
  range to a bar: a character back or on (over a line's end to the next
  line), a row up or down at the same column, counted in characters and
  kept within the row, the start of the row, and the two ends of the text.
- **`edit-select-left`, `-right`, `-up` and `-down`** move each range's
  head so and keep its anchor: a selection extended.
- **`edit-undo` and `edit-redo`** undo and redo one step of the buffer's
  history (`BufferId.undo`, `redo`) and place the selection the step hands
  back; with no step they say `nothing to undo` or `nothing to redo`.

`editingKeys` puts them on keys that print nothing, so none is ever the
test scheme's self-insert: the arrows, `<Backspace>`, `RET`, `<Home>`,
`C-<Home>`, `C-<End>`, the arrows with shift, `C-z` and `C-Z`.

Its names are its own: nothing outside a test registers or runs them. It
grows only by what a check needs, and it holds no checks (the kit's rule):
its commands are pinned by the checks that use them.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import").
-/

namespace Editor.Test

open Editor

namespace Editing

/-- The rows of `text`, each with the byte offset it starts at. -/
def rows (text : String) : List (Nat × String) :=
  ((text.splitOn "\n").foldl
      (fun (acc : List (Nat × String) × Nat) row =>
        (acc.1 ++ [(acc.2, row)], acc.2 + row.utf8ByteSize + 1))
      ([], 0)).1

/-- The row of the byte `offset` of `text`, and its column there in
characters. -/
def placeOf (text : String) (offset : Nat) : Nat × Nat :=
  let rows := rows text
  let row := ((rows.findIdx? fun (start, _) => start > offset).getD rows.length) - 1
  match rows[row]? with
  | some (start, line) =>
    let within := offset - start
    (row,
      (line.toList.foldl
          (fun (acc : Nat × Nat) c =>
            if acc.2 < within then (acc.1 + 1, acc.2 + c.utf8Size) else acc)
          (0, 0)).1)
  | none => (0, 0)

/-- The byte offset of the column `column`, in characters, of the row
`row` of `text`, the column kept within the row and the row within the
text. -/
def offsetAt (text : String) (row column : Nat) : Nat :=
  let rows := rows text
  match rows[min row (rows.length - 1)]? with
  | some (start, line) => start + (String.ofList (line.toList.take column)).utf8ByteSize
  | none => 0

/-- How many characters the row `row` of `text` holds. -/
def widthOf (text : String) (row : Nat) : Nat :=
  ((rows text)[row]?.map (·.2.length)).getD 0

/-- One character back: over the start of a row to the end of the row
before, and nowhere from the start of the text. -/
def left (text : String) (offset : Nat) : Nat :=
  let (row, column) := placeOf text offset
  if column > 0 then offsetAt text row (column - 1)
  else if row > 0 then offsetAt text (row - 1) (widthOf text (row - 1)) else offset

/-- One character on: over the end of a row to the start of the next, and
nowhere from the end of the text. -/
def right (text : String) (offset : Nat) : Nat :=
  let (row, column) := placeOf text offset
  if column < widthOf text row then offsetAt text row (column + 1)
  else if row + 1 < (rows text).length then offsetAt text (row + 1) 0 else offset

/-- One row up at the same column, kept within the row; nowhere from the
first row. -/
def up (text : String) (offset : Nat) : Nat :=
  let (row, column) := placeOf text offset
  if row > 0 then offsetAt text (row - 1) column else offset

/-- One row down at the same column, kept within the row; nowhere from the
last row. -/
def down (text : String) (offset : Nat) : Nat :=
  let (row, column) := placeOf text offset
  if row + 1 < (rows text).length then offsetAt text (row + 1) column else offset

/-- The start of the row. -/
def lineStart (text : String) (offset : Nat) : Nat :=
  offsetAt text (placeOf text offset).1 0

/-- A command that moves each range's head by `motion`, a function of the
text and the head's byte offset; the anchor follows the head, leaving a
bar, unless `keep`. -/
def moved (motion : String → Nat → Nat) (keep : Bool := false) (call : Call) : EditorM Unit := do
  let text ← call.target.buffer.text.read
  let selection ← call.target.selection
  call.target.select
      { selection with
        ranges :=
          selection.ranges.map fun range =>
            let head := motion text range.head
            { anchor := if keep then range.anchor else head, head } }

/-- The test scheme's self-insert: its argument, a text, at the
selections. -/
def selfInsert (call : Call) : EditorM Unit := do
  let [.str text] := call.arguments | throw .badRange
  call.target.insertAtSelections text

/-- Removes each selected range, or, of a bar, the character before it. -/
def deleteBackward (call : Call) : EditorM Unit := do
  let text ← call.target.buffer.text.read
  let selection ← call.target.selection
  call.target.select
      { selection with
        ranges :=
          selection.ranges.map fun range =>
            if range.anchor == range.head then { range with anchor := left text range.head }
            else range }
  call.target.deleteSelections

/-- One step of the buffer's history by `step` (`BufferId.undo` or `redo`),
with the selection it hands back placed; says `nothing` when there is no
step. -/
def stepped (step : BufferId → EditorM (Except BufferRefusal (Option Undone))) (nothing : String)
    (call : Call) : EditorM Unit := do
  match ← step call.target.window.buffer with
  | .ok (some undone) =>
    if let some selection := undone.selection then
      call.target.select selection
  | _ =>
    message nothing

end Editing

/-- The kit's editing commands, by name (the module docs). -/
def editingCommands : List (String × (Call → EditorM Unit)) :=
  [((TestScheme.selfInsert "").command, Editing.selfInsert),
    ("edit-newline", fun call => call.target.insertLineBreak),
    ("edit-delete-backward", Editing.deleteBackward), ("edit-left", Editing.moved Editing.left),
    ("edit-right", Editing.moved Editing.right), ("edit-up", Editing.moved Editing.up),
    ("edit-down", Editing.moved Editing.down), ("edit-line-start", Editing.moved Editing.lineStart),
    ("edit-buffer-start", Editing.moved fun _ _ => 0),
    ("edit-buffer-end", Editing.moved fun text _ => text.utf8ByteSize),
    ("edit-select-left", Editing.moved Editing.left (keep := true)),
    ("edit-select-right", Editing.moved Editing.right (keep := true)),
    ("edit-select-up", Editing.moved Editing.up (keep := true)),
    ("edit-select-down", Editing.moved Editing.down (keep := true)),
    ("edit-undo", Editing.stepped BufferId.undo "nothing to undo"),
    ("edit-redo", Editing.stepped BufferId.redo "nothing to redo")]

/-- The keys of the kit's editing commands, each a key string and the name
of the command it runs: keys that print nothing (the module docs). -/
def editingKeys : List (String × String) :=
  [("<ArrowLeft>", "edit-left"), ("<ArrowRight>", "edit-right"), ("<ArrowUp>", "edit-up"),
    ("<ArrowDown>", "edit-down"), ("<Backspace>", "edit-delete-backward"), ("RET", "edit-newline"),
    ("<Home>", "edit-line-start"), ("C-<Home>", "edit-buffer-start"),
    ("C-<End>", "edit-buffer-end"), ("S-<ArrowLeft>", "edit-select-left"),
    ("S-<ArrowRight>", "edit-select-right"), ("S-<ArrowUp>", "edit-select-up"),
    ("S-<ArrowDown>", "edit-select-down"), ("C-z", "edit-undo"), ("C-Z", "edit-redo")]

/-- The kit's editing commands as a driver's dispatch takes them
(`dispatchKeys`, `Editor/Test/Loop.lean`). -/
def editingDispatched : List (String × Dispatched) :=
  editingCommands.map fun (name, run) =>
    (name, fun call => do
      run call
      return none)

/-- The kit's editing keys as a driver's dispatch takes them
(`dispatchKeys`): each key string with the invocation of its command. -/
def editingBindings : List (String × Invocation) :=
  editingKeys.map fun (text, name) => (text, { command := name })

/-- The kit's editing commands and keys as a package, named `editing`, for
a driver or a host that is handed packages. -/
def editingPackage : Package :=
  { name := "editing"
    setup := do
      for (name, run) in editingCommands do
        commandWith name run
      for (text, name) in editingKeys do
        bindKey text name }

end Editor.Test
