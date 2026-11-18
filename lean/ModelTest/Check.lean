/-!
# Model tests: the check

The type of one model test, `Check`, and `failures`, which runs a list of
them. Every module of the model tests (`ModelTest/*.lean`) imports this one,
through the chain of imports the root module `ModelTest` describes. This
module needs nothing of the editor.
-/

namespace ModelTest

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

end ModelTest
