import Editor.Job

/-!
# The contract of the job port

What every implementation of the job port (`Editor/Job.lean`) does, as one
list of properties. A property is a job that returns whether it held, so the
same list runs three ways:

- against the pure model (`Editor/Job/Model.lean`), by `model-test`;
- against the runner over the fake clock (`Editor/Job/Runner.lean`,
  `Editor/Job/Fake.lean`), by `model-test`;
- against the runner over the Rust library's timer service
  (`Editor/Job/Real.lean`), by `contract-test`.

That is what keeps the model, the fake clock and the library from drifting
apart.

Every property is an inequality. A real clock only promises "not before": a
wait may return late, and time passes between two requests. So nothing here
says a clock reads exactly some instant, and durations are 0 to 3 ms, so the
run against the real clock takes milliseconds. What needs equality (that a
timer does not drift) is checked against the model alone, where the clock is
exact (`ModelTest.jobModelChecks`).

This module imports only the port. The list is plain data, jobs that have
not run, so it is a constant: nothing in it calls the library when the module
is initialised.
-/

namespace Editor.JobContract

/-- One property of the job port: a job that observes it. -/
structure Property where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the property; `true` when it holds. A job that fails or is
  cancelled has not held. -/
  holds : JobM Bool

/-- The properties every implementation of the job port has. -/
def properties : List Property :=
  [{ name := "the clock does not go back across a wait",
     holds := do
       let before ← now
       sleep 1
       let between ← now
       waitUntil (between + 1)
       return before ≤ between && between ≤ (← now) },
    { name := "after a sleep the clock has moved by at least its duration, and a sleep of 0 returns"
      holds := do
        let before ← now
        sleep 3
        let after ← now
        sleep 0
        return before + 3 ≤ after && after ≤ (← now) },
    { name := "waitUntil an instant that has passed returns, and does not move the clock back"
      holds := do
        sleep 2
        let before ← now
        waitUntil 0
        waitUntil (before - 1)
        return before ≤ (← now) },
    { name := "after waitUntil the clock reads at least its deadline"
      holds := do
        let deadline := (← now) + 3
        waitUntil deadline
        return deadline ≤ (← now) },
    { name :=
        "a timer's third tick is not before its start plus three periods, with work between the ticks"
      holds := do
        let start ← now
        let timer ← Timer.every 2
        let timer ← timer.tick
        sleep 1
        let timer ← timer.tick
        sleep 1
        discard timer.tick
        return start + 6 ≤ (← now) },
    { name :=
        "a throw after a wait is caught by the job's own handler, with its message, and the job goes on to wait again"
      holds := do
        let caught ←
          try
            sleep 1
            throw "no thanks"
          catch message =>
            pure (message == "no thanks")
        sleep 1
        return caught }]

/-- Runs each of `properties` with `run` and returns the names of those that
did not hold. A property whose job failed or was cancelled has not held, and
is named with how it ended. -/
def failures (run : JobM Bool → IO (Job.Outcome Bool)) (properties : List Property) :
    IO (List String) :=
  properties.filterMapM fun property => do
    match ← run property.holds with
    | .finished true =>
      return none
    | .finished false =>
      return some property.name
    | .failed message =>
      return some s!"{property.name} (the job failed with `{message}`)"
    | .cancelled =>
      return some s!"{property.name} (the job was cancelled)"

end Editor.JobContract
