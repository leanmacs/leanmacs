import Lint.RealHost
import LintTest.Check

/-!
# Lint tests: `Lint/RealHost.lean`

The checks of the real-host linter's rules, `lintRealHostChecks`: how a
mark's value and a module's declaration are read, which types are a
check's, and which modules are contract roots. What the linter refuses in a
module is shown by its fixtures, which a build of the test roots runs
(`ModelTest/Lint/RealHost.lean` and the modules under
`ModelTest/Lint/RealHost/`, `ConfigTest/Lint/RealHost.lean`). The root
module `LintTest` runs the checks; its module doc says what each shows.
-/

namespace LintTest

open Lean

/-- `Editor.WiringSet.<kind>` applied to the string literals `texts`, as a
declaration's value elaborates. -/
def declarationValue (kind : String) (texts : List String) : Expr :=
  mkAppN (.const (.str Lint.wiringSetType kind) []) (texts.map (.lit <| .strVal ·)).toArray

/-- The constant `name` as a type. -/
def typeNamed (name : Name) : Expr :=
  .const name []

/-- A function type from `domain` to `codomain`. -/
def arrow (domain codomain : Expr) : Expr :=
  .forallE `x domain codomain .default

/-- The checks of the real-host linter's rules (`Lint/RealHost.lean`). -/
def lintRealHostChecks : List Check :=
  [{  name := "the mark of a constant is the constant's name with realHost added, and a module's declaration its name with wiringSet added"
      run :=
        return Lint.hostMarkOf `Editor.Headless.withHost == `Editor.Headless.withHost.realHost &&
            Lint.wiringSetOf `ConfigTest.Editor.Job.Real == `ConfigTest.Editor.Job.Real.wiringSet },
    { name := "a mark's value is loop or service, a constructor of Editor.RealHost, and nothing else"
      run :=
        return Lint.decodeHost (.const (.str Lint.hostType "loop") []) == some .loop &&
            Lint.decodeHost (.const (.str Lint.hostType "service") []) == some .service &&
            Lint.decodeHost (.const (.str Lint.hostType "thread") []) == none &&
            Lint.decodeHost (.const `Other.loop []) == none &&
            Lint.decodeHost (toExpr (0 : Nat)) == none },
    { name := "a declaration's value is a constructor of Editor.WiringSet applied to string literals, each read as written"
      run :=
        return Lint.decodeWiringSet (declarationValue "wiring" ["the diff service", "no fake"]) ==
              some (.wiring "the diff service" "no fake") &&
            Lint.decodeWiringSet (declarationValue "contract" ["Echo.Contract"]) ==
              some (.contract "Echo.Contract") &&
            Lint.decodeWiringSet (declarationValue "edge" ["main starts the services"]) ==
              some (.edge "main starts the services") },
    { name := "a declaration with an empty string, a string worked out, too few strings, or another type's constructor is none the linter reads"
      run :=
        let worked := mkApp (.const ``String.append []) (.lit (.strVal "a"))
        return Lint.decodeWiringSet (declarationValue "wiring" ["", ""]) == none &&
            Lint.decodeWiringSet (declarationValue "wiring" ["the diff service", ""]) == none &&
            Lint.decodeWiringSet (declarationValue "edge" []) == none &&
            Lint.decodeWiringSet
                (mkApp (.const (.str Lint.wiringSetType "contract") []) worked) == none &&
            Lint.decodeWiringSet (mkAppN (.const `Other.wiring []) #[.lit (.strVal "a"), .lit (.strVal "b")]) ==
              none &&
            Lint.decodeWiringSet (declarationValue "other" ["a"]) == none },
    { name := "a check's type is Check, a list of checks, a function to either, or an IO of either; IO Bool and a helper taking a check body are not"
      run :=
        let check := typeNamed `ConfigTest.Check
        let list := mkApp (typeNamed ``List) check
        let io (type : Expr) := mkApp (typeNamed ``IO) type
        let bool := typeNamed ``Bool
        let body := arrow (typeNamed `Session) (io bool)
        return Lint.isCheckType check && Lint.isCheckType list &&
            Lint.isCheckType (arrow (typeNamed `Context) list) &&
            Lint.isCheckType (io list) &&
            Lint.isCheckType (mkApp (typeNamed ``BaseIO) check) &&
            !Lint.isCheckType (io bool) &&
            !Lint.isCheckType (arrow body (io bool)) &&
            !Lint.isCheckType (typeNamed `Checked) },
    { name := "a contract root is a module under ContractTest, and no other"
      run :=
        return Lint.isContractRoot `ContractTest.Editor.SyntaxTree.Real &&
            Lint.isContractRoot `ContractTest &&
            !Lint.isContractRoot `ConfigTest.Editor.Headless &&
            !Lint.isContractRoot `Editor.Job.Contract }]

end LintTest
