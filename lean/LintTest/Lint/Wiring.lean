import Lint.Wiring
import LintTest.Check

/-!
# Lint tests: `Lint/Wiring.lean`

The checks of the wiring-set linter's rules, `lintWiringChecks`: which
types are a check set, a table of scenarios, a check of a root's check type
and an IO list producer; how a check set's value is read into its groups;
that a reference is counted for each place it is written; and which module
names are under a root's first name component. What the linter refuses in
a module is shown by its fixtures, which a build of the test roots runs
(`ModelTest/Lint/Wiring.lean` and the modules under
`ModelTest/Lint/Wiring/`, and the fixture package `greeting`'s
`GreetingTest/Linked/Lint/Wiring.lean`). The root module `LintTest` runs
the checks; its module doc says what each shows.
-/

namespace LintTest

open Lean

/-- The constant `name` as a type or a term. -/
def constant (name : Name) : Expr :=
  .const name []

/-- `List element`. -/
def listOf (element : Expr) : Expr :=
  mkApp (constant ``List) element

/-- `IO result`. -/
def ioOf (result : Expr) : Expr :=
  mkApp (constant ``IO) result

/-- A function type from `domain` to `codomain`, with no dependency. -/
def arrowTo (domain codomain : Expr) : Expr :=
  .forallE `x domain codomain .default

/-- `Editor.CheckGroup context check`. -/
def groupOf (context check : Expr) : Expr :=
  mkAppN (constant Lint.checkGroupType) #[context, check]

/-- A string literal. -/
def text (value : String) : Expr :=
  .lit (.strVal value)

/-- The checks of the wiring-set linter's rules (`Lint/Wiring.lean`). -/
def lintWiringChecks : List Check :=
  let check := constant `Root.Check
  let context := constant `Root.Context
  [{  name :=
        "a check set's type is a list of Editor.CheckGroup over a context and a check type, after any binders, and a list of anything else is none"
      run :=
        return Lint.checkSetOf? (listOf (groupOf context check)) == some (context, check) &&
            Lint.checkSetOf? (arrowTo (constant ``Nat) (listOf (groupOf context check))) ==
              some (context, check) &&
            Lint.checkSetOf? (listOf check) == none &&
            Lint.checkSetOf? (groupOf context check) == none },
    { name := "a table of scenarios is a list of Editor.Scenario, and one scenario is none"
      run :=
        return Lint.isScenarioTable (listOf (constant Lint.scenarioType)) &&
            !Lint.isScenarioTable (constant Lint.scenarioType) &&
            !Lint.isScenarioTable (listOf check) },
    { name :=
        "a check of a root's check type is the type or a list of it after any binders, and nothing generic or of another type"
      run :=
        return Lint.isCheckOf check check && Lint.isCheckOf check (listOf check) &&
            Lint.isCheckOf check (arrowTo context (listOf check)) &&
            !Lint.isCheckOf check (listOf (constant `Other.Check)) &&
            !Lint.isCheckOf check (.forallE `α (.sort 1) (.bvar 0) .default) &&
            !Lint.isCheckOf check (ioOf (listOf check)) },
    { name :=
        "an IO list producer is IO of a list of a closed type, of strings, of pairs or of checks, after any binders, and not IO of a generic list, a list alone or IO of one check"
      run :=
        let pair := mkAppN (constant ``Prod) #[constant ``String, constant ``Bool]
        return Lint.isIoListProducer (ioOf (listOf (constant ``String))) &&
            Lint.isIoListProducer (arrowTo context (ioOf (listOf pair))) &&
            Lint.isIoListProducer (ioOf (listOf check)) &&
            !Lint.isIoListProducer (.forallE `β (.sort 1) (ioOf (listOf (.bvar 0))) .implicit) &&
            !Lint.isIoListProducer (listOf (constant ``String)) &&
            !Lint.isIoListProducer (ioOf check) },
    { name :=
        "a check set's value is read into its groups in order: a plain group's checks, and a wired group's module literal, set and checks, a module that is no literal read as none"
      run :=
        let plain := mkAppN (constant Lint.plainName) #[context, check, constant `Root.steppedChecks]
        let wired :=
          mkAppN (constant Lint.wiredName)
            #[context, check, text "Root.Real", constant `wiringSet.Root.Real, constant `Root.realChecks]
        let unread :=
          mkAppN (constant Lint.wiredName)
            #[context, check, constant `Root.name, constant `wiringSet.Root.Real, constant `Root.more]
        let value :=
          mkAppN (constant ``List.cons) #[plain, mkAppN (constant ``List.cons) #[wired, unread]]
        let read :=
          (Lint.groupsOf value).map fun
            | .plain checks => s!"plain {checks}"
            | .wired module set checks => s!"wired {module} {set} {checks}"
        return read ==
            #["plain Root.steppedChecks", "wired (some Root.Real) wiringSet.Root.Real Root.realChecks",
              "wired none wiringSet.Root.Real Root.more"] },
    { name := "a constant written twice is referenced twice, in the order it is written"
      run :=
        let twice :=
          mkAppN (constant ``HAppend.hAppend) #[constant `Root.a, constant `Root.b, constant `Root.a]
        return Lint.constantsOf twice == #[``HAppend.hAppend, `Root.a, `Root.b, `Root.a] },
    { name :=
        "a module is under a root's first name component when its own first component is that one, and none is under no component"
      run :=
        return Lint.isUnder (some `FilesTest) `FilesTest.Linked.Files.Real &&
            !Lint.isUnder (some `FilesTest) `Editor.Test.Fixture.RealThread &&
            !Lint.isUnder none `FilesTest.Linked && Lint.firstComponent `ConfigTest.Editor == some `ConfigTest &&
            Lint.moduleNamed "ConfigTest.Editor.Job.Real" == `ConfigTest.Editor.Job.Real },
    { name :=
        "the bindings' module, a root that imports it or one under it links the library, is Editor.Ffi"
      run :=
        return Lint.bindingsModule == `Editor.Ffi && Lint.bindingsModule.isPrefixOf `Editor.Ffi.Timers },
    { name :=
        "a main selects by the shared wiring mode when it reaches a check set, Editor.CheckGroup.select and a shared reader of the mode, and neither the wiring groups alone nor the wiring mode named is one"
      run :=
        let set := `Root.checks
        let isSet := (· == set)
        return Lint.selectName == `Editor.CheckGroup.select &&
            Lint.modeReaders ==
              #[`Editor.CheckGroup.Mode.ofArguments?, `Editor.CheckGroup.Mode.read?,
                `Editor.CheckGroup.Mode.ofSubcommand?] &&
            Lint.selectsByMode isSet #[set, Lint.selectName, `Editor.CheckGroup.Mode.ofArguments?] &&
            Lint.selectsByMode isSet #[`Editor.CheckGroup.Mode.read?, Lint.selectName, set] &&
            Lint.selectsByMode isSet #[set, Lint.selectName, `Editor.CheckGroup.Mode.ofSubcommand?] &&
            !Lint.selectsByMode isSet #[set, Lint.selectName, `Editor.CheckGroup.Mode.wiring] &&
            !Lint.selectsByMode isSet #[set, `Editor.CheckGroup.wiring, `Editor.CheckGroup.all] &&
            !Lint.selectsByMode isSet #[set, `Editor.CheckGroup.Mode.ofArguments?] &&
            !Lint.selectsByMode isSet #[set, Lint.selectName] &&
            !Lint.selectsByMode isSet #[Lint.selectName, `Editor.CheckGroup.Mode.ofArguments?] }]

end LintTest
