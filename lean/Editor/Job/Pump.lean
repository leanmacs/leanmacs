import Editor.Job.Runner

/-!
# The completion pump's port

What the completion pump pulls (`CompletionSource`), and the pump itself
over a source (`pumpFrom`): it pulls the source and ends the wait each
completion names, in the order pulled, until the source says quit. The
library's source is `Job.librarySource` (`Editor/Job/Real.lean`), the
library's completion queue, and `Job.pump` is `pumpFrom` over it, which a
host runs on a dedicated task. The fake is `Job.FakePump`
(`Editor/Job/Fake.lean`): the stepped fakes of the job services hand it
their completions, as the real services hand theirs to the library's queue,
and a check steps it on its own thread, or runs `pumpFrom` over its source
there.

The contract both keep is `Editor/Job/PumpContract.lean`, run over the fake
by `model-test` (`ModelTest.pumpContractChecks`) and over the library's
queue by `contract-test` (`ContractTest.pumpContractChecks`).

## Where an addition goes

A new kind of event the pump must tell apart is a constructor of `Pulled`,
which each source maps to; what the pump does with it is `pumpFrom`'s, here,
and pinned by the contract. This module imports the runner's table alone:
no `Ffi`.
-/

namespace Editor.Job

/-- What a pull of the completion source gave. -/
inductive Pulled where
  /-- The wait `id` is completed. -/
  | completion (id : UInt64)
  /-- The queues are quit: the pump ends. -/
  | quit
  /-- Anything else, which the pump passes over. -/
  | other
  deriving DecidableEq, Repr

/-- Where the completion pump pulls from. -/
structure CompletionSource where
  /-- Blocks until the next event, and gives it. -/
  next : IO Pulled

/-- The completion pump over `source`: pulls it and ends the wait each
completion names, as completed, in the order pulled, until it says quit. It
blocks in `next`: over the library's source, run it on a dedicated task. -/
partial def pumpFrom (source : CompletionSource) (completions : Completions) : IO Unit := do
  match ← source.next with
  | .quit =>
    pure ()
  | .completion id =>
    completions.finish id .completed
    pumpFrom source completions
  | .other =>
    pumpFrom source completions

end Editor.Job
