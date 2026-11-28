import Editor.Api
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Jumps
import Editor.Loop
import Editor.Loop.Driver
import Editor.State
import Editor.Test.Driver
import Editor.Test.Editing
import Editor.Test.Files
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Test.Opener
import Editor.Text

/-!
# Model tests: support: Jumps

The driver of the jump checks, over the test scheme, the editor's models
and the file model, with keys that record, edit, open and close, written
over the core's API: the kit's opener opens a file, and stand-ins written
here switch and close; and what a check reads of a window's jump list and
cursor, written as text; and a state whose buffer has a folded range, with
what a check of a landing inside it reads (`foldedJumpState`,
`foldedJumpSeen`). The core's `ModelTest/Editor/Jumps.lean` runs on
its driver; the files feature's support (`ModelTest/Support/JumpsGo.lean`)
binds the same keys to the real commands, for `ModelTest/Editor/Jumps/Go.lean`
and `packages/evil/EvilTest/Evil/Marks.lean`. It holds no checks of its own.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The text the scratch buffer of the jump checks starts with: eight lines,
`l0` to `l7`. -/
def jumpScratch : String :=
  "l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\n"

/-- The keys of the jump checks, over the window they are pressed in, each
bound to the command of its name:

- `C-j 0` to `C-j 7` put the cursor at the start of that row (`row`), and
  `C-j w` two bytes on from where it is (`step`);
- `C-j r` records a jump (`record`, `Jumps.record`), `C-j o` and `C-j i`
  move one back and one on (`back`, `forward`), and `C-j t` goes to the row
  1 of `jumps.txt` as a jump (`go-to`);
- `C-j l` inserts a line at the text's start (`line`), `C-j d` deletes its
  first line (`delete-first`), and `C-j x` deletes the rows 2 and 3
  (`delete-two`);
- `C-j n` opens `jumps.txt` (`open`), `C-j v` visits its row 1 at its first
  non-blank (`visit`), and `C-j V` visits it so recording no jump
  (`visit-quietly`);
- `C-j b` switches to the buffer `scratch` (`switch`), `C-j s` shows the
  buffer 0 with no jump (`scratch`), `C-j m` makes a buffer with no file and
  shows it (`make`), `C-j k` closes the window's buffer (`close`) and `C-j K`
  closes the buffer 1 (`close-1`).

Which commands a driver registers under those names is its own: the
core's (`jumpCoreCommands` and `jumpStandIns`) or the files feature's
(`ModelTest/Support/JumpsGo.lean`). -/
def jumpBindings : List (String × Invocation) :=
  let rowKeys :=
    (List.range 8).map fun row => (s!"C-j {row}", { command := "row", arguments := [.nat row] })
  rowKeys ++
    [("C-j w", invoke "step"), ("C-j r", invoke "record"), ("C-j o", invoke "back"),
      ("C-j i", invoke "forward"), ("C-j t", invoke "go-to"), ("C-j l", invoke "line"),
      ("C-j d", invoke "delete-first"), ("C-j x", invoke "delete-two"), ("C-j n", invoke "open"),
      ("C-j v", invoke "visit"), ("C-j V", invoke "visit-quietly"), ("C-j b", invoke "switch"),
      ("C-j s", invoke "scratch"), ("C-j m", invoke "make"), ("C-j k", invoke "close"),
      ("C-j K", invoke "close-1")]

/-- `run` as a command the jump checks' driver dispatches. -/
def jumpCommand (run : Call → EditorM Unit) : Dispatched := fun call => do
  run call
  return none

/-- The commands of the jump checks that are the core's alone: `row`,
`step`, `record`, `line`, `delete-first`, `delete-two`, `scratch` and
`make`. -/
def jumpCoreCommands : List (String × Dispatched) :=
  let view (call : Call) : ViewId := call.target.window.id
  [("row",
      jumpCommand fun call => do
        let row :=
          match call.arguments with
          | .nat row :: _ => row
          | _ => 0
        let offset ← call.target.buffer.text.offsetOf ⟨row, 0⟩
        call.target.select { ranges := #[⟨offset, offset⟩] }),
    ("step",
      jumpCommand fun call => do
        let selection ← call.target.selection
        let head := (selection.ranges[0]?.map (·.head)).getD 0
        call.target.select { ranges := #[⟨head + 2, head + 2⟩] }),
    ("record", jumpCommand fun call => Jumps.record (view call)),
    ("line", jumpCommand fun call => call.target.buffer.text.insert 0 "new\n"),
    ("delete-first",
      jumpCommand fun call => do
        let text := call.target.buffer.text
        text.delete 0 (← text.offsetOf ⟨1, 0⟩)),
    ("delete-two",
      jumpCommand fun call => do
        let text := call.target.buffer.text
        text.delete (← text.offsetOf ⟨2, 0⟩) (← text.offsetOf ⟨4, 0⟩)),
    ("scratch", jumpCommand fun call => discard <| (view call).show ⟨0⟩),
    ("make",
      jumpCommand fun call => do
        if let .ok made← createBuffer "nofile" "n0\nn1\n" then
          discard <| (view call).show made)]

/-- Closes the buffer `id` as the core's API alone does it: the places held
in its text detached into its file (`Jumps.detach`), the scratch buffer, or
the buffer 1 when it is the scratch buffer being closed, shown in every
window that showed it, and the buffer removed. A stand-in for the buffers
feature's close, which the core's jump checks do not import. -/
def standInClose (id : BufferId) : EditorM Unit := do
  Jumps.detach id
  let state ← editorState
  let fallback : BufferId := if id == ⟨0⟩ then ⟨1⟩ else ⟨0⟩
  for view in state.frame.everyWindow do
    if (state.window? view).any (·.buffer == id) then
      discard <| view.show fallback
  discard <| id.remove

/-- The stand-ins of the core's jump checks for what the file and buffer
features do: `open` opens `jumps.txt` with the kit's opener (`Opener.open`),
`switch` records a jump and shows the buffer `scratch`, as a switch does,
and `close` and `close-1` close with `standInClose`. -/
def jumpStandIns : List (String × Dispatched) :=
  let view (call : Call) : ViewId := call.target.window.id
  [("open", jumpCommand fun call => Opener.open (view call) jumpsPath),
    ("switch",
      jumpCommand fun call => do
        Jumps.record (view call)
        discard <| (view call).show ⟨0⟩),
    ("close", jumpCommand fun call => standInClose call.target.window.buffer),
    ("close-1", jumpCommand fun _ => standInClose ⟨1⟩)]

/-- The driver of the jump checks with `commands` and the jobs `jobs`: the
keys of `jumpBindings`, and the files `jumpFiles`, from one window on the
buffer `scratch`, which holds `jumpScratch`, its cursor at 0. -/
def jumpDriverWith (commands : List (String × Dispatched))
    (jobs : String → Option (List Argument → Work)) : Option TestDriver :=
  (Loop.Driver.over (dispatchKeys jumpBindings commands) jobs (holding jumpScratch #[⟨0, 0⟩])
        editorModel).toOption.map
    fun driver => { driver with jobs := { files := jumpFiles } }

/-- `driver` fed the keys `keys`, each followed by every load of the job
`loadJob` it started being finished, so a key after an open acts on the
file opened. -/
def jumpedWith (loadJob : String) (driver : TestDriver) (keys : String) : TestDriver :=
  (presses keys).foldl
    (fun driver event =>
      let fed := (fedTo driver [event]).1
      (List.range 2).foldl (fun driver _ => finishNamed driver loadJob) fed)
    driver

/-- The driver of the core's jump checks: the core's commands and its
stand-ins, and the kit's opener's jobs. -/
def jumpDriver : Option TestDriver :=
  jumpDriverWith (jumpCoreCommands ++ jumpStandIns) Opener.jobs

/-- `driver`, the core's, fed the keys `keys` (`jumpedWith`). -/
def jumped (driver : TestDriver) (keys : String) : TestDriver :=
  jumpedWith Opener.loadJob driver keys

/-- The driver of the core's jump checks after `keys` (`jumped`). -/
def jumpedFrom (keys : String) : Option TestDriver :=
  jumpDriver.map (jumped · keys)

/-- `place` as a check writes it: a held place as its buffer's number, `@`,
its row and its column in bytes, read from the text model; a place in a
file as its path, `@`, its row and its column in characters. -/
def placeText (driver : TestDriver) (place : Place) : String :=
  match place with
  | .held buffer marker =>
    let read : TextM Point := do
      let offset ← Marks.offsetOf marker
      marker.text.pointOf offset
    match (read.runModel driver.model.texts).1 with
    | .ok point => s!"{buffer.index}@{point.row}:{point.column}"
    | .error _ => s!"{buffer.index}@given up"
  | .file path row column => s!"{path}@{row}:{column}"

/-- The jump list of the view `view` of `driver`, each entry as `placeText`
writes it, and its index. -/
def jumpsOf (driver : TestDriver) (view : ViewId := ⟨0⟩) : Option (List String × Nat) := do
  let window ← driver.loop.state.window? view
  return (window.jumps.list.entries.toList.map (placeText driver), window.jumps.list.index)

/-- A buffer over `l0` to `l4` whose rows 1 to 3 are the folded range `f`,
its cursor at 0. -/
def foldedJumpState : TextM EditorState := do
  let state ← barState "l0\nl1\nl2\nl3\nl4\n" 0
  let folds : Array Foldable :=
    #[{ start := 3, stop := 11, key := "f", text := "…", folded := true }]
  return { state with buffers := state.buffers.modify 0 (·.map ({ · with folds })) }

/-- Whether buffer 0's range `f` is folded, and the head of view 0's cursor,
in the state a command runs on. -/
def foldedJumpSeen : EditorM (Bool × Nat) := do
  let folded := ((← editorState).buffer? ⟨0⟩).any fun buffer => buffer.folds.any (·.folded)
  let .ok selection ← (⟨0⟩ : ViewId).selection | return (folded, 0)
  return (folded, (selection.ranges[0]?.map (·.head)).getD 0)

/-- The previous-context mark of the view `view` of `driver`, as `placeText`
writes it. -/
def previousOf (driver : TestDriver) (view : ViewId := ⟨0⟩) : Option (Option String) := do
  let window ← driver.loop.state.window? view
  return window.jumps.previous.map (placeText driver)

/-- Where the cursor of the view `view` of `driver` is, as `placeText`
writes a held place: its buffer's number, `@`, its row and its column in
bytes. -/
def cursorOf (driver : TestDriver) (view : ViewId := ⟨0⟩) : Option String := do
  let target ← driver.loop.state.target? view
  let read : TextM Point := do
    let selection ← target.selection
    let head := (selection.ranges[selection.primary]?.map (·.head)).getD 0
    target.buffer.text.pointOf head
  let point ← (read.runModel driver.model.texts).1.toOption
  return s!"{target.window.buffer.index}@{point.row}:{point.column}"

end ModelTest
