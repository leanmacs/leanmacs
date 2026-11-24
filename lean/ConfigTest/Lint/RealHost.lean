import ConfigTest.Check
import Editor.Headless
import Editor.Test.Linked.Host

/-!
# Config tests: `Lint/RealHost.lean`

The real-host linter's fixtures that need the host and the linked kit,
which only the config tests link: checks of a config test module that
declares no wiring set, each reaching a real host or a real service, and a
kit-style helper that hands one on unmarked, each wrapped in `#guard_msgs`,
which expects `linter.realHost`'s error. Building this module shows that
the linter refuses them; it holds no check. A stepped check beside them is
refused nothing. The launder, contract and edge rules are the model tests'
fixtures (`ModelTest/Lint/RealHost.lean` and the modules under
`ModelTest/Lint/RealHost/`).
-/

namespace ConfigTest.RealHostFixture

open Editor
open Editor.Test.Linked

/-- A config the fixtures' hosts load: nothing. -/
def files : List (String × String) :=
  []

/--
error: `Editor.Test.Linked.withRealHost`, in `ConfigTest.RealHostFixture.realHostCheck`, runs a real editor loop thread (loop): a check runs one only in a module of the wiring set: declare `def wiringSet.ConfigTest.Lint.RealHost : Editor.WiringSet := .wiring "…" "…"` in a module that wires the adapter, or run the check on the stepped host and the fakes (AGENTS.md, "Deterministic concurrency in tests")

Note: This linter can be disabled with `set_option linter.realHost false`
-/
#guard_msgs in
/-- A bad declaration: a check on the linked kit's real host. -/
def realHostCheck (context : HostContext) : ConfigTest.Check :=
  { name := "a check on a real host"
    run := withRealHost context files fun _ => pure true }

/--
error: `Editor.Headless.withHost`, in `ConfigTest.RealHostFixture.bracketCheck`, runs a real editor loop thread (loop): a check runs one only in a module of the wiring set: declare `def wiringSet.ConfigTest.Lint.RealHost : Editor.WiringSet := .wiring "…" "…"` in a module that wires the adapter, or run the check on the stepped host and the fakes (AGENTS.md, "Deterministic concurrency in tests")

Note: This linter can be disabled with `set_option linter.realHost false`
-/
#guard_msgs in
/-- A bad declaration: a check on the host's own bracket over a real loop thread. -/
def bracketCheck (context : HostContext) : ConfigTest.Check :=
  { name := "a check in a real host's bracket"
    run := do
      let stage ← Stage.new context context.elaborator (memorySource files)
      Headless.withHost stage.collaborators fun _ => pure true }

/--
error: `Editor.Test.Linked.Stage.overFiles`, in `ConfigTest.RealHostFixture.servicesCheck`, runs a real background service (service): a check runs one only in a module of the wiring set: declare `def wiringSet.ConfigTest.Lint.RealHost : Editor.WiringSet := .wiring "…" "…"` in a module that wires the adapter, or run the check on the stepped host and the fakes (AGENTS.md, "Deterministic concurrency in tests")

Note: This linter can be disabled with `set_option linter.realHost false`
-/
#guard_msgs in
/-- A bad declaration: a check over a stage on the library's services. -/
def servicesCheck (context : HostContext) : ConfigTest.Check :=
  { name := "a check over the library's services"
    run := do
      discard <| Stage.overFiles context (memorySource files)
      return true }

/-- A private helper that runs a real host: not refused where it is
written, and a reference to it is one to the real host. -/
private def onReal (context : HostContext) : IO Bool := do
  let stage ← Stage.new context context.elaborator (memorySource files)
  onRealStage stage fun _ _ => pure true

/--
error: `Editor.Test.Linked.onRealStage`, in `ConfigTest.RealHostFixture.privateCheck`, runs a real editor loop thread (loop), through `ConfigTest.RealHostFixture.onReal`: a check runs one only in a module of the wiring set: declare `def wiringSet.ConfigTest.Lint.RealHost : Editor.WiringSet := .wiring "…" "…"` in a module that wires the adapter, or run the check on the stepped host and the fakes (AGENTS.md, "Deterministic concurrency in tests")

Note: This linter can be disabled with `set_option linter.realHost false`
-/
#guard_msgs in
/-- A bad declaration: a check through a private helper of a real host. -/
def privateCheck (context : HostContext) : ConfigTest.Check :=
  { name := "a check through a private helper"
    run := onReal context }

/--
error: `Editor.Test.Linked.withRealHost`, in `ConfigTest.RealHostFixture.withRealKit`, runs a real editor loop thread (loop): a check runs one only in a module of the wiring set: declare `def wiringSet.ConfigTest.Lint.RealHost : Editor.WiringSet := .wiring "…" "…"` in a module that wires the adapter, or run the check on the stepped host and the fakes (AGENTS.md, "Deterministic concurrency in tests")

Note: This linter can be disabled with `set_option linter.realHost false`
-/
#guard_msgs in
/-- A bad declaration: a public kit-style helper that hands the real host on,
unmarked. -/
def withRealKit (context : HostContext) (check : RealSession → IO Bool) : IO Bool :=
  withRealHost context files check

/-- A stepped check: refused nothing. -/
def steppedCheck (context : HostContext) : ConfigTest.Check :=
  { name := "a check on a stepped host"
    run := withHost context files fun _ => pure true }

end ConfigTest.RealHostFixture
