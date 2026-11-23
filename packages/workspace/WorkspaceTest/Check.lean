import Editor.Lint.Wait

/-!
# The tests of `workspace`: the check

The type of one test, `Check`, and `failures`, which runs a list of them.
Every test module of the package that writes a check imports this one. It
needs nothing of the editor but the wait linters (`Editor/Lint/Wait.lean`), which it
imports so that every test module that writes a check is linted.
-/

namespace WorkspaceTest

/-- One behaviour, and how to observe it. -/
structure Check where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the behaviour; `true` when it holds. -/
  run : IO Bool

/-- Runs `checks` and returns the names of those that failed. A check that
throws has failed, and its error is reported with its name. -/
def failures (checks : List Check) : IO (List String) :=
  checks.filterMapM fun check => do
    try
      return if ← check.run then none else some check.name
    catch error =>
      return some s!"{check.name} ({error})"

end WorkspaceTest
