import Editor.Api
import Editor.Command.Control
import ModelTest.Check
import ModelTest.Support.Models
import ModelTest.Support.States

/-!
# Model tests: `Editor/Command/Control.lean`

The model tests of `Editor/Command/Control.lean`: `controlRequestChecks`.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of what a runner answers a control request where no loop
dispatched the command (`ControlRequest.bare`,
`Editor/Command/Control.lean`), and of the API's operations over it. -/
def controlRequestChecks : List Check :=
  [{  name :=
        "with no loop to act, a control request runs nothing and ends nothing: running a command answers false, asking a source none, asking an at-point source none, matching a text no hit, and giving up and breaking off are answered as a write with no reply"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            match state.target? ⟨0⟩ with
            | none => false
            | some target =>
              ControlRequest.bare (.runCommand "x" { target }) == false &&
                ControlRequest.bare (.askSource "x" { text := "w", view := ⟨0⟩ }) == none &&
                ControlRequest.bare (.askAtPoint "line" { view := ⟨0⟩, offset := 0 }) == none &&
                ControlRequest.bare (.matchCandidates (some "buffer") "w" #["w", "wq"]) == #[] &&
                ControlRequest.bare (.giveUp "no such thing") == () &&
                ControlRequest.bare (.breakOff "far enough") == () },
    { name :=
        "run where no loop dispatched the command, giving up and breaking off are refused with badSelection, and running another command answers false with nothing run"
      run := do
        let gives : EditorM Unit := giveUp "x"
        let breaks : EditorM Unit := breakOff "x"
        let runs : EditorM Bool := do
          let some target := (← liftM twoBuffers : EditorState).target? ⟨0⟩
            | throw .noSuchText
          runCommand "x" { target }
        return resulted (gives.runModel editorModel).1 == .inl .badSelection &&
            resulted (breaks.runModel editorModel).1 == .inl .badSelection &&
            resulted (runs.runModel editorModel).1 == .inr false }]

end ModelTest
