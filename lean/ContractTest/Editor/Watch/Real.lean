import ContractTest.Check
import ContractTest.Support.Displays
import Editor.Clipboard
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Real
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Config.Stores
import Editor.Display
import Editor.Display.Recorder
import Editor.DisplayRules
import Editor.Event
import Editor.Event.Queue
import Editor.Ex.Line
import Editor.Ffi.Document
import Editor.Ffi.Events
import Editor.Ffi.Interrupt
import Editor.Ffi.Snapshot
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job.Fake
import Editor.Job.Runner
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
import Editor.SyntaxTree
import Editor.TabBar
import Editor.Text
import Editor.Text.Real
import Editor.Watch
import Editor.Watch.Real
import Editor.Workspace

/-!
# Contract tests: `Editor/Watch/Real.lean`

The tests of `Editor/Watch/Real.lean`: `watchChecks`, what only the real watch
binding shows. The root module `ContractTest` runs them; its module doc says
what each shows.
-/

namespace ContractTest

open Editor

/-- What a command of the watch checks is: given its call, a program whose
value is what to write back. -/
abbrev Dispatched :=
  Call → EditorM (Option Config.Write)

/-- The keys the key string `text` names; none when it is refused. -/
def keys (text : String) : List Key :=
  (Key.parse text).toOption.getD []

/-- A scene with no views whose echo is `echo`: what the command `spin`
publishes, so that a display handler tells its publishes apart. -/
def spinScene (echo : String) : Scene :=
  { emptyScene with echo }

/-- The command `spin` of the watch checks: it replaces what the selection
covers with `spin`, and then, five times over, publishes a scene whose echo
says which round it is and makes a text named for the round. -/
def spin : Dispatched := fun call => do
  Loop.insert call.target "spin"
  for round in [1:6] do
    Display.publish (spinScene s!"spin {round}")
    discard <| createText s!"after {round}"
  return none

/-- The command `stamp` of the watch checks: it replaces what the selection
covers with the keys it was called with, as a key string. -/
def stamp : Dispatched := fun call => do
  Loop.insert call.target (Key.notations call.keys)
  return none

/-- What a step of the watch checks is handed: one keymap for every view,
which binds `C-c l` to `spin` and `C-c s` to `stamp`, and those two
commands. -/
def watchKeys : Loop.Keys TestScheme.scheme :=
  { maps := fun _ _ =>
      [Keymap.ofList
          [(keys "C-c l", ({ command := "spin" } : Invocation)),
            (keys "C-c s", { command := "stamp" })]]
    command? := fun name => ([("spin", spin), ("stamp", stamp)].find? (·.1 == name)).map (·.2) }

/-- What only the watch port's real binding shows. -/
def watchChecks (timers : Job.Timers) : List Check :=
  [{  name :=
        "the watch binding's clock is the job port's: over a fake clock it reads that clock's reading, and each reading is a read of that clock"
      run := do
        let clock ← Job.FakeClock.new (← Job.Completions.new)
        let handler := Watch.real clock.timers
        let first ← Program.runM (port := watchPort) handler Watch.now
        clock.advance 60
        let second ← Program.runM (port := watchPort) handler Watch.now
        return first == 0 && second == 60 && (← clock.reads) == 2 },
    { name :=
        "the interrupt key arrives during a command's third publish, on the real text binding: the command makes no request after it, the buffer's text is as before, the echo says interrupted, the event then pulled is marked, taking it lowers the flag, and the next key's command runs to its end"
      run := do
        unless ← Event.setInterruptKey (some Watch.interruptKey) do
          return false
        try
          let published ← Snapshots.new
          let recorder ← DisplayRecorder.new { advance := 8, lineHeight := 16 } published.reader
          -- The key arrives while the command is inside its third publish,
          -- on this thread: nothing else runs between.
          let display : DisplayHandler := fun request => do
            if let .publish scene := request then
              if scene.echo == "spin 3" then
                discard <| Event.post (.key Watch.interruptKey true "")
            recorder.handle request
          let watch := Watch.real timers
          let run {α : Type} (texts : RealTexts) (program : EditorM α) :
            IO (Option α × RealTexts) := do
            let (result, texts) ← program.runReal texts display (watch := watch)
            return (result.toOption, texts)
          let press (text : String) : List Received :=
            (keys text).map fun key => { event := .key key true "", stamp := 0 }
          let takes (loop : Loop TestScheme.scheme) (received : List Received) :
            EditorM (Loop TestScheme.scheme) := do
            let mut loop := loop
            for one in received do
              loop := (← loop.take watchKeys one).loop
            return loop
          let read (loop : Loop TestScheme.scheme) : EditorM String := do
            let some target := loop.state.focusedTarget? | throw .noSuchText
            target.buffer.text.read
          let (started, texts) ←
            run (RealTexts.over published) (Loop.start TestScheme.scheme ⟨640, 480⟩)
          let some loop := started | return false
          -- The command, interrupted in its third round.
          let (interrupted, texts) ←
            run texts do
                let loop ← takes loop (press "C-c l")
                return (loop, ← read loop)
          let some (loop, after) := interrupted | return false
          let made ←
            texts.documents.filterMapM fun document => do
                let some document := document | return none
                return some (← document.read)
          let raised ← Ffi.interruptRaised
          -- The interrupt key is next on the queue, marked.
          let some pulled ← Ffi.takeQueued .editor | return false
          let .ok received := Event.ofFfi pulled | return false
          let (lowered, texts) ← run texts (takes loop [received])
          let some loop := lowered | return false
          let down ← Ffi.interruptRaised
          let echoed := loop.state.echo
          -- The next key's command runs to its end.
          let (next, _) ←
            run texts do
                let loop ← takes loop (press "C-c s")
                return (loop.state.echo, ← read loop)
          return after == "" && made == #["", "after 1", "after 2"] && raised &&
              received.interrupt &&
              received.event == .key Watch.interruptKey true "" &&
              !down &&
              echoed == "spin: interrupted" &&
              next == some ("", "C-c s")
        finally
          discard <| Event.setInterruptKey none }]

end ContractTest
