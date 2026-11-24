import ModelTest.Lint.Wait

/-!
# Model tests: `Lint/Wait.lean`, a module beside a mirror that declares nothing

The wait linter's fixture of a module named as one of the wiring set beside
the mirror of its target, `<Root>.<target>.Real`, that declares no
`wiringSet.<module>`: it is no mirror of `Lint.Wait.Unwired`, a subject of
`besideCount`'s mark (`ModelTest/Lint/Wait.lean`), so its reference to that
wait is refused. Its name alone says nothing.
-/

/--
error: `ModelTest.LintFixture.besideCount`, in `ModelTest.LintBesideFixture.unwiredRead`, is an inferred wait (count): it infers done from something shared, not from a signal for this work. It is allowed only in ModelTest.Lint.Wait, Lint.Wait.Wired, Lint.Wait.Unwired and the test modules that mirror them; wait on the work's own handle, promise or flush, or, for a site a later phase removes, `set_option linter.inferredWait false in` with its row of docs/dev-practices/inferred-waits.md

Note: This linter can be disabled with `set_option linter.inferredWait false`
-/
#guard_msgs in
/-- A bad declaration: a reference to its target's inferred wait from a
module that declares no wiring set. -/
def ModelTest.LintBesideFixture.unwiredRead : BaseIO Bool :=
  return (← ModelTest.LintFixture.besideCount) == 0
