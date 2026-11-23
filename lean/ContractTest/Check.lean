import Editor.Lint.Wait

/-!
# Contract tests: the check

The type of one check of a real binding, `Check`, and `checkFailures`, which
runs a list of them. Every test module that writes a check imports this one (the
root module `ContractTest` describes the layout). This module needs nothing of
the editor but the wait linters (`Editor/Lint/Wait.lean`), which it
imports so that every test module that writes a check is linted.
-/

namespace ContractTest

/-- One behaviour, and how to observe it. -/
structure Check where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the behaviour; `true` when it holds. -/
  run : IO Bool

/-- Runs `checks` and returns the names of those that failed. A check that
throws has failed, and its error is reported with its name. -/
def checkFailures (checks : List Check) : IO (List String) :=
  checks.filterMapM fun check => do
    try
      return if ← check.run then none else some check.name
    catch error =>
      return some s!"{check.name} ({error})"

end ContractTest
