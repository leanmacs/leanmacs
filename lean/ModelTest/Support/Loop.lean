import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Compile.Contribution
import Editor.Completion.Display
import Editor.Completion.Displays
import Editor.Completion.Keys
import Editor.Config.Stores
import Editor.Display.Model
import Editor.DisplayRules
import Editor.Event
import Editor.Ex.Line
import Editor.File
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Key.Notation
import Editor.Keymap
import Editor.Language
import Editor.Layout
import Editor.Loop
import Editor.Menu
import Editor.Mode
import Editor.ModeLine
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.TabBar
import Editor.Text
import Editor.Text.Model
import Editor.UndoTree
import Editor.Value
import Editor.Watch
import Editor.Workspace
import ModelTest.Support.Config
import ModelTest.Support.Keys
import ModelTest.Support.Models
import ModelTest.Support.States

/-!
# Model tests: support: Loop

The command loop stepped on the editor's models, with keymaps and commands
written in the test (`Dispatched`), and what a check reads of a step. Shared by
several test modules under `ModelTest/Editor/`; it holds no checks of its own.
-/

namespace ModelTest

open Editor

/-- The loop the model tests run: one over the test scheme. -/
abbrev TestLoop :=
  Loop TestScheme.scheme

/-- One step of `loop` with no keymap: the loop after `event` and what the
step said to do next, for the checks that look at nothing else of a step. -/
def stepped (loop : TestLoop) (event : Event) : EditorM (TestLoop × Loop.Next) := do
  let after ← loop.step {} event
  return (after.loop, after.next)

/-- Starts a loop from the state `start` makes, feeds it `events` in order,
and returns the loop and what each step said to do next. -/
def stepsFrom (start : TextM EditorState) (events : List Event) :
    EditorM (TestLoop × Array Loop.Next) := do
  let mut loop : TestLoop := { state := ← start }
  let mut nexts := #[]
  for event in events do
    let (next, said) ← stepped loop event
    loop := next
    nexts := nexts.push said
  return (loop, nexts)

/-- The shipped mode line (`ModeLine.standard`) of a view of a buffer called
`name`, with no file and no major mode, modified when `modified` says, of
which the scheme reports `reported`, its cursor at `cursor` in a text of
`lines` rows, selected when `selected` says: what the loop draws of a view
of the scratch buffer. -/
def modeLineOf (name : String := "scratch") (modified : Bool := false)
    (cursor : Option Point := some ⟨0, 0⟩) (lines : Nat := 1) (reported : Array StatusField := #[])
    (selected : Bool := true) : Array StatusField :=
  let history := UndoTree.new ⟨0⟩ 0
  ModeLine.standard.fields
    { buffer := { name, text := ⟨0⟩, history := if modified then history.record 1 else history }
      reported, cursor, lines, selected }

/-- The left side of a status line: the fields of the buffer's name and its
modified mark, and a badge. -/
def leftOf (status : Array StatusField) : Array StatusField :=
  status.filter (·.side == .left)

/-- What a run of the loop on the editor's models came to: the loop and what
each step said, the scenes the display recorded, and the models. `none` when
it was refused. -/
def looped (start : TextM EditorState) (events : List Event) :
    Option ((TestLoop × Array Loop.Next) × Array Scene × EditorModel) :=
  match (stepsFrom start events).runModel editorModel with
  | (.ok result, model) => some (result, model.display.scenes, model)
  | (.error _, _) => none

/-- The initial state at 640 by 480 with a prompt open, asked from view 0 with
the label `Name: ` and the continuation `asked`: the minibuffer is view 1,
over a text of its own holding `text`, with a scroll anchor at its start
and one cursor after `text`. -/
def promptedOver (text : String) : TextM EditorState := do
  let state ← EditorState.initial ⟨640, 480⟩
  let made ← createText text
  let scroll ← made.mark (.anchor { offset := 0, bias := .before })
  let selection ← made.mark (.selection { ranges := #[⟨text.utf8ByteSize, text.utf8ByteSize⟩] })
  return (state.openPrompt "Name: " asked made (← UndoTree.over made) scroll selection).2

/-- A press of a key that no keymap binds and that prints nothing, with its
physical code as a window reports it: the loop steps it through its scheme,
which yields nothing for it. -/
def pressF5 : Event :=
  .key { logical := .named ⟨"F5"⟩, physical := .code "F5" } true ""

/-- The text of the snapshot a view shows, as the text model holds it. -/
def shownText (model : EditorModel) (view : View) : Option String :=
  (model.texts.snapshots[view.snapshot.index]?).join.map (·.contents)

/-- The focused window's buffer and window in `loop`'s state, or a refusal
for a state with none. -/
def focusedOf (loop : TestLoop) : EditorM Target := do
  let some target := loop.state.focusedTarget? | throw .noSuchText
  return target

/-- The initial state at 640 by 480, its buffer holding `text`, and the
focused window's selection placed at `ranges`, exclusive. -/
def holding (text : String) (ranges : Array SelectionRange) : TextM EditorState := do
  let state ← EditorState.initial ⟨640, 480⟩
  let some target := state.focusedTarget? | throw .noSuchText
  target.buffer.text.insert 0 text
  target.buffer.text.place target.window.selection (.selection { ranges })
  return state

/-- What a command of the dispatch checks is: given its call, a program
whose value is what to write back. -/
abbrev Dispatched :=
  Call → EditorM (Option Config.Write)

/-- What a step of the dispatch checks is handed: one keymap, the same for
every view, that binds each key string of `bindings` to the invocation
beside it, and the commands `commands`, by name. -/
def dispatchKeys (bindings : List (String × Invocation))
    (commands : List (String × Dispatched) := []) : Loop.Keys TestScheme.scheme :=
  { maps := fun _ _ =>
      [Keymap.ofList (bindings.map fun (text, invocation) => (keys text, invocation))]
    command? := fun name => (commands.find? (·.1 == name)).map (·.2) }

/-- What a command was called with, as one line: its arguments, then its
keys as a key string. -/
def calledWith (call : Call) : String :=
  " ".intercalate (call.arguments.map argumentText ++ [Key.notations call.keys])

/-- The command `stamp` of the dispatch checks: it inserts what it was
called with (`calledWith`) at the cursors of the window it is handed. -/
def stamp : Dispatched := fun call => do
  Loop.insert call.target (calledWith call)
  return none

/-- Feeds `loop` the `events` in order, each step handed `keys`: the loop
after them and what each step handed back. -/
def stepsWith {scheme : InputScheme} (keys : Loop.Keys scheme) (loop : Loop scheme)
    (events : List Event) : EditorM (Loop scheme × Array (Loop.Stepped scheme)) := do
  let mut loop := loop
  let mut steps := #[]
  for event in events do
    let after ← loop.step keys event
    loop := after.loop
    steps := steps.push after
  return (loop, steps)

/-- What a run of the loop over the state `start` makes came to on the
models `model`, each step handed `keys`: the loop and what each step handed
back, the scenes the display recorded, and the models. `none` when it was
refused. -/
def dispatched (keys : Loop.Keys TestScheme.scheme) (events : List Event)
    (start : TextM EditorState := EditorState.initial ⟨640, 480⟩)
    (model : EditorModel := editorModel) :
    Option ((TestLoop × Array (Loop.Stepped TestScheme.scheme)) × Array Scene × EditorModel) :=
  let program : EditorM (TestLoop × Array (Loop.Stepped TestScheme.scheme)) := do
    stepsWith keys { state := ← start } events
  match program.runModel model with
  | (.ok result, model) => some (result, model.display.scenes, model)
  | (.error _, _) => none

/-- A command of the rollback checks that is refused with `badRange`, after
`before` has run on what it was called with. -/
def failingAfter (before : Call → EditorM Unit) : Dispatched := fun call => do
  before call
  call.target.buffer.text.delete 9 99
  return none

/-- The command `boom` of the rollback checks: it replaces what the
selection covers with `boom`, which edits the text and moves the selection,
and is then refused. -/
def boom : Dispatched :=
  failingAfter fun call => Loop.insert call.target "boom"

/-- A press of the interrupt key as it arrives, marked as one: the event
the loop lowers the flag for. -/
def interruptArrives : Received :=
  { event := press Watch.interruptKey, stamp := 0, interrupt := true }

/-- The refusal `program` ends with, if it is refused. -/
def refusalOf {α : Type} (program : TextM α) : TextM (Option TextError) := do
  match ← observing program with
  | .ok _ =>
    return none
  | .error refusal =>
    return some refusal

/-- The refusals reading each of a window's two markers ends with, the
scroll anchor's first. -/
def markerRefusals (window : Window) : TextM (List (Option TextError)) :=
  return [← refusalOf (window.scroll.text.marker window.scroll),
      ← refusalOf (window.selection.text.marker window.selection)]

/-- What the key hint checks hand a step, with the key hint delay `delay`:
one keymap that binds `C-x C-s`, described `Save`, and `C-x r t`, described
`Rectangle`, with the prefix `C-x r` named `rect`. -/
def hintedKeys (delay : Completion.Keys.Delay := 0) : Loop.Keys TestScheme.scheme :=
  { maps := fun _ _ =>
      [Keymap.ofDescribed
          [(keys "C-x C-s", invoke "save", some "Save"),
            (keys "C-x r t", invoke "rectangle", some "Rectangle")]]
    prefixNames := fun typed => if typed == keys "C-x r" then some "rect" else none
    keyHintDelay := delay }

/-- The key hints after `C-x` under `hintedKeys`: `C-s`, the binding, and
`r`, the prefix `rect`. -/
def afterPrefix : Array KeyHint :=
  #[{ key := "C-s", leads := .binding (some "Save") },
    { key := "r", leads := .prefix (some "rect") 1 }]

/-- The text the candidate list's view shows of `hints` drawn by `display`:
its sheet's text over their listing, of the category `key`. -/
def hintRows (hints : Array KeyHint)
    (display : Completion.Display := Completion.Displays.minibuffer) : String :=
  (display.sheet
      { listed := (Completion.Keys.candidates hints).map (Completion.Listed.of ·)
        category := some Completion.Keys.category }).text

end ModelTest
