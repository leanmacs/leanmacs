import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Compile.Contribution
import Editor.Config.Stores
import Editor.Display.Model
import Editor.DisplayRules
import Editor.Event
import Editor.Ex.Line
import Editor.File
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Contract
import Editor.Language
import Editor.Loop
import Editor.Loop.Driver
import Editor.Mode
import Editor.Process
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Text
import Editor.Text.Model
import Editor.Workspace
import ModelTest.Support.Jobs
import ModelTest.Support.Keys
import ModelTest.Support.Loop
import ModelTest.Support.Models
import ModelTest.Support.States

/-!
# Model tests: support: Driver

The loop's driver over the editor's models and the job model (`TestDriver`),
with the keys and jobs it is built with and what a check reads back from it.
Shared by several test modules under `ModelTest/Editor/`; it holds no checks of
its own.
-/

namespace ModelTest

open Editor

/-- What `command`, run dispatched from the state `start` makes with nothing
told of the registry, returned on the editor's models, and the state it
left; `none` unless it ran to its end. -/
def dispatchedFrom {α : Type} (command : EditorM α) (start : TextM EditorState := twoBuffers) :
    Option (α × EditorState) :=
  let program : EditorM (Guarded α × EditorState) := do
    command.dispatched {} (← start)
  match (program.runModel editorModel).1 with
  | .ok (.finished value, state) => some (value, state)
  | _ => none

/-- The driver the job checks run: one over the test scheme. -/
abbrev TestDriver :=
  Loop.Driver TestScheme.scheme

/-- The streaming child the driver checks' `streamer` starts: one that waits
for its input, which is never written. -/
def streamed : Process.Command :=
  { program := "/bin/cat", directory := "/p/d" }

/-- The jobs of the driver checks, by name. `double` doubles the number it
is started with, and its command inserts the result, in brackets, at the
cursor of view 0. `poster` posts `mark` with `p1`, sleeps 10 ms, posts `mark`
with `p2`, and finishes with a command that inserts `[end]`. `streamer`
starts `streamed` as a streaming child, posts `mark` with `s` and reads
the child, and finishes with a command that inserts `[streamed]`. `bad` finishes with a command that inserts and is then
refused. `chain` finishes with a command that starts `double` with 5.

Four reach files, in `fileRoot`. `load` loads the file it is named and
finishes with a command that makes a text of it. `adopt` loads nothing, and
finishes with a command that adopts the job snapshot of the number it is
started with. `save` saves the snapshot of the store whose index it is
started with as `out.txt`, which must not be there. `lose` loads `note.txt`
and then throws. -/
def driverJobs (name : String) : Option (List Argument → Work) :=
  let inserts (text : String) : EditorM Unit := discard <| (⟨0⟩ : ViewId).insertAtSelections text
  match name with
  | "double" =>
    some fun arguments =>
      Work.of
        (fun _ => do
          let [.nat n] := arguments | throw "double takes one number"
          sleep 10
          return 2 * n)
        fun n => inserts s!"[{n}]"
  | "bad" =>
    some fun _ =>
      Work.of (fun _ => pure ()) fun _ => do
        inserts "lost"
        (⟨0⟩ : TextId).delete 9 99
  | "chain" =>
    some fun _ => Work.of (fun _ => pure ()) fun _ => discard <| startJob "double" [.nat 5]
  | "load" =>
    some fun arguments =>
      Work.of
        (fun _ => do
          let [.str name] := arguments | throw "load takes one name"
          return (← JobContract.loaded (fileRoot / name)).snapshot)
        fun file => discard file.toText
  | "adopt" =>
    some fun arguments =>
      Work.of
        (fun _ => do
          let [.nat number] := arguments | throw "adopt takes one number"
          return number)
        fun number => discard (JobSnapshotId.mk number).adopt
  | "save" =>
    some fun arguments =>
      Work.of
        (fun _ => do
          let [.nat index] := arguments | throw "save takes one number"
          discard <| JobContract.saved (.snapshot ⟨index⟩) (fileRoot / "out.txt") .absent)
        fun _ => pure ()
  | "lose" =>
    some fun _ =>
      Work.of
        (fun _ => do
          discard <| JobContract.loaded (fileRoot / "note.txt")
          throw "lost")
        fun (_ : Unit) => pure ()
  | "build" =>
    some fun _ =>
      Work.of (fun _ => Process.run { program := "/bin/true", directory := "/p/d" } 10) fun _ =>
        pure ()
  | "poster" =>
    some fun _ =>
      Work.of
        (fun _ => do
          post { command := "mark", arguments := [.str "p1"] }
          sleep 10
          post { command := "mark", arguments := [.str "p2"] })
        fun _ => inserts "[end]"
  | "streamer" =>
    some fun _ =>
      Work.of
        (fun _ => do
          match ← Process.start streamed { input := true, bound := 64 } with
          | .ok child =>
            post { command := "mark", arguments := [.str "s"] }
            discard <| Process.read child
          | .error _ =>
            throw "streamer: refused")
        fun _ => inserts "[streamed]"
  | _ => none

/-- The commands of the driver checks, bound under `C-c`: `ask` (`a`)
messages `asked` and starts `double` with 21; `missing` (`m`) starts a job
no one registered and messages the refusal; `fail` (`f`) starts `double`
and is then refused; `none` (`n`) starts `double` with no argument; `bad`
(`b`) and `chain` (`c`) start the jobs of those names; `load` (`l`) starts
`load` with `note.txt`, `adopt` (`s`) starts `adopt` with 0, `save` (`w`)
takes a snapshot of its buffer's text and starts `save` with its index, and
`lose` (`t`) starts `lose`, and `build` (`e`) starts `build`, which runs
`/bin/true` in `/p/d`. `keyed` (`k`) starts `double` with 21 under the key
`k`, `cancel` (`x`) cancels the key `k`, `cancelFails` (`y`) cancels it
and is then refused, and `cancelAfterRead` (`z`) reads its buffer's text
and then cancels it. `post` (`p`) starts `poster` under the key `p`,
`stream` (`r`) starts `streamer` under the key `s`, and `cancelStream` (`v`)
cancels the key `s`; `mark`, which no key runs, inserts its argument at the
cursor of view 0, for the jobs' posts. -/
def driverKeys : Loop.Keys TestScheme.scheme :=
  let starts (name : String) (arguments : List Argument := []) : Dispatched := fun _ => do
    discard <| startJob name arguments
    return none
  dispatchKeys
    [("C-c a", invoke "ask"), ("C-c m", invoke "missing"), ("C-c f", invoke "fail"),
      ("C-c n", invoke "none"), ("C-c b", invoke "bad"), ("C-c c", invoke "chain"),
      ("C-c l", invoke "load"), ("C-c s", invoke "adopt"), ("C-c w", invoke "save"),
      ("C-c t", invoke "lose"), ("C-c e", invoke "build"), ("C-c k", invoke "keyed"),
      ("C-c x", invoke "cancel"), ("C-c y", invoke "cancelFails"),
      ("C-c z", invoke "cancelAfterRead"), ("C-c p", invoke "post"), ("C-c r", invoke "stream"),
      ("C-c v", invoke "cancelStream")]
    [("ask", fun _ => do
        message "asked"
        discard <| startJob "double" [.nat 21]
        return none),
      ("missing", fun _ => do
        if let .error (.noSuchJob name)← startJob "nope" [.nat 1] then
          message s!"no job {name}"
        return none),
      ("fail", failingAfter fun _ => discard <| startJob "double" [.nat 1]),
      ("none", starts "double"), ("bad", starts "bad"), ("chain", starts "chain"),
      ("load", starts "load" [.str "note.txt"]), ("adopt", starts "adopt" [.nat 0]),
      ("save", fun call => do
        let taken ← call.target.buffer.text.snapshot
        discard <| startJob "save" [.nat taken.index]
        return none),
      ("lose", starts "lose"), ("build", starts "build"),
      ("keyed", fun _ => do
        discard <| startJob "double" [.nat 21] (key := some "k")
        return none),
      ("cancel", fun _ => do
        cancelJob "k"
        return none),
      ("cancelFails", failingAfter fun _ => cancelJob "k"),
      ("cancelAfterRead", fun call => do
        -- A read of the text is a guarded request, which an interrupt ends:
        -- a command of state requests alone cannot be interrupted.
        discard <| call.target.buffer.text.read
        cancelJob "k"
        return none),
      ("post", fun _ => do
        discard <| startJob "poster" (key := some "p")
        return none),
      ("stream", fun _ => do
        discard <| startJob "streamer" (key := some "s")
        return none),
      ("cancelStream", fun _ => do
        cancelJob "s"
        return none),
      ("mark", fun call => do
        if let [.str text] := call.arguments then
          discard <| (⟨0⟩ : ViewId).insertAtSelections text
        return none)]

/-- A driver over the initial state, with the commands and the jobs of the
driver checks; `none` if making the state was refused. -/
def newDriver : Option TestDriver :=
  (Loop.Driver.over driverKeys driverJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption

/-- Feeds `driver` the `events` in order: the driver after them, and what
each step handed back, `none` for a step that was refused. -/
def fedTo (driver : TestDriver) (events : List Event) :
    TestDriver × Array (Option (Loop.Stepped TestScheme.scheme)) :=
  events.foldl
    (fun (driver, steps) event =>
      let (driver, stepped) := driver.feed { event, stamp := 0 }
      (driver, steps.push stepped.toOption))
    (driver, #[])

/-- What the buffer of view 0 holds in `driver`'s text model. -/
def driverText (driver : TestDriver) : Option String :=
  driver.model.texts.contents[0]?

/-- What a view of a driver shows. -/
structure Showing where
  /-- The buffer's id. -/
  id : BufferId
  /-- The buffer. -/
  buffer : Buffer
  /-- What the buffer's text holds in the text model; `none` if it was
  released. -/
  text : Option String
  /-- The ranges of the window's selection, as the text model has them;
  `none` if the marker was given up. -/
  cursors : Option (Array SelectionRange)

/-- What the view `view` of `driver` shows; `none` if it has no window. -/
def showing (driver : TestDriver) (view : ViewId := ⟨0⟩) : Option Showing := do
  let target ← driver.loop.state.target? view
  return {
      id := target.window.buffer
      buffer := target.buffer
      text := (driver.model.texts.texts[target.buffer.text.index]?).join.map (·.contents)
      cursors := (target.selection.runModel driver.model.texts).1.toOption.map (·.ranges) }

/-- The echo area of the last scene `driver`'s display recorded. -/
def echoOf (driver : TestDriver) : Option String :=
  driver.model.display.scenes.back?.map (·.echo)

/-- The view 0 of the last scene `driver` published. -/
def gutterView (driver : TestDriver) : Option View :=
  driver.model.display.scenes.back?.bind (·.views[0]?)

/-- `driver` once every pending job not called `name` is finished, oldest
first, with those they start; bounded. -/
def settledBut (driver : TestDriver) (name : String) : TestDriver :=
  (List.range 8).foldl
    (fun driver _ =>
      match driver.pending.find? (·.name != name) with
      | some job => (driver.finish job.id).1
      | none => driver)
    driver

/-- The starts every step of `steps` handed back, by name. -/
def startNames (steps : Array (Option (Loop.Stepped TestScheme.scheme))) : Array String :=
  steps.flatMap fun step => ((step.map (·.starts)).getD #[]).map (·.name)

/-- The names of `bindings`, each once, in the order they are first bound:
what a step of the ex checks is told the bound ex names are. -/
def exNamesOf (bindings : Array Ex.Binding) : Array String :=
  bindings.foldl
    (fun names binding => if names.contains binding.name then names else names.push binding.name)
    #[]

/-- The events of one ex line: the key that opens the ex line, `line`
committed into the minibuffer, and the accept key. -/
def exLine (line : String) : List Event :=
  presses "C-e e" ++ [.commit line] ++ presses "C-e y"

end ModelTest
