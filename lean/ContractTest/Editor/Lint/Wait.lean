import ContractTest.Check
import Editor.Headless
import Editor.Test.Linked.Jobs

/-!
# Contract tests: `Editor/Lint/Wait.lean`

The wait linter's fixtures that need the linked kit or the host, which the
model tests cannot link: a "first X after Y" wait (kind b of
`docs/dev-practices/inferred-waits.md`), and an idle wait (kind a) put
together from the host's `waitWhile` and a kind of wait, written outside
the modules they are allowed in, each wrapped in `#guard_msgs`, which
expects `linter.inferredWait`'s error. Building this module shows that the linter refuses it; it holds no
check. The model tests' fixtures (`ModelTest/Editor/Lint/Wait.lean`) show
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

/-! An idle wait cannot be put together from parts: the host's `waitWhile`
takes a kind of wait, and the kinds that infer "done" from the host's idle
or its job count are marked (`Headless.Wait.Kind.join`, `.idle`, `.quiet`,
`.indexed`), as are the fields a new kind would set to do the same (its
`busy` and `still`) and its constructor. -/

/-- The guard of the fixtures' waits. -/
def ContractTest.LintFixture.guard : Editor.HangGuard :=
  .on "the fixture's wait, never run" 1000

/--
error: `Editor.Headless.Wait.Kind.join`, in `ContractTest.LintFixture.joinByKind`, is an inferred wait (idle): it infers done from something shared, not from a signal for this work. It is allowed only in Editor.Headless, Editor.Headless.Stepped, Editor.Headless.Wait, Editor.Test.Linked.Host and the test modules that mirror them; wait on the work's own handle, promise or flush, or, for a site a later phase removes, `set_option linter.inferredWait false in` with its row of docs/dev-practices/inferred-waits.md

Note: This linter can be disabled with `set_option linter.inferredWait false`
-/
#guard_msgs in
/-- A bad declaration: a `join` through the host's `waitWhile`. -/
def ContractTest.LintFixture.joinByKind (host : Editor.Headless.Host) : IO Editor.Headless.Wait :=
  host.waitWhile ContractTest.LintFixture.guard
    { Editor.Headless.Wait.Kind.join with marker := false }

/--
error: `Editor.Headless.Wait.Kind.busy`, in `ContractTest.LintFixture.quietByHand`, is an inferred wait (idle): it infers done from something shared, not from a signal for this work. It is allowed only in Editor.Headless, Editor.Headless.Stepped, Editor.Headless.Wait and the test modules that mirror them; wait on the work's own handle, promise or flush, or, for a site a later phase removes, `set_option linter.inferredWait false in` with its row of docs/dev-practices/inferred-waits.md

Note: This linter can be disabled with `set_option linter.inferredWait false`
---
error: `Editor.Headless.Wait.Kind.still`, in `ContractTest.LintFixture.quietByHand`, is an inferred wait (idle): it infers done from something shared, not from a signal for this work. It is allowed only in Editor.Headless, Editor.Headless.Stepped, Editor.Headless.Wait and the test modules that mirror them; wait on the work's own handle, promise or flush, or, for a site a later phase removes, `set_option linter.inferredWait false in` with its row of docs/dev-practices/inferred-waits.md

Note: This linter can be disabled with `set_option linter.inferredWait false`
-/
#guard_msgs in
/-- A bad declaration: a wait answered at the host's idle, its kind made by
hand. -/
def ContractTest.LintFixture.quietByHand (host : Editor.Headless.Host) : IO Editor.Headless.Wait :=
  host.waitWhile ContractTest.LintFixture.guard
    { what := "idle", busy := fun _ => pure true, still := some .settled, hung := .busy }

/--
error: `Editor.Headless.Wait.Kind.busy`, in `ContractTest.LintFixture.jobsByHand`, is an inferred wait (idle): it infers done from something shared, not from a signal for this work. It is allowed only in Editor.Headless, Editor.Headless.Stepped, Editor.Headless.Wait and the test modules that mirror them; wait on the work's own handle, promise or flush, or, for a site a later phase removes, `set_option linter.inferredWait false in` with its row of docs/dev-practices/inferred-waits.md

Note: This linter can be disabled with `set_option linter.inferredWait false`
-/
#guard_msgs in
/-- A bad declaration: a `settle` whose `busy` reads the job count. -/
def ContractTest.LintFixture.jobsByHand (host : Editor.Headless.Host) : IO Editor.Headless.Wait :=
  host.waitWhile ContractTest.LintFixture.guard
    { Editor.Headless.Wait.Kind.settle with busy := fun progress => pure (progress.jobs > 0) }

/--
error: `Editor.Headless.Wait.Kind.mk`, in `ContractTest.LintFixture.madeKind`, is an inferred wait (idle): it infers done from something shared, not from a signal for this work. It is allowed only in Editor.Headless, Editor.Headless.Stepped, Editor.Headless.Wait and the test modules that mirror them; wait on the work's own handle, promise or flush, or, for a site a later phase removes, `set_option linter.inferredWait false in` with its row of docs/dev-practices/inferred-waits.md

Note: This linter can be disabled with `set_option linter.inferredWait false`
-/
#guard_msgs in
/-- A bad declaration: a kind made with its constructor. -/
def ContractTest.LintFixture.madeKind : Editor.Headless.Wait.Kind :=
  ⟨"idle", fun _ => pure true, some .settled, .busy, false⟩

/-- A `settle`, whose kind infers nothing from the host's idle, is refused
nothing. -/
def ContractTest.LintFixture.settles (host : Editor.Headless.Host) : IO Editor.Headless.Wait :=
  host.waitWhile ContractTest.LintFixture.guard .settle
