import ContractTest.Check
import Editor.Test.Linked.Jobs

/-!
# Contract tests: `Lint/Wait.lean`

The wait linter's fixture that needs the linked kit, which the model tests
cannot link: a "first X after Y" wait (kind b of
`docs/dev-practices/inferred-waits.md`) written outside the modules it is
allowed in, wrapped in `#guard_msgs`, which expects `linter.inferredWait`'s
error. Building this module shows that the linter refuses it; it holds no
check. The model tests' fixtures (`ModelTest/Lint/Wait.lean`) show
the other kinds.
-/

/--
error: `Editor.Test.Linked.startsArrive`, in `ContractTest.LintFixture.firstStart`, is an inferred wait (firstAfter): it infers done from something shared, not from a signal for this work. It is allowed only in Editor.Test.Linked.Jobs and the test modules that mirror them; wait on the work's own handle, promise or flush, or, for a site a later phase removes, `set_option linter.inferredWait false in` with its row of docs/dev-practices/inferred-waits.md

Note: This linter can be disabled with `set_option linter.inferredWait false`
-/
#guard_msgs in
/-- A bad declaration: the first start a real port is handed, which another
check's request can be. -/
def ContractTest.LintFixture.firstStart (start : UInt64 → Unit → BaseIO Unit) :
    BaseIO ((UInt64 → Unit → BaseIO Unit) × IO.Promise Unit) :=
  Editor.Test.Linked.startsArrive start 1
