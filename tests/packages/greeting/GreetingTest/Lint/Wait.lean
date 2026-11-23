/-!
# Greeting tests: `Lint/Wait.lean`

A wait linters' fixture in a package's test library: a raw sleep wrapped
in `#guard_msgs`, which expects `linter.rawClock`'s error, so a build of
this module shows that the `plugins` line of a package's lakefile loads the
core's linters into its libraries, as `lintPlugin` loads them into the
core's (`lean/Lint/Wait.lean`). It holds no check. That every package's
libraries and executables load them is the lint plugins check's
(`tools/lint-plugins-check.sh`).
-/

/--
error: `IO.sleep` reads the clock: a wait takes a `HangGuard`, real time under test is `RealTime.sleep` (`Editor/Bound.lean`), and a measurement of real time says so with `set_option linter.rawClock false in` and its reason

Note: This linter can be disabled with `set_option linter.rawClock false`
-/
#guard_msgs in
/-- A bad declaration: a raw sleep. -/
def GreetingTest.LintFixture.sleeps : IO Unit :=
  IO.sleep 10
