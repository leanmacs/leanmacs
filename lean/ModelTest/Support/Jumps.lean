import Editor.Api
import Editor.Buffers
import Editor.Files
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Jumps
import Editor.Jumps.Go
import Editor.Loop
import Editor.Loop.Driver
import Editor.State
import Editor.Text
import ModelTest.Support.Driver
import ModelTest.Support.Files
import ModelTest.Support.Keys
import ModelTest.Support.Loop
import ModelTest.Support.Models

/-!
# Model tests: support: Jumps

The driver of the jump checks, over the test scheme, the editor's models
and the file model, with keys that record, move, edit, open and close; and
what a check reads of a window's jump list and cursor, written as text.
Shared by `ModelTest/Editor/Jumps.lean` and `ModelTest/Editor/Jumps/Go.lean`;
it holds no checks of its own.
-/

namespace ModelTest

open Editor

/-- The path of the file of the jump checks. -/
def jumpsPath : System.FilePath :=
  inFiles "jumps.txt"

/-- The files of the jump checks: those of the file command checks, and
`jumps.txt`, of five lines: its row 1 is indented by two blanks, and its
row 2 starts with a two-byte character. -/
def jumpFiles : FileModel :=
  commandFiles.withFile jumpsPath "zero\n  one\néx two\nthree\nfour\n".toUTF8

/-- The text the scratch buffer of the jump checks starts with: eight lines,
`l0` to `l7`. -/
def jumpScratch : String :=
  "l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\n"

/-- The keys of the jump checks, over the window they are pressed in:

- `C-j 0` to `C-j 7` put the cursor at the start of that row, and `C-j w`
  two bytes on from where it is;
- `C-j r` records a jump (`Jumps.record`), `C-j o` and `C-j i` move one
  back and one on (`Jumps.move`), and `C-j t` goes to the row 1 of
  `jumps.txt` as a jump (`Jumps.goTo`);
- `C-j l` inserts a line at the text's start, `C-j d` deletes its first
  line, and `C-j x` deletes the rows 2 and 3;
- `C-j n` opens `jumps.txt` (`Files.open`), `C-j v` visits its row 1 at its
  first non-blank (`Files.visit`), and `C-j V` visits it so recording no
  jump;
- `C-j b` switches to the buffer `scratch` (`Buffers.switchTo`), `C-j s`
  shows the buffer 0 with no jump, `C-j m` makes a buffer with no file and
  shows it, `C-j k` closes the window's buffer and `C-j K` closes the
  buffer 1 (`Buffers.close`). -/
def jumpKeys : Loop.Keys TestScheme.scheme :=
  let rowKeys :=
    (List.range 8).map fun row => (s!"C-j {row}", { command := "row", arguments := [.nat row] })
  let unit (run : Call → EditorM Unit) : Dispatched := fun call => do
    run call
    return none
  let view (call : Call) : ViewId := call.target.window.id
  dispatchKeys
    (rowKeys ++
      [("C-j w", invoke "step"), ("C-j r", invoke "record"), ("C-j o", invoke "back"),
        ("C-j i", invoke "forward"), ("C-j t", invoke "go-to"), ("C-j l", invoke "line"),
        ("C-j d", invoke "delete-first"), ("C-j x", invoke "delete-two"), ("C-j n", invoke "open"),
        ("C-j v", invoke "visit"), ("C-j V", invoke "visit-quietly"), ("C-j b", invoke "switch"),
        ("C-j s", invoke "scratch"), ("C-j m", invoke "make"), ("C-j k", invoke "close"),
        ("C-j K", invoke "close-1")])
    [("row",
        unit fun call => do
          let row :=
            match call.arguments with
            | .nat row :: _ => row
            | _ => 0
          let offset ← call.target.buffer.text.offsetOf ⟨row, 0⟩
          call.target.select { ranges := #[⟨offset, offset⟩] }),
      ("step",
        unit fun call => do
          let selection ← call.target.selection
          let head := (selection.ranges[0]?.map (·.head)).getD 0
          call.target.select { ranges := #[⟨head + 2, head + 2⟩] }),
      ("record", unit fun call => Jumps.record (view call)),
      ("back", unit fun call => discard <| Jumps.move (view call) (-1)),
      ("forward", unit fun call => discard <| Jumps.move (view call) 1),
      ("go-to", unit fun call => Jumps.goTo (view call) (.file jumpsPath 1 0) false),
      ("line", unit fun call => call.target.buffer.text.insert 0 "new\n"),
      ("delete-first",
        unit fun call => do
          let text := call.target.buffer.text
          text.delete 0 (← text.offsetOf ⟨1, 0⟩)),
      ("delete-two",
        unit fun call => do
          let text := call.target.buffer.text
          text.delete (← text.offsetOf ⟨2, 0⟩) (← text.offsetOf ⟨4, 0⟩)),
      ("open", unit fun call => Files.open (view call) jumpsPath),
      ("visit",
        unit fun call =>
          Files.visit (view call) jumpsPath { row := 1, column := 0, firstNonBlank := true } false),
      ("visit-quietly",
        unit fun call =>
          Files.visit (view call) jumpsPath { row := 1, column := 0, firstNonBlank := true } false
            (record := false)),
      ("switch", unit fun call => Buffers.switchTo (view call) EditorState.scratchName),
      ("scratch", unit fun call => discard <| (view call).show ⟨0⟩),
      ("make",
        unit fun call => do
          if let .ok made← createBuffer "nofile" "n0\nn1\n" then
            discard <| (view call).show made),
      ("close", unit fun call => Buffers.close call.target.window.buffer),
      ("close-1", unit fun _ => Buffers.close ⟨1⟩)]

/-- The driver of the jump checks: the keys of `jumpKeys`, the file jobs,
and the files `jumpFiles`, from one window on the buffer `scratch`, which
holds `jumpScratch`, its cursor at 0. -/
def jumpDriver : Option TestDriver :=
  (Loop.Driver.over jumpKeys fileJobs (holding jumpScratch #[⟨0, 0⟩]) editorModel).toOption.map
    fun driver => { driver with jobs := { files := jumpFiles } }

/-- `driver` fed the keys `keys`, each followed by every load it started
being finished, so a key after an open acts on the file opened. -/
def jumped (driver : TestDriver) (keys : String) : TestDriver :=
  (presses keys).foldl
    (fun driver event =>
      let fed := (fedTo driver [event]).1
      (List.range 2).foldl (fun driver _ => finishNamed driver Files.loadJob) fed)
    driver

/-- The driver of the jump checks after `keys` (`jumped`). -/
def jumpedFrom (keys : String) : Option TestDriver :=
  jumpDriver.map (jumped · keys)

/-- `place` as a check writes it: a held place as its buffer's number, `@`,
its row and its column in bytes, read from the text model; a place in a
file as its path, `@`, its row and its column in characters. -/
def placeText (driver : TestDriver) (place : Place) : String :=
  match place with
  | .held buffer marker =>
    let read : TextM Point := do
      let offset ← Jumps.offsetOf marker
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
