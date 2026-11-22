import Editor.Api
import Editor.Command.Call
import Editor.Test.Driver
import Editor.Test.Keys
import Editor.Test.Loop
import ModelTest.Check

/-!
# Model tests: `Editor/Command/Call.lean`

The model tests of `Editor/Command/Call.lean`: `callChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- A driver of the call checks: `C-a` runs `count` with the argument 3,
`C-b` with none, `C-c` with a text and then 2, and `C-d` with 0; `count`
says its call's count and steps in the echo area. -/
def callDriver : Option TestDriver :=
  let counted (arguments : List Argument) : Invocation := { command := "count", arguments }
  let keys :=
    dispatchKeys
      [("C-a", counted [.nat 3]), ("C-b", counted []), ("C-c", counted [.str "x", .nat 2]),
        ("C-d", counted [.nat 0])]
      [("count", fun call => do
          message s!"{call.count} {call.steps}"
          return none)]
  (Loop.Driver.over keys (fun _ => none) (EditorState.initial ⟨640, 480⟩) editorModel).toOption

/-- The checks of what a command reads of its call (`Editor/Command/Call.lean`). -/
def callChecks : List Check :=
  [{  name :=
        "a call's count is its first argument when that is a natural number and 0 otherwise, and its steps are at least one: 3 and 3 for the argument 3, 0 and 1 for no argument, for a text first and for the argument 0"
      run :=
        pure <|
          match callDriver with
          | none => false
          | some driver =>
            let said (keys : String) : Option String := echoOf (fedTo driver (presses keys)).1
            said "C-a" == some "3 3" && said "C-b" == some "0 1" && said "C-c" == some "0 1" &&
              said "C-d" == some "0 1" }]

end ModelTest
