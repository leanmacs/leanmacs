/-!
# FFI tests: `Lint/Wait.lean`

A wait linters' fixture in the library of the `ffi-test` executable
(`FfiTests`): a raw sleep wrapped in `#guard_msgs`, which expects
`linter.rawClock`'s error, so a build of this module shows that the build
loads the linters into this library too (`lintPlugin`, `lean/lakefile.lean`).
It holds no check. That every library and executable loads them is the lint
plugins check's (`tools/lint-plugins-check.sh`); what the linters refuse is
shown by the model tests' fixtures (`ModelTest/Lint/Wait.lean`).
-/

/--
error: `IO.sleep` reads the clock: a wait takes a `HangGuard`, real time under test is `RealTime.sleep` (`Editor/Bound.lean`), and a measurement of real time says so with `set_option linter.rawClock false in` and its reason

Note: This linter can be disabled with `set_option linter.rawClock false`
-/
#guard_msgs in
/-- A bad declaration: a raw sleep. -/
def FfiTest.LintFixture.sleeps : IO Unit :=
  IO.sleep 10
