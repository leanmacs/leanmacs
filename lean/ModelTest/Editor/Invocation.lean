import Editor.Invocation
import ModelTest.Check

/-!
# Model tests: `Editor/Invocation.lean`

The model tests of `Editor/Invocation.lean`: `invocationChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of invocations (`Editor/Invocation.lean`): two can be
compared, by their command names and their arguments. -/
def invocationChecks : List Check :=
  let save : Invocation := { command := "save" }
  let insert (text : String) : Invocation := { command := "self-insert", arguments := [.str text] }
  [{  name := "two invocations of one command with the same arguments are equal"
      run :=
        pure
          (decide (save = { command := "save" }) && decide (insert "a" = insert "a") &&
            decide
              (({ command := "move", arguments := [.nat 2, .int (-1), .bool true] } : Invocation) =
                { command := "move", arguments := [.nat 2, .int (-1), .bool true] })) },
    { name := "invocations of commands with different names are unequal"
      run := pure (decide (save ≠ { command := "quit" })) },
    { name :=
        "invocations of one command are unequal when an argument differs: in its value, in its kind, in how many there are, or in their order"
      run :=
        pure
          (decide (insert "a" ≠ insert "b") &&
            decide
              (({ command := "move", arguments := [.nat 1] } : Invocation) ≠
                { command := "move", arguments := [.int 1] }) &&
            decide (save ≠ { command := "save", arguments := [.bool false] }) &&
            decide
              (({ command := "move", arguments := [.nat 1, .nat 2] } : Invocation) ≠
                { command := "move", arguments := [.nat 2, .nat 1] })) }]

end ModelTest
