import Editor.RealHost
import ModelTest.Check

/-!
# Model tests: `Lint/RealHost.lean`

The real-host linter's fixtures in a test module that declares no wiring
set, with a stand-in for a real host marked here: each bad declaration is
wrapped in `#guard_msgs`, which expects the lint's error (an error under
`warningAsError`), so a build of this module shows that the linter refuses
it, and the declaration is no check of the suite. The modules under
`ModelTest/Lint/RealHost/` hold the fixtures of a module that declares
itself: one the linter cannot read, `.wiring`, `.contract` and `.edge`.
This module imports nothing of the linter: the build loads it as a Lean
plugin (`lean/lakefile.lean`, `lintPlugin`), and `model-test` links no
module of Lean's frontend. The linter's checks are
`LintTest.lintRealHostChecks` (`LintTest/Lint/RealHost.lean`).
-/

/-- The mark of `realLoop`, before it. -/
def ModelTest.RealHostFixture.realLoop.realHost : Editor.RealHost :=
  .loop

/-- A stand-in for a real host: marked, so a reference to it is one to a
real loop thread, though it runs nothing. -/
def ModelTest.RealHostFixture.realLoop : IO Unit :=
  pure ()

/-! A check outside the wiring set that reaches a real host is refused. -/

/--
error: `ModelTest.RealHostFixture.realLoop`, in `ModelTest.RealHostFixture.loopCheck`, runs a real editor loop thread (loop): a check runs one only in a module of the wiring set: declare `def wiringSet.ModelTest.Lint.RealHost : Editor.WiringSet := .wiring "…" "…"` in a module that wires the adapter, or run the check on the stepped host and the fakes (AGENTS.md, "Deterministic concurrency in tests")

Note: This linter can be disabled with `set_option linter.realHost false`
-/
#guard_msgs in
/-- A bad declaration: an unmarked check that runs a real loop thread. -/
def ModelTest.RealHostFixture.loopCheck : ModelTest.Check :=
  { name := "a check over a real loop thread",
    run := do
      ModelTest.RealHostFixture.realLoop
      return true }

/-! A private wrapper launders nothing: it is not linted where it is
written, and a reference to it is a reference to what it hands on. -/

/-- A private wrapper of a real host: not refused, as it is private. -/
private def ModelTest.RealHostFixture.hidden : IO Unit :=
  ModelTest.RealHostFixture.realLoop

/--
error: `ModelTest.RealHostFixture.realLoop`, in `ModelTest.RealHostFixture.hiddenCheck`, runs a real editor loop thread (loop), through `ModelTest.RealHostFixture.hidden`: a check runs one only in a module of the wiring set: declare `def wiringSet.ModelTest.Lint.RealHost : Editor.WiringSet := .wiring "…" "…"` in a module that wires the adapter, or run the check on the stepped host and the fakes (AGENTS.md, "Deterministic concurrency in tests")

Note: This linter can be disabled with `set_option linter.realHost false`
-/
#guard_msgs in
/-- A bad declaration: an unmarked check over a private wrapper of a real
host. -/
def ModelTest.RealHostFixture.hiddenCheck : ModelTest.Check :=
  { name := "a check over a private wrapper",
    run := do
      ModelTest.RealHostFixture.hidden
      return true }

/-! A declaration that has a mark is an entry point: a reference inside it
is allowed, and the rule holds its callers. -/

/-- The mark of `entry`, before it. -/
def ModelTest.RealHostFixture.entry.realHost : Editor.RealHost :=
  .loop

/-- A marked entry point over a real host: refused nothing. -/
def ModelTest.RealHostFixture.entry : IO Unit :=
  ModelTest.RealHostFixture.realLoop

/-! A mark the linter cannot read is refused where the constant it marks
is referenced: one of another type than `Editor.RealHost`, and one whose
value is worked out. -/

/-- A bad mark: not of the type of a mark. -/
def ModelTest.RealHostFixture.mistyped.realHost : Nat :=
  0

/-- A constant with a bad mark. -/
def ModelTest.RealHostFixture.mistyped : Nat :=
  0

/--
error: `ModelTest.RealHostFixture.mistyped.realHost` is named as a mark and is not of the type `Editor.RealHost`

Note: This linter can be disabled with `set_option linter.realHost false`
-/
#guard_msgs in
/-- A reference to a constant whose mark is of another type. -/
def ModelTest.RealHostFixture.readsMistyped : Nat :=
  ModelTest.RealHostFixture.mistyped

/-- A bad mark: its kind is worked out, not written. -/
def ModelTest.RealHostFixture.computed.realHost : Editor.RealHost :=
  if true then .loop else .service

/-- A constant with a bad mark. -/
def ModelTest.RealHostFixture.computed : Nat :=
  0

/--
error: `ModelTest.RealHostFixture.computed.realHost` is a mark the real-host linter cannot read: write its value as `.loop` or `.service`

Note: This linter can be disabled with `set_option linter.realHost false`
-/
#guard_msgs in
/-- A reference to a constant whose mark is worked out. -/
def ModelTest.RealHostFixture.readsComputed : Nat :=
  ModelTest.RealHostFixture.computed
