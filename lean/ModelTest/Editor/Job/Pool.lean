import Editor.Job.Pool
import Editor.Test.Jobs
import ModelTest.Check

/-!
# Model tests: `Editor/Job/Pool.lean`

The model tests of `Editor/Job/Pool.lean`: `poolChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- Whether `threads` are all different, and are exactly the threads of
`others`. -/
def sameThreads (threads others : Array UInt64) : Bool :=
  distinct threads == threads.size && threads.size == others.size && threads.all others.contains

/-- The threads `Pool.holdAll` held for `Pool.expected` tasks, or a hang
thrown past `patience`, a hang guard: only a pool with fewer threads than
expected reaches it. -/
def heldAll : IO (Array UInt64) := do
  let expected ← Job.Pool.expected
  let some threads ←
    Job.Pool.holdAll expected
        patience | throw <| IO.userError s!"a hang: {expected} pool tasks had not all started within {patience.ms} ms"
  return threads

/-- The checks of warming the pool (`Editor/Job/Pool.lean`). They are about
the process's one pool, so they run first, while nothing else has used it.

They take the pool's size as Lean's runtime does (`Pool.expected`:
`LEAN_NUM_THREADS` when it is set, else the machine's), and pin what this
module promises: `holdAll` holds that many tasks at once, on that many
threads, each start an event it waits for. That a task more than the pool
has threads does not start is Lean's rule, not this module's, and could only
be shown by a window, so no check pins it. -/
def poolChecks : List Check :=
  [{  name :=
        "holding the pool's expected size of tasks holds them all at once, on as many different threads"
      run := do
        let threads ← heldAll
        return threads.size == (← Job.Pool.expected) && distinct threads == threads.size },
    { name :=
        "a second hold of the pool's expected size holds the same threads: the threads exist before the burst, which is what warming is for"
      run := do
        let first ← heldAll
        let second ← heldAll
        return !first.isEmpty && sameThreads second first },
    { name :=
        "a burst after warming starts no thread: warmed to its expected size, the pool's expected size of tasks, all running at once, are on the threads the warming held"
      run := do
        -- Warmed to the expected size, every task starts: the bound is a
        -- hang guard, never the warming's stop.
        let warmed ← Job.Pool.warm (← Job.Pool.expected) patience
        let burst ← heldAll
        return !warmed.isEmpty && sameThreads burst warmed }]

end ModelTest
