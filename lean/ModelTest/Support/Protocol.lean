import Editor.Job.Protocol

/-!
# Model tests: support: Protocol

The job runner's protocol as it was before the runner-park fix (784962e3),
reconstructed as a step over the model's own state (`PreFix.step`): a job
parking gave its unit back before it recorded its wait. Its two users are
the model tests of the protocol (`ModelTest/Editor/Job/Protocol.lean`), whose
search finds the counterexample in it, and those of the protocol contract
(`ModelTest/Editor/Job/ProtocolContract.lean`), whose park check fails on
it.

It is a reconstruction, not a switch in the runner: a seam that let a caller
split the park would be the very split the runner now cannot make, and a copy
of the old `drive` in test code would drift. Each step is the old runner's
(the parent of 784962e3, `Job.drive`): it gave a parking job's unit back
(`activity.done`) before it set the token's wait, and once it set it, a job
cancelled in between withdrew its own wait, whose end took a unit back. The
steps allow a subset of the old runner's interleavings, which is enough: a
counterexample in a subset is one of the old runner.
-/

namespace ModelTest

open Editor.Job
open Editor.Job.Protocol

/-- A step of the pre-fix protocol. -/
inductive PreFix.Transition where
  /-- A step of the protocol, but `park`, which the pre-fix runner split. -/
  | of (transition : Protocol.Transition)
  /-- The job `job`, asking a parking wait, gives its unit back, its wait
  not yet recorded: the first half of the old park. -/
  | giveBack (job : Nat)
  /-- The job `job`, parked, records its wait, or withdraws it if it was
  cancelled in between: the second half of the old park. -/
  | record (job : Nat)
  deriving DecidableEq, Repr, Inhabited

/-- One step of the pre-fix protocol over the model's state, or `none` where
it is not enabled. -/
def PreFix.step (state : State) : PreFix.Transition → Option State
  | .of (.park _) => none
  | .of transition => state.step transition
  | .giveBack index =>
    match state.jobs[index]? with
    | some { status := .asking wait .parks none, cancelled := false, recorded } =>
      some
        { state with
          jobs := state.jobs.set index { status := .parked wait, cancelled := false, recorded }
          count := state.count - 1 }
    | _ => none
  | .record index =>
    match state.jobs[index]? with
    | some { status := .parked wait, cancelled, recorded := none } =>
      if cancelled then
        -- The job withdraws its own wait, whose end takes a unit back.
        some
          { state with
            jobs :=
              state.jobs.set index { status := .woken .cancelled, cancelled, recorded := none }
            count := state.count + 1 }
      else
        some
          { state with
            jobs :=
              state.jobs.set index { status := .parked wait, cancelled, recorded := some wait } }
    | _ => none

end ModelTest
