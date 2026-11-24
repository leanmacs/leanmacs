import Editor.Test.Linked.Host

/-!
# Greeting tests: `Linked/Lint/RealHost.lean`

The real-host linter's fixture in a package's test library: a package
linked check that runs the linked kit's real host, outside the wiring set,
wrapped in `#guard_msgs`, which expects `linter.realHost`'s error, so a
build of this module shows that the `plugins` line of a package's lakefile
loads the core's real-host linter into its libraries. It is under the
linked root, `GreetingTest.Linked`, since only a package's linked test and
the modules under it may import the linked test kit. It holds no check.
-/

/--
error: `Editor.Test.Linked.withRealHost`, in `GreetingTest.LintFixture.realHostCheck`, runs a real editor loop thread (loop): a check runs one only in a module of the wiring set: declare `def wiringSet.GreetingTest.Linked.Lint.RealHost : Editor.WiringSet := .wiring "…" "…"` in a module that wires the adapter, or run the check on the stepped host and the fakes (AGENTS.md, "Deterministic concurrency in tests")

Note: This linter can be disabled with `set_option linter.realHost false`
-/
#guard_msgs in
/-- A bad declaration: a package linked check on a real host. -/
def GreetingTest.LintFixture.realHostCheck (context : Editor.Test.Linked.HostContext) : IO Bool :=
  Editor.Test.Linked.withRealHost context [] fun _ => pure true
