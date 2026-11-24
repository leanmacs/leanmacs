import Editor.RealHost
import ModelTest.Check

/-!
# Model tests: `Lint/RealHost.lean`, a declaration it cannot read

The real-host linter's fixtures of a module's declaration
(`wiringSet.<module>`, `Editor/RealHost.lean`): one with an empty string is
refused where it is declared, and the module is then one that declares
nothing, so a check of it that reaches a real host is refused as any test
module's is; and one named after another module is refused. The launder
rule of a module whose declaration the linter reads is
`ModelTest/Lint/RealHost/Launder.lean`'s.
-/

/--
error: `wiringSet.ModelTest.Lint.RealHost.Declaration` is a wiring set the real-host linter cannot read: write it as a constructor of `Editor.WiringSet` applied to string literals none of which is empty, as `.wiring "the library's diff service" "why a fake cannot stand in"`

Note: This linter can be disabled with `set_option linter.realHost false`
-/
#guard_msgs in
/-- A bad declaration: its adapter and its reason are empty. -/
def wiringSet.ModelTest.Lint.RealHost.Declaration : Editor.WiringSet :=
  .wiring "" ""

/--
error: `wiringSet.ModelTest.Lint.RealHost.Elsewhere` names a module's wiring set and is not this module's: a module declares itself as `def wiringSet.ModelTest.Lint.RealHost.Declaration : Editor.WiringSet`

Note: This linter can be disabled with `set_option linter.realHost false`
-/
#guard_msgs in
/-- A bad declaration: it names a module that is not this one. -/
def wiringSet.ModelTest.Lint.RealHost.Elsewhere : Editor.WiringSet :=
  .wiring "a stand-in for a real host" "a fixture of the declaration's name"

/-- The mark of `realLoop`, before it. -/
def ModelTest.RealHostDeclarationFixture.realLoop.realHost : Editor.RealHost :=
  .loop

/-- A stand-in for a real host, marked. -/
def ModelTest.RealHostDeclarationFixture.realLoop : IO Unit :=
  pure ()

/--
error: `ModelTest.RealHostDeclarationFixture.realLoop`, in `ModelTest.RealHostDeclarationFixture.loopCheck`, runs a real editor loop thread (loop): a check runs one only in a module of the wiring set: declare `def wiringSet.ModelTest.Lint.RealHost.Declaration : Editor.WiringSet := .wiring "…" "…"` in a module that wires the adapter, or run the check on the stepped host and the fakes (AGENTS.md, "Deterministic concurrency in tests")

Note: This linter can be disabled with `set_option linter.realHost false`
-/
#guard_msgs in
/-- A bad declaration: a check over a real host in a module whose own
declaration the linter cannot read, refused as in one that declares
nothing. -/
def ModelTest.RealHostDeclarationFixture.loopCheck : ModelTest.Check :=
  { name := "a check over a real loop thread",
    run := do
      ModelTest.RealHostDeclarationFixture.realLoop
      return true }
