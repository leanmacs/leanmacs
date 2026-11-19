import ConfigTest.Check
import Editor.Config.Elaborate
import Editor.Config.Elaborator.Contract

/-!
# Config tests: `Editor/Config/Elaborator/Contract.lean`

The elaborator port's contract held of the real adapter over Lean's
elaborator (`Editor/Config/Elaborate.lean`): `elaboratorContractChecks`,
with `realSubject`. `model-test` holds the same properties of the port's
model. The root module `ConfigTest` runs them; its module doc says what
each shows.
-/

namespace ConfigTest

open Editor

/-- The real elaborator as the subject of the port's contract. A file is
Lean: a definition is a `def` of a number, a use an `example` that names
the constant, a failing line a type error, a warning line a `sorry`, and
`setup` a definition at the type the editor runs. The base the checks
share holds `Editor` and can grow to hold `Lean`; `Lake` is in the
toolchain and is not linked. -/
def realSubject (context : Context) :
    Config.Elaborator.Contract.Subject Config.Elaborate.Base Config.Elaborate.Handle :=
  { elaborator := context.elaborator,
    write := fun lines =>
      "\n".intercalate
        (lines.map fun line =>
            match line with
            | .import module => s!"import {module}"
            | .define name => s!"def {name} : Nat := 0"
            | .use name => s!"example := @{name}"
            | .fail => "example : Nat := \"fail\""
            | .warn => "example : Nat := sorry"
            | .setup => "def setup : Editor.SetupM Unit := pure ()").toList,
    held := ("Editor", "Editor.SetupM"), grown := ("Lean", "Lean.Elab.Command.elabCommand"),
    unlinked := "Lake" }

/-- The elaborator port's contract (`Editor/Config/Elaborator/Contract.lean`)
held of the real adapter (`realSubject`): each property as a check. -/
def elaboratorContractChecks (context : Context) : List Check :=
  (Config.Elaborator.Contract.properties (realSubject context)).map fun property =>
    { name := s!"the real elaborator: {property.name}", run := property.holds }

end ConfigTest
