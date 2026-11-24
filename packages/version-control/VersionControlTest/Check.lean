/-!
# The tests of `version-control`: the check

The type of one test, `Check`, and `failures`, which runs a list of them.
Every test module of the package that writes a check imports this one. It
needs nothing of the editor.
-/

namespace VersionControlTest

/-- One behaviour, and how to observe it. -/
structure Check where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the behaviour; `true` when it holds. -/
  run : IO Bool

/-- How a check ends that says what it saw when it fails: `true` when `holds`,
and otherwise it throws `observed`, which `failures` reports after the
check's name, as `(saw <observed>)`. -/
def saw (holds : Bool) (observed : String) : IO Bool := do
  unless holds do
    throw (IO.userError s!"saw {observed}")
  return true

/-- Runs `checks` and returns the names of those that failed. A check that
throws has failed, and its error is reported with its name. -/
def failures (checks : List Check) : IO (List String) :=
  checks.filterMapM fun check => do
    try
      return if ← check.run then none else some check.name
    catch error =>
      return some s!"{check.name} ({error})"

end VersionControlTest
