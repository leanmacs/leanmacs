import Editor.Executable.Refusal
import Editor.InputScheme.Test
import ModelTest.Check

/-!
# Model tests: `Editor/Executable/Refusal.lean`

The model tests of `Editor/Executable/Refusal.lean`:
`executableRefusalChecks`. The root module `ModelTest` runs them; its
module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the executable's scheme refusal
(`Executable.schemeRefusal?`): which modes an editor with no input scheme
refuses, and what it says. -/
def executableRefusalChecks : List Check :=
  let refusing : List Executable.Mode :=
    [.headless {} ["/c", "/t"], .window {} [], .window {} ["f.txt"], .probe {}]
  let running : List Executable.Mode := [.demo, .version, .windowCheck []]
  let one : Array SchemePackage := #[{ name := "test", scheme := TestScheme.scheme }]
  [{  name :=
        "with no input scheme the headless mode, the window mode and the probe are refused with editor: and the sentence that none is installed"
      run :=
        pure
          (refusing.all fun mode =>
            Executable.schemeRefusal? mode #[] ==
              some ("editor: " ++ SchemePackage.noneInstalled)) },
    { name := "with no input scheme the demonstration, the version and the keyboard check run"
      run := pure (running.all fun mode => Executable.schemeRefusal? mode #[] == none) },
    { name := "with one input scheme no mode is refused"
      run :=
        pure ((refusing ++ running).all fun mode => Executable.schemeRefusal? mode one == none) }]

end ModelTest
