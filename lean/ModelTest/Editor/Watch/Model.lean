import Editor.Command
import Editor.Command.Model
import Editor.Display
import Editor.Program
import Editor.Text
import Editor.Watch
import Editor.Watch.Model
import ModelTest.Check
import ModelTest.Support.Display
import ModelTest.Support.Models

/-!
# Model tests: `Editor/Watch/Model.lean`

The model tests of `Editor/Watch/Model.lean`: `watchChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the watch port's model (`Editor/Watch/Model.lean`): what
only the model has, an arrival a test places and a clock a command's
requests move. -/
def watchChecks : List Check :=
  [{  name :=
        "the watch model's interrupt key arrives when the flag is asked for the time after the count it was given, and once: asked four times with a count of two, the flag is down, down, up and up, with one arrived"
      run :=
        let asks : WatchM (List Bool) := do
          return [← Watch.interrupted, ← Watch.interrupted, ← Watch.interrupted,
              ← Watch.interrupted]
        let (answers, model) := watched asks { arrivesAfter := some 2 }
        let (never, _) := watched asks
        pure
          (answers == [false, false, true, true] && model.arrived == 1 &&
            model.arrivesAfter == none &&
            never == [false, false, false, false]) },
    { name := "the watch model's clock reads where it was set, and a watch request does not move it"
      run :=
        let reads : WatchM (List Nat) := do
          let first ← Watch.now
          discard Watch.interrupted
          Watch.lower
          return [first, ← Watch.now]
        pure ((watched reads { clock := 5, pace := 10 }).1 == [5, 5]) },
    { name :=
        "on the editor's models the clock moves on by the watch model's pace at each text request and each display request of a command, and at no watch request"
      run := do
        let command : EditorM (List Nat) := do
          let start ← Watch.now
          let text ← createText "ab"
          let afterText ← Watch.now
          Display.publish twoViews
          let afterDisplay ← Watch.now
          discard Watch.interrupted
          discard <| text.read
          return [start, afterText, afterDisplay, ← Watch.now]
        let paced := (command.runModel { editorModel with watch := { clock := 100, pace := 10 } }).1
        let still := (command.runModel editorModel).1
        return resulted paced == .inr [100, 110, 120, 130] && resulted still == .inr [0, 0, 0, 0] }]

end ModelTest
