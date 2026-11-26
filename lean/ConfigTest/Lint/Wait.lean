import ConfigTest.Check
import Editor.Ffi.Syntax
import Editor.Headless
import Editor.Test.Linked.Host

/-!
# Config tests: `Lint/Wait.lean`

The wait linter's fixtures that need the host, which only the config tests
link, with the elaborator it imports: the linked kit's join and the real
syntax service's settle refused in a check module; and an idle wait (kind a of
`docs/dev-practices/inferred-waits.md`) put together from the host's
`waitWhile` and a kind of wait, written outside the modules it is allowed
in, each wrapped in `#guard_msgs`, which expects `linter.inferredWait`'s
error. Building this module shows that the linter refuses them; it holds
no check. The model tests' fixtures (`ModelTest/Lint/Wait.lean`) and
the contract tests' (`ContractTest/Lint/Wait.lean`) show the other
kinds.
-/

/-! An idle wait cannot be put together from parts: the host's `waitWhile`
takes a kind of wait, and the kinds that infer "done" from the host's idle
or its job count are marked (`Headless.Wait.Kind.join`, `.idle`, `.quiet`,
`.indexed`), as are the fields a new kind would set to do the same (its
`busy` and `still`) and its constructor. -/

/-- The guard of the fixtures' waits. -/
def ConfigTest.LintFixture.guard : Editor.HangGuard :=
  .on "the fixture's wait, never run" 1000

/--
error: `Editor.Headless.Wait.Kind.join`, in `ConfigTest.LintFixture.joinByKind`, is an inferred wait (idle): it infers done from something shared, not from a signal for this work. It is allowed only in Editor.Headless, Editor.Headless.Stepped, Editor.Headless.Wait, Editor.Test.Linked.Host and the test modules that mirror them; wait on the work's own handle, promise or flush, or, for a site a later phase removes, `set_option linter.inferredWait false in` with its row of docs/dev-practices/inferred-waits.md

Note: This linter can be disabled with `set_option linter.inferredWait false`
-/
#guard_msgs in
/-- A bad declaration: a `join` through the host's `waitWhile`. -/
def ConfigTest.LintFixture.joinByKind (host : Editor.Headless.Host) : IO Editor.Headless.Wait :=
  host.waitWhile ConfigTest.LintFixture.guard
    { Editor.Headless.Wait.Kind.join with marker := false }

/--
error: `Editor.Headless.Wait.Kind.busy`, in `ConfigTest.LintFixture.quietByHand`, is an inferred wait (idle): it infers done from something shared, not from a signal for this work. It is allowed only in Editor.Headless, Editor.Headless.Stepped, Editor.Headless.Wait and the test modules that mirror them; wait on the work's own handle, promise or flush, or, for a site a later phase removes, `set_option linter.inferredWait false in` with its row of docs/dev-practices/inferred-waits.md

Note: This linter can be disabled with `set_option linter.inferredWait false`
---
error: `Editor.Headless.Wait.Kind.still`, in `ConfigTest.LintFixture.quietByHand`, is an inferred wait (idle): it infers done from something shared, not from a signal for this work. It is allowed only in Editor.Headless, Editor.Headless.Stepped, Editor.Headless.Wait and the test modules that mirror them; wait on the work's own handle, promise or flush, or, for a site a later phase removes, `set_option linter.inferredWait false in` with its row of docs/dev-practices/inferred-waits.md

Note: This linter can be disabled with `set_option linter.inferredWait false`
-/
#guard_msgs in
/-- A bad declaration: a wait answered at the host's idle, its kind made by
hand. -/
def ConfigTest.LintFixture.quietByHand (host : Editor.Headless.Host) : IO Editor.Headless.Wait :=
  host.waitWhile ConfigTest.LintFixture.guard
    { what := "idle", busy := fun _ => pure true, still := some .settled, hung := .busy }

/--
error: `Editor.Headless.Wait.Kind.busy`, in `ConfigTest.LintFixture.jobsByHand`, is an inferred wait (idle): it infers done from something shared, not from a signal for this work. It is allowed only in Editor.Headless, Editor.Headless.Stepped, Editor.Headless.Wait and the test modules that mirror them; wait on the work's own handle, promise or flush, or, for a site a later phase removes, `set_option linter.inferredWait false in` with its row of docs/dev-practices/inferred-waits.md

Note: This linter can be disabled with `set_option linter.inferredWait false`
-/
#guard_msgs in
/-- A bad declaration: a `settle` whose `busy` reads the job count. -/
def ConfigTest.LintFixture.jobsByHand (host : Editor.Headless.Host) : IO Editor.Headless.Wait :=
  host.waitWhile ConfigTest.LintFixture.guard
    { Editor.Headless.Wait.Kind.settle with busy := fun progress => pure (progress.jobs > 0) }

/--
error: `Editor.Headless.Wait.Kind.mk`, in `ConfigTest.LintFixture.madeKind`, is an inferred wait (idle): it infers done from something shared, not from a signal for this work. It is allowed only in Editor.Headless, Editor.Headless.Stepped, Editor.Headless.Wait and the test modules that mirror them; wait on the work's own handle, promise or flush, or, for a site a later phase removes, `set_option linter.inferredWait false in` with its row of docs/dev-practices/inferred-waits.md

Note: This linter can be disabled with `set_option linter.inferredWait false`
-/
#guard_msgs in
/-- A bad declaration: a kind made with its constructor. -/
def ConfigTest.LintFixture.madeKind : Editor.Headless.Wait.Kind :=
  ⟨"idle", fun _ => pure true, some .settled, .busy, false⟩

/-- A `settle`, whose kind infers nothing from the host's idle, is refused
nothing. -/
def ConfigTest.LintFixture.settles (host : Editor.Headless.Host) : IO Editor.Headless.Wait :=
  host.waitWhile ConfigTest.LintFixture.guard .settle

/-! The linked kit's waits are refused in a check module too: a check that
infers "done" from the host's idle through the kit's `Driven.join`, or that
waits on the real syntax service's delivery (`Ffi.syntaxSettle`, a real
effect whose fake is `FakeSyntaxService`), outside their allowed modules. -/

/--
error: `Editor.Test.Linked.Driven.join`, in `ConfigTest.LintFixture.kitJoin`, is an inferred wait (idle): it infers done from something shared, not from a signal for this work. It is allowed only in Editor.Test.Linked.Host and the test modules that mirror them; wait on the work's own handle, promise or flush, or, for a site a later phase removes, `set_option linter.inferredWait false in` with its row of docs/dev-practices/inferred-waits.md

Note: This linter can be disabled with `set_option linter.inferredWait false`
-/
#guard_msgs in
/-- A bad declaration: a check that joins through the kit's driven host. -/
def ConfigTest.LintFixture.kitJoin (drive : Editor.Test.Linked.Driven) : IO Editor.Headless.Wait :=
  drive.join ConfigTest.LintFixture.guard

/--
error: `Editor.Ffi.syntaxSettle`, in `ConfigTest.LintFixture.syntaxSettled`, is an inferred wait (realEffect): it infers done from something shared, not from a signal for this work. It is allowed only in Editor.Ffi.Syntax, Editor.SyntaxTree.Real, Editor.SyntaxTree.DeliveryContract, Editor.Test.Linked.Shipped, Editor.Test.Linked.Syntax, Editor.Test.Linked.Grammar, Editor.Headless and the test modules that mirror them; wait on the work's own handle, promise or flush, or, for a site a later phase removes, `set_option linter.inferredWait false in` with its row of docs/dev-practices/inferred-waits.md

Note: This linter can be disabled with `set_option linter.inferredWait false`
-/
#guard_msgs in
/-- A bad declaration: a check that settles the real syntax service. -/
def ConfigTest.LintFixture.syntaxSettled (snapshot : Editor.Ffi.Snapshot) : IO Bool :=
  Editor.Ffi.syntaxSettle snapshot ConfigTest.LintFixture.guard
