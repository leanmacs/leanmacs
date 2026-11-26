import Editor.Test.Fixture.Support
import ModelTest.Check

/-!
# Model tests: `Editor/Test/Fixture/Support.lean`

The model tests of a package's fixture support: what `Support.merge` gives
and what it refuses (`supportChecks`). The root module `ModelTest` runs
them; its module doc says what they show.
-/

namespace ModelTest

open Editor
open Editor.Test.Fixture

/-- A package's own fake named `name`, which makes a service that takes
nothing. -/
def namedFake (name : String) : Job.PackageFake :=
  { name
    make := fun _ _ =>
      return {
          service :=
            { name, start := fun _ _ => pure false, take := fun _ _ => pure (.error (.refused "")),
              cancel := fun _ => pure (), flush := fun _ => pure () }
          quiescent := pure true } }

/-- What `merge` refuses `supports` for, if it does. -/
def refusalOf (supports : Array Support) : Option String :=
  match Support.merge supports with
  | .ok _ => none
  | .error reason => some reason

/-- The checks of `Support.merge`, each pure. -/
def supportChecks : List Check :=
  [{  name := "with no support, merge gives the core's setups as they are and no fake"
      run := do
        match Support.merge #[] with
        | .ok (setups, fakes) =>
          return setups.map (·.1) == Setup.core.map (·.1) && fakes.isEmpty
        | .error _ =>
          return false },
    { name :=
        "merge keeps the core's setups first, appends each support's in order, and gathers every support's fakes in order"
      run := do
        let first : Support :=
          { name := "first", setups := #[("p/tests/headless/a/script", Setup.default)]
            fakes := #[namedFake "alpha"] }
        let second : Support :=
          { name := "second"
            setups :=
              #[("q/tests/headless/b/script", { Setup.default with workingDirectory := "/work/q" })]
            fakes := #[namedFake "beta", namedFake "gamma"] }
        match Support.merge #[first, second] with
        | .ok (setups, fakes) =>
          return setups.map (·.1) ==
                Setup.core.map (·.1) ++
                  #["p/tests/headless/a/script", "q/tests/headless/b/script"] &&
              (Setup.of "q/tests/headless/b/script" setups).workingDirectory == "/work/q" &&
              fakes.map (·.name) == #["alpha", "beta", "gamma"]
        | .error _ =>
          return false },
    { name :=
        "a script two supports declare a setup of is refused, naming the script and both, and so is one the core declares already"
      run := do
        let script := "p/tests/headless/a/script"
        let one : Support := { name := "one", setups := #[(script, Setup.default)] }
        let two : Support := { name := "two", setups := #[(script, Setup.default)] }
        let core := ((Setup.core[0]?).map (·.1)).getD ""
        let shadow : Support := { name := "shadow", setups := #[(core, Setup.default)] }
        return refusalOf #[one, two] ==
              some s!"the fixture {script} has a setup from both one and two" &&
            refusalOf #[shadow] ==
              some s!"the fixture {core} has a setup from both the core and shadow" }]

end ModelTest
