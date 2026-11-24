import Lint.Wait
import LintTest.Check

/-!
# Lint tests: `Lint/Wait.lean`

The checks of the wait linters' rules, `lintWaitChecks`: the rules on
module names the linters apply, and how a mark's value is read. What the
linters refuse in a module is shown by their fixtures, which a build of
the test roots runs (`ModelTest/Lint/Wait.lean`,
`ConfigTest/Lint/Wait.lean`, `ContractTest/Lint/Wait.lean`). The root
module `LintTest` runs the checks; its module doc says what each shows.
-/

namespace LintTest

open Lean

/-- `Editor.InferredWait.<kind>` applied to `subjects`, as a mark's value
elaborates. -/
def markValue (kind : String) (subjects : Expr) : Expr :=
  .app (.const (.str Lint.markType kind) []) subjects

/-- The list literal of `names`, of type `List Name`, as a mark's subjects
elaborate. -/
def namesLiteral (names : List Name) : Expr :=
  let type := Expr.const ``Name []
  names.foldr (init := mkApp (.const ``List.nil [.zero]) type) fun name list =>
    mkApp3 (.const ``List.cons [.zero]) type (toExpr name) list

/-- The checks of the wait linters' rules (`Lint/Wait.lean`): what a test
module is, which test module mirrors which, and what a mark's value
says. -/
def lintWaitChecks : List Check :=
  [{  name :=
        "a test module is one whose first name component ends in Test, or the core's test kits under Editor.Test"
      run :=
        return Lint.isTestModule `ModelTest.Editor.Job.Activity &&
            Lint.isTestModule `CompileTest.Linked &&
            Lint.isTestModule `FilesApiTest.Fake &&
            Lint.isTestModule `Editor.Test.Linked.Host &&
            !Lint.isTestModule `Editor.Job.Activity &&
            !Lint.isTestModule `Editor.Headless &&
            !Lint.isTestModule `Editor.Testing },
    { name := "a test module mirrors the module it names under its root, and no other"
      run :=
        return Lint.mirrors `ModelTest.Editor.Job.Activity `Editor.Job.Activity &&
            Lint.mirrors `ContractTest.Editor.Job.Activity `Editor.Job.Activity &&
            !Lint.mirrors `ModelTest.Editor.Job.Activity `Editor.Job.Runner &&
            !Lint.mirrors `Editor.Job.Activity `Editor.Job.Activity &&
            !Lint.mirrors `ModelTest `Editor.Job.Activity },
    { name :=
        "a module of the wiring set beside a mirror, its Real module or a subject under it, mirrors the module too, and no deeper module or other name does"
      run :=
        return Lint.mirrors `ConfigTest.Editor.Headless.Real `Editor.Headless &&
            Lint.mirrors `ConfigTest.Editor.Headless.Real.Waits `Editor.Headless &&
            !Lint.mirrors `ConfigTest.Editor.Headless.Real.Waits.More `Editor.Headless &&
            !Lint.mirrors `ConfigTest.Editor.Headless.Stepped `Editor.Headless &&
            !Lint.mirrors `ConfigTest.Editor.Headless.Fake.Waits `Editor.Headless &&
            !Lint.mirrors `ConfigTest.Editor.Real `Editor.Headless },
    { name := "the mark of a constant is the constant's name with inferredWait added"
      run :=
        return Lint.markOf `Editor.Job.Activity.seen == `Editor.Job.Activity.seen.inferredWait },
    { name := "a mark's value written out says its kind and its subject modules, in order"
      run :=
        return Lint.decodeMark (fun _ => none)
              (markValue "idle" (namesLiteral [`Editor.Headless.Wait, `Editor.Test.Linked.Host])) ==
            some { kind := `idle, subjects := #[`Editor.Headless.Wait, `Editor.Test.Linked.Host] } &&
          Lint.decodeMark (fun _ => none) (markValue "count" (namesLiteral [])) ==
            some { kind := `count, subjects := #[] } },
    { name := "a mark's subjects may be a constant whose value is a list written out"
      run :=
        let shared := namesLiteral [`Editor.Job.Runner]
        let resolve (name : Name) := if name == `Shared.subjects then some shared else none
        return Lint.decodeMark resolve (markValue "count" (.const `Shared.subjects [])) ==
            some { kind := `count, subjects := #[`Editor.Job.Runner] } &&
          Lint.decodeMark (fun _ => none) (markValue "count" (.const `Shared.subjects [])) == none },
    { name := "a value that is no constructor of the mark's type, or names no list, is no mark"
      run :=
        return Lint.decodeMark (fun _ => none)
              (.app (.const `Other.count []) (namesLiteral [`Editor.Job.Runner])) == none &&
          Lint.decodeMark (fun _ => none) (.const (.str Lint.markType "count") []) == none &&
          Lint.decodeMark (fun _ => none) (markValue "count" (toExpr (3 : Nat))) == none }]

end LintTest
