import Editor.Job.Pool
import ModelTest.Check
import ModelTest.Support.Jobs

/-!
# Model tests: `Editor/Job/Pool.lean`

The model tests of `Editor/Job/Pool.lean`: `poolChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- Whether `threads` are all different, and are exactly the threads of
`others`. -/
def sameThreads (threads others : Array UInt64) : Bool :=
  distinct threads == threads.size && threads.size == others.size && threads.all others.contains

/-- The checks of warming the pool (`Editor/Job/Pool.lean`). They are about
the process's one pool, so they run first, while nothing else has used it.

None of them knows how many threads the pool has: that number is Lean's, and
`LEAN_NUM_THREADS` changes it. Each learns the pool's threads from a warming
that stopped short of its limit (`Pool.whole`), and states what must hold
relative to that. -/
def poolChecks : List Check :=
  [{
      name :=
        "warming the pool holds one task on every thread it has, at once: the threads are all different, and a task more than the pool has threads does not start",
      run := do
        let threads ← Job.Pool.whole warmPatience
        return !threads.isEmpty && distinct threads == threads.size },
    { name :=
        "warming stops at the pool's size, and a second warming adds no thread: asked for two threads more than the pool was seen to have, it holds the same threads"
      run := do
        let first ← Job.Pool.whole warmPatience
        let second ← Job.Pool.warm (first.size + 2) warmPatience
        return !first.isEmpty && sameThreads second first },
    { name :=
        "a burst after warming starts no thread: a task for each thread of the pool, all running at once, are on the threads the warming held"
      run := do
        let warmed ← Job.Pool.whole warmPatience
        let release : IO.Promise Unit ← IO.Promise.new
        let running ← IO.mkRef #[]
        try
          for _ in [0:warmed.size] do
            discard <|
                IO.asTask do
                  running.modify (·.push (← IO.getTID))
                  -- Holds its thread in a system call, which Lean does not
                  -- count as blocked, so no thread is added for it.
                  while !(← release.isResolved) do
                    IO.sleep 1
          let together ← eventually (return (← running.get).size == warmed.size)
          return !warmed.isEmpty && together && sameThreads (← running.get) warmed
        finally
          release.resolve () }]

end ModelTest
