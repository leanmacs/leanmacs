import Editor.RealHost
import ModelTest.Check
import ModelTest.Lint.Wiring.Contract
import ModelTest.Lint.Wiring.Edge
import ModelTest.Lint.Wiring.Stepped
import ModelTest.Lint.Wiring.Wired

/-!
# Model tests: `Lint/Wiring.lean`

The wiring-set linter's `#guard_msgs` fixtures of check sets, over the
modules under `ModelTest/Lint/Wiring/`: `Wired` (`.wiring`), `Contract`
(`.contract`), `Edge` (`.edge`) and `Stepped` (none). A check set that
passes every rule, with two groups of one module, and one refusal each of
rules (t), (a) and (u); rule (b) is `Wired`'s. Each bad declaration is
wrapped in `#guard_msgs`, which expects the lint's error, so a build of
this module shows that the linter refuses it.

The `main` here is not refused, though it runs `Wired`'s checks outside a
check set and selects by no wiring mode: rules (c) and (d) hold only a root
that links the library, and model-test links none, so its `.wiring`
declarations are fixtures alone. Their refusals are the fixture package
`greeting`'s (`GreetingTest/Linked/Lint/Wiring.lean`), under a root that
links it. This module imports nothing of the linter: the build loads it as
a Lean plugin. The linter's checks are `LintTest.lintWiringChecks`
(`LintTest/Lint/Wiring.lean`).
-/

namespace ModelTest.WiringFixture

open Editor

/-- A check set that passes every rule: the stepped and the edge's checks in
plain groups, `Wired`'s two lists in two groups of its own with a plain one
between them, and `Contract`'s in its group. -/
def passing : List (CheckGroup Unit Check) :=
  [.plain fun _ => steppedChecks,
    .wired "ModelTest.Lint.Wiring.Wired" wiringSet.ModelTest.Lint.Wiring.Wired fun _ => wiredChecks,
    .plain fun _ => edgeChecks,
    .wired "ModelTest.Lint.Wiring.Wired" wiringSet.ModelTest.Lint.Wiring.Wired fun _ =>
      wiredLater 2,
    .wired "ModelTest.Lint.Wiring.Contract" wiringSet.ModelTest.Lint.Wiring.Contract fun _ =>
      contractChecks]

/-! (t) A list of the wiring set in a plain group, which then no wired group
reaches (a). -/

/--
error: `ModelTest.WiringFixture.wiredLater` is a check of `ModelTest.Lint.Wiring.Wired`, a module of the wiring set, in a plain group of `ModelTest.WiringFixture.inPlain`: put it in `.wired "ModelTest.Lint.Wiring.Wired" wiringSet.ModelTest.Lint.Wiring.Wired fun … => …`

Note: This linter can be disabled with `set_option linter.wiringSet false`
---
error: `ModelTest.WiringFixture.inPlain` leaves out `ModelTest.WiringFixture.wiredLater`, a check of `ModelTest.Lint.Wiring.Wired`, a module of the wiring set: run it from a group `.wired "ModelTest.Lint.Wiring.Wired" wiringSet.ModelTest.Lint.Wiring.Wired fun … => …`

Note: This linter can be disabled with `set_option linter.wiringSet false`
-/
#guard_msgs in
/-- A bad check set: `Wired`'s later list in a plain group. -/
def inPlain : List (CheckGroup Unit Check) :=
  [.plain fun _ => steppedChecks ++ wiredLater 1,
    .wired "ModelTest.Lint.Wiring.Wired" wiringSet.ModelTest.Lint.Wiring.Wired fun _ => wiredChecks,
    .wired "ModelTest.Lint.Wiring.Contract" wiringSet.ModelTest.Lint.Wiring.Contract fun _ =>
      contractChecks]

/-! (t) A group tagged with another module's declaration. -/

/--
error: the wired group "ModelTest.Lint.Wiring.Wired" of `ModelTest.WiringFixture.mistagged` is tagged with something other than `wiringSet.ModelTest.Lint.Wiring.Wired`, the declaration of the module `ModelTest.Lint.Wiring.Wired`: tag it with that constant

Note: This linter can be disabled with `set_option linter.wiringSet false`
-/
#guard_msgs in
/-- A bad check set: `Wired`'s group tagged with `Contract`'s declaration. -/
def mistagged : List (CheckGroup Unit Check) :=
  [.wired "ModelTest.Lint.Wiring.Wired" wiringSet.ModelTest.Lint.Wiring.Contract fun _ =>
      wiredChecks ++ wiredLater 1,
    .wired "ModelTest.Lint.Wiring.Contract" wiringSet.ModelTest.Lint.Wiring.Contract fun _ =>
      contractChecks]

/-! (t) A group that holds another module's list. -/

/--
error: `ModelTest.WiringFixture.contractChecks` is a check of `ModelTest.Lint.Wiring.Contract`, in the wired group "ModelTest.Lint.Wiring.Wired" of `ModelTest.WiringFixture.elsewhere`: a wired group holds only its own module's checks

Note: This linter can be disabled with `set_option linter.wiringSet false`
-/
#guard_msgs in
/-- A bad check set: `Contract`'s list in `Wired`'s group. -/
def elsewhere : List (CheckGroup Unit Check) :=
  [.wired "ModelTest.Lint.Wiring.Wired" wiringSet.ModelTest.Lint.Wiring.Wired fun _ =>
      wiredChecks ++ wiredLater 1 ++ contractChecks]

/-! (a) A list of the wiring set left out. -/

/--
error: `ModelTest.WiringFixture.leavesOut` leaves out `ModelTest.WiringFixture.contractChecks`, a check of `ModelTest.Lint.Wiring.Contract`, a module of the wiring set: run it from a group `.wired "ModelTest.Lint.Wiring.Contract" wiringSet.ModelTest.Lint.Wiring.Contract fun … => …`

Note: This linter can be disabled with `set_option linter.wiringSet false`
-/
#guard_msgs in
/-- A bad check set: it leaves `Contract`'s list out. -/
def leavesOut : List (CheckGroup Unit Check) :=
  [.wired "ModelTest.Lint.Wiring.Wired" wiringSet.ModelTest.Lint.Wiring.Wired fun _ =>
      wiredChecks ++ wiredLater 1]

/-! (u) A list run twice. -/

/--
error: `ModelTest.WiringFixture.wiredChecks` is in `ModelTest.WiringFixture.twice` twice: a check set runs each check once

Note: This linter can be disabled with `set_option linter.wiringSet false`
-/
#guard_msgs in
/-- A bad check set: `Wired`'s first list in both of its groups. -/
def twice : List (CheckGroup Unit Check) :=
  [.wired "ModelTest.Lint.Wiring.Wired" wiringSet.ModelTest.Lint.Wiring.Wired fun _ =>
      wiredChecks ++ wiredLater 1,
    .wired "ModelTest.Lint.Wiring.Wired" wiringSet.ModelTest.Lint.Wiring.Wired fun _ => wiredChecks,
    .wired "ModelTest.Lint.Wiring.Contract" wiringSet.ModelTest.Lint.Wiring.Contract fun _ =>
      contractChecks]

/-! A root that links no library: its `main` may run a module of the wiring
set's checks with no check set, as model-test's fixtures are never run as
the wiring set. -/

#guard_msgs in
/-- Not refused: this module links no library. -/
def main : IO UInt32 := do
  let failed ← failures wiredChecks
  return if failed.isEmpty then 0 else 1

end ModelTest.WiringFixture
