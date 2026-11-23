/-!
# The job runner's protocol

How the job runner (`Editor/Job/Runner.lean`) schedules many jobs, as a pure
transition system: each job's state and the runner's share of the host's
activity count, the transitions that move them, one atomic step each, and
an executable replay of a recorded trace. It is not `Editor/Job/Model.lean`,
which models one job's port; this is how the runner moves jobs through
their waits.

It imports nothing but `Init`, so the model tests, which must not reach
`Lean`, run it, and `Editor/Job/Runner.lean` decides each step it takes with
this module's own per-job step (`JobState.step`).

## The states

A job is spawned `queued`, and holds its unit of the host's activity from
there. It makes a request that waits by `ask`ing: the wait is registered and
handed to its service, and the job is `asking` until it records the wait as
its own, which a `park` (a wait only a test ends: the fake clock's sleep, a
fake watch's `next`) or a `serve` (any other wait) does. A parked job gives
its unit back in that same step, and a serving one keeps it. The wait's end
(`wake`) leaves the job `woken`, its continuation queued, and a parked job
takes a unit back in that step; the continuation's first step, `resume`,
leaves it `running`. A job ends `done`, giving its unit back.

Cancelling a job sets its token's flag (`JobState.cancelled`) and takes the
wait it recorded, which the canceller withdraws. A job cancelled while it is
`asking` has recorded nothing: it withdraws its own wait in its `park` or
`serve` step, and keeps its unit until it is `done`.

## The transitions

| Transition | Enabled when | Effect |
|---|---|---|
| `start j` | `j` is the next job, the loop has not ended | a `queued` job; a unit taken |
| `ask j w k` | `queued` or `running`, `w` a fresh wait | `asking w k`, not ended |
| `park j` | `asking w parks e` | not cancelled and not ended: `parked w`, recorded, a unit given; else `woken`, the wait withdrawn if it had not ended |
| `serve j` | `asking w service e` | as `park`, but `waiting w` in place of `parked w`, and nothing given |
| `wake w c` | `w` is in the table | an `asking` job's wait ended early; `waiting w` or `parked w` to `woken c`, a parked job taking a unit |
| `resume j` | `woken` | `running`, nothing recorded |
| `cancel j` | a job, the loop has not ended | cancelled, nothing recorded |
| `done j` | `queued` or `running` | `done`; a unit given |
| `loopEnd` | not ended, every cancelled job `done` | ended |

What is proved of it is `Editor/Job/Protocol/Theorems.lean`'s; how the runner
applies and records one transition per critical section is
`Editor/Job/Runner.lean`'s ("The protocol"); the checks that the runner's
recorded traces are runs of this model are
`Editor/Job/ProtocolContract.lean`'s.
-/

namespace Editor.Job

/-- How a wait ended. -/
inductive Completion where
  /-- The service completed it. -/
  | completed
  /-- It was withdrawn: the job that made it was cancelled. -/
  | cancelled
  deriving DecidableEq, Repr, Inhabited

namespace Protocol

/-- What a wait's end does to its job's unit: what `Answer.later`'s kind of
wait was. -/
inductive Kind where
  /-- A wait only a test ends: the job gives its unit back once the wait is
  recorded, and its end takes one back. -/
  | parks
  /-- A wait on a service that ends it by itself: the job keeps its unit. -/
  | service
  deriving DecidableEq, Repr, Inhabited

/-- Where a job is. -/
inductive Status where
  /-- Spawned, its unit held, no wait asked yet. -/
  | queued
  /-- On its thread again after a wait, its unit held. -/
  | running
  /-- Its wait `wait` registered and handed to its service, not yet recorded
  as its own; `ended` is how the wait ended, if it already has. Its unit is
  held. -/
  | asking (wait : Nat) (kind : Kind) (ended : Option Completion)
  /-- In the service wait `wait`, recorded, its unit kept. -/
  | waiting (wait : Nat)
  /-- In the parking wait `wait`, recorded, its unit given back. -/
  | parked (wait : Nat)
  /-- Its wait has ended as `completion` and its continuation is queued; its
  unit is held. -/
  | woken (completion : Completion)
  /-- Ended, its unit given back. -/
  | done
  deriving DecidableEq, Repr, Inhabited

/-- One job, as its token holds it. -/
structure JobState where
  /-- Where the job is. -/
  status : Status := .queued
  /-- Whether the job has been cancelled: the token's flag. -/
  cancelled : Bool := false
  /-- The wait the job has recorded as its own, which a cancel withdraws. -/
  recorded : Option Nat := none
  deriving DecidableEq, Repr, Inhabited

/-- The runner's jobs, its share of the activity count, the next fresh wait
and whether the loop has ended. -/
structure State where
  /-- Each job, by its number. -/
  jobs : List JobState := []
  /-- The runner's share of the host's activity count. -/
  count : Nat := 0
  /-- The least wait id not yet asked. -/
  nextWait : Nat := 0
  /-- Whether the loop has ended (`loopEnd`). -/
  ended : Bool := false
  deriving DecidableEq, Repr, Inhabited

/-- One atomic step of the protocol. -/
inductive Transition where
  /-- The job `job` is spawned. -/
  | start (job : Nat)
  /-- The job `job` registers the wait `wait` of kind `kind` and hands it to
  its service. -/
  | ask (job : Nat) (wait : Nat) (kind : Kind)
  /-- The job `job` records its parking wait: park-with-wait. -/
  | park (job : Nat)
  /-- The job `job` records its service wait: wait-on-service. -/
  | serve (job : Nat)
  /-- The wait `wait` ends as `completion`. -/
  | wake (wait : Nat) (completion : Completion)
  /-- The continuation of the job `job`, woken, runs. -/
  | resume (job : Nat)
  /-- The job `job` is cancelled. -/
  | cancel (job : Nat)
  /-- The job `job` ends. -/
  | done (job : Nat)
  /-- The loop ends, once every job it cancelled is done. -/
  | loopEnd
  deriving DecidableEq, Repr, Inhabited

/-- What one step does to the activity count. -/
inductive Move where
  /-- Nothing. -/
  | keep
  /-- A unit taken. -/
  | take
  /-- A unit given back. -/
  | give
  deriving DecidableEq, Repr, Inhabited

/-- The count `count` after the move. -/
def Move.apply : Move → Nat → Nat
  | .keep, count => count
  | .take, count => count + 1
  | .give, count => count - 1

/-- Whether a job in this status holds its unit. -/
def Status.holds : Status → Bool
  | .queued | .running | .asking .. | .waiting _ | .woken _ => true
  | .parked _ | .done => false

/-- The wait a job in this status has in the table of waits: one asked or
recorded and not yet ended. -/
def Status.carries : Status → Option Nat
  | .asking wait _ none => some wait
  | .waiting wait => some wait
  | .parked wait => some wait
  | _ => none

/-- Whether a job in this status may have recorded nothing and still be
reached by a cancel: it is on its thread, and sees the token there. -/
def Status.onThread : Status → Bool
  | .queued | .running | .asking .. => true
  | _ => false

/-- Whether the job holds its unit. -/
def JobState.holds (job : JobState) : Bool :=
  job.status.holds

/-- The job's step into the wait it asked, of kind `kind`: `park` or
`serve`. A job not cancelled records the wait; one whose wait has not ended
is in it, and gives its unit back if the wait parks. A cancelled job
withdraws a wait that has not ended, in this step, and is woken as
cancelled; it keeps its unit. -/
def JobState.enter (job : JobState) (kind : Kind) : Option (JobState × Move) :=
  match job.status with
  | .asking wait asked ended =>
    if asked != kind then none
    else
      match job.cancelled, ended with
      | false, none =>
        match kind with
        | .parks =>
          some
            ({ job with
                status := .parked wait, recorded := some wait },
              .give)
        | .service =>
          some
            ({ job with
                status := .waiting wait, recorded := some wait },
              .keep)
      | false, some completion =>
        some
          ({ job with
              status := .woken completion, recorded := some wait },
            .keep)
      | true, none => some ({ job with status := .woken .cancelled }, .keep)
      | true, some completion => some ({ job with status := .woken completion }, .keep)
  | _ => none

/-- The end of the wait `wait` as `completion`, for the job that carries
it. -/
def JobState.wake (job : JobState) (wait : Nat) (completion : Completion) :
    Option (JobState × Move) :=
  match job.status with
  | .asking carried kind none =>
    if carried == wait then
      some ({ job with status := .asking carried kind (some completion) }, .keep)
    else none
  | .waiting carried =>
    if carried == wait then some ({ job with status := .woken completion }, .keep) else none
  | .parked carried =>
    if carried == wait then some ({ job with status := .woken completion }, .take) else none
  | _ => none

/-- One job's part of a transition: its new state and what the step does to
the count, or `none` where the transition is not enabled for it. `start`
and `loopEnd` are not a job's (`State.step`). The runner decides each step it
takes with this function (`Editor/Job/Runner.lean`). -/
def JobState.step (job : JobState) : Transition → Option (JobState × Move)
  | .start _ => none
  | .ask _ wait kind =>
    match job.status with
    | .queued | .running => some ({ job with status := .asking wait kind none }, .keep)
    | _ => none
  | .park _ => job.enter .parks
  | .serve _ => job.enter .service
  | .wake wait completion => job.wake wait completion
  | .resume _ =>
    match job.status with
    | .woken _ =>
      some
        ({ job with
            status := .running, recorded := none },
          .keep)
    | _ => none
  | .cancel _ =>
    some
      ({ job with
          cancelled := true, recorded := none },
        .keep)
  | .done _ =>
    match job.status with
    | .queued | .running => some ({ job with status := .done }, .give)
    | _ => none
  | .loopEnd => none

/-- A spawned job, as `start` makes it, and the unit it takes. -/
def JobState.started : JobState × Move :=
  ({}, .take)

/-- The job `index`, or a fresh one past the last. -/
def State.job (state : State) (index : Nat) : JobState :=
  state.jobs[index]?.getD {}

/-- The waits in the table: asked or recorded, not yet ended. -/
def State.table (state : State) : List Nat :=
  state.jobs.filterMap (·.status.carries)

/-- The jobs whose continuation is queued: the queued wake-ups. -/
def State.wakeUps (state : State) : List Nat :=
  (List.range state.jobs.length).filter fun index =>
    match (state.job index).status with
    | .woken _ => true
    | _ => false

/-- The job that carries the wait `wait`, if one does. -/
def State.carrier (state : State) (wait : Nat) : Option Nat :=
  state.jobs.findIdx? (·.status.carries == some wait)

/-- The transition `transition` applied to the job `index`: its part
(`JobState.step`), and the count moved by it. -/
def State.applyAt (state : State) (index : Nat) (transition : Transition) : Option State :=
  match state.jobs[index]? with
  | none => none
  | some job =>
    match job.step transition with
    | none => none
    | some (after, move) =>
      some
        { state with
          jobs := state.jobs.set index after, count := move.apply state.count }

/-- Whether every cancelled job is done. -/
def State.cancelledDone (state : State) : Bool :=
  state.jobs.all fun job => !job.cancelled || job.status == .done

/-- One step of the whole state, or `none` where `transition` is not
enabled. -/
def State.step (state : State) : Transition → Option State
  | .start index =>
    if index == state.jobs.length && !state.ended then
      some
        { state with
          jobs := state.jobs ++ [JobState.started.1], count := state.count + 1 }
    else none
  | .ask index wait kind =>
    if state.nextWait ≤ wait then
      (state.applyAt index (.ask index wait kind)).map ({ · with nextWait := wait + 1 })
    else none
  | .park index => state.applyAt index (.park index)
  | .serve index => state.applyAt index (.serve index)
  | .wake wait completion =>
    match state.carrier wait with
    | some index => state.applyAt index (.wake wait completion)
    | none => none
  | .resume index => state.applyAt index (.resume index)
  | .cancel index => if state.ended then none else state.applyAt index (.cancel index)
  | .done index => state.applyAt index (.done index)
  | .loopEnd =>
    if !state.ended && state.cancelledDone then some { state with ended := true } else none

/-- The state `transitions` reach from the initial state, one step each, or
`none` if one is not enabled where it comes. -/
def run (transitions : List Transition) : Option State :=
  transitions.foldlM (fun state transition => state.step transition) {}

/-- An invariant the checker looks at (`State.violation?`), each one of the
theorems of `Editor/Job/Protocol/Theorems.lean`. -/
inductive Invariant where
  /-- A cancel finds its job on its thread or its wait recorded
  (`cancel_finds_running_or_recorded`). -/
  | cancelFindsRunningOrRecorded
  /-- The count is 0 exactly when no job holds a unit
  (`count_zero_iff_none_holds`). -/
  | countZeroIffNoneHolds
  /-- After loop-end every cancelled job is done
  (`loopEnd_settles_cancelled`). -/
  | loopEndSettlesCancelled
  deriving DecidableEq, Repr, Inhabited

/-- Whether a cancel of `job` would find it on its thread or its wait
recorded, when it is not cancelled and not done. -/
def JobState.reachable (job : JobState) : Bool :=
  job.cancelled || job.status == .done || job.status.onThread || job.recorded.isSome

/-- The first invariant `state` breaks, or `none`: the decidable checker of
`cancel_finds_running_or_recorded`, `count_zero_iff_none_holds` and
`loopEnd_settles_cancelled` over one state. `checker_agrees` proves it
finds nothing in a reachable state. -/
def State.violation? (state : State) : Option Invariant :=
  if !state.jobs.all (·.reachable) then some .cancelFindsRunningOrRecorded
  else
    if (state.count == 0) != state.jobs.all (!·.holds) then some .countZeroIffNoneHolds
    else if state.ended && !state.cancelledDone then some .loopEndSettlesCancelled else none

/-- Where a replay was refused: the index of the transition in the trace,
the transition as the model numbers its job, and the state it was refused
in. -/
structure Refusal where
  /-- The index of the refused transition in the trace. -/
  index : Nat
  /-- The refused transition, its job renumbered. -/
  transition : Transition
  /-- The state it was refused in. -/
  state : State
  deriving Repr

/-- The refusal as text, for a check's failure and a stress find. -/
def Refusal.text (refusal : Refusal) : String :=
  s!"the protocol refuses transition {refusal.index}, {repr refusal.transition}, in {repr refusal.state}"

/-- The job a transition names, if it names one. -/
def Transition.job? : Transition → Option Nat
  | .start job | .ask job .. | .park job | .serve job | .resume job | .cancel job | .done job =>
    some job
  | .wake .. | .loopEnd => none

/-- The transition with its job `job` in place of the one it names. -/
def Transition.withJob (transition : Transition) (job : Nat) : Transition :=
  match transition with
  | .start _ => .start job
  | .ask _ wait kind => .ask job wait kind
  | .park _ => .park job
  | .serve _ => .serve job
  | .resume _ => .resume job
  | .cancel _ => .cancel job
  | .done _ => .done job
  | other => other

/-- Replays a recorded trace: each job's number is renamed to its place in
the order of the trace's `start`s, since several hosts may share one table
and its numbering, and the trace is then run on the model from its initial
state. The state it reaches, or where the model refused it. -/
def replay (trace : Array Transition) : Except Refusal State := do
  let (state, _) ←
    trace.size.foldM
        (fun index _ (acc : State × List (Nat × Nat)) => do
          let (state, names) := acc
          let recorded := trace[index]
          let (transition, names) :=
            match recorded with
            | .start number =>
              (Transition.start state.jobs.length, (number, state.jobs.length) :: names)
            | other =>
              match other.job? with
              | none => (other, names)
              | some number =>
                -- A job the trace never started is past every job, so the
                -- model refuses it.
                (other.withJob ((names.lookup number).getD (state.jobs.length + number + 1)), names)
          match state.step transition with
          | some after =>
            pure (after, names)
          | none =>
            throw { index, transition, state })
        ({}, [])
  return state

end Protocol

end Editor.Job
