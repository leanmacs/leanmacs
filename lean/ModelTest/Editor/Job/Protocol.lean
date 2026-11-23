import Editor.Job.Protocol
import ModelTest.Check

/-!
# Model tests: `Editor/Job/Protocol.lean`

The model tests of the job runner's protocol (`Editor/Job/Protocol.lean`):
`protocolChecks`, and the bounded search they run the checker with
(`search`). The root module `ModelTest` runs them; its module doc says what
each shows. Every check is pure.
-/

namespace ModelTest

open Editor.Job
open Editor.Job.Protocol

/-- A shortest trace of at most `depth` steps from `start` to a state `bad`
says breaks an invariant, and the invariant: an iterative-deepening search,
each round a depth-first walk of the steps `enabled` names that `step`
takes. `none` if no state within `depth` steps breaks one. -/
def search {σ τ : Type} (enabled : σ → List τ) (step : σ → τ → Option σ)
    (bad : σ → Option Invariant) (depth : Nat) (start : σ) : Option (List τ × Invariant) :=
  let rec walk : Nat → σ → Option (List τ × Invariant)
    | left, state =>
      match bad state with
      | some broken => some ([], broken)
      | none =>
        match left with
        | 0 => none
        | left + 1 =>
          (enabled state).findSome? fun transition =>
            (step state transition).bind fun after =>
              (walk left after).map fun (trace, broken) => (transition :: trace, broken)
  (List.range (depth + 1)).findSome? (walk · start)

/-- The transitions the search tries in `state`, with at most `jobs` jobs:
a start of the next job, each job's steps with a fresh wait of each kind,
each wait of the table ended either way, and the loop's end. Whether each is
enabled is the step's to say. -/
def protocolMoves (jobs : Nat) (state : State) : List Transition :=
  (if state.jobs.length < jobs then [.start state.jobs.length] else []) ++
    (List.range state.jobs.length).flatMap
      (fun job =>
        [.ask job state.nextWait .parks, .ask job state.nextWait .service, .park job, .serve job,
          .resume job, .cancel job, .done job]) ++
    state.table.flatMap (fun wait => [.wake wait .completed, .wake wait .cancelled]) ++
    [.loopEnd]

/-- The state `transitions` reach, or `none`. -/
def reached (transitions : List Transition) : Option State :=
  Protocol.run transitions

/-- The status of the job `job` in the state `transitions` reach. -/
def statusAfter (transitions : List Transition) (job : Nat) : Option Status :=
  (reached transitions).map (·.job job |>.status)

/-- The checks of the protocol model. Each is pure: one per row of the
transition table, enabled and refused, the replay's renaming and its
refusal, and the search's bound over the protocol itself. -/
def protocolChecks : List Check :=
  [{  name := "start adds a queued job that holds a unit, and only as the next job number"
      run :=
        pure
          (reached [.start 0] == some { jobs := [{}], count := 1 } && reached [.start 1] == none &&
            reached [.start 0, .start 0] == none) },
    { name := "no job starts once the loop has ended"
      run := pure (reached [.loopEnd, .start 0] == none) },
    { name := "ask registers a fresh wait from a queued or running job, and only a fresh one"
      run :=
        pure
          (statusAfter [.start 0, .ask 0 3 .parks] 0 == some (.asking 3 .parks none) &&
            (reached [.start 0, .ask 0 3 .parks]).map (·.nextWait) == some 4 &&
            reached [.start 0, .start 1, .ask 0 3 .parks, .ask 1 2 .service] == none &&
            reached [.start 0, .ask 0 0 .parks, .ask 0 1 .parks] == none) },
    { name :=
        "park records the job's wait and gives its unit back; serve records it and keeps the unit"
      run :=
        pure
          (reached [.start 0, .ask 0 0 .parks, .park 0] ==
              some
                { jobs := [{ status := .parked 0, recorded := some 0 }], count := 0
                  nextWait := 1 } &&
            reached [.start 0, .ask 0 0 .service, .serve 0] ==
              some
                { jobs := [{ status := .waiting 0, recorded := some 0 }], count := 1
                  nextWait := 1 }) },
    { name := "park and serve are each refused for the other kind of wait, and for a job not asking"
      run :=
        pure
          (reached [.start 0, .ask 0 0 .parks, .serve 0] == none &&
            reached [.start 0, .ask 0 0 .service, .park 0] == none &&
            reached [.start 0, .park 0] == none) },
    { name :=
        "a wait that ended before its job recorded it leaves the job woken at its park, its unit kept"
      run :=
        pure
          (reached [.start 0, .ask 0 0 .parks, .wake 0 .completed, .park 0] ==
            some
              { jobs := [{ status := .woken .completed, recorded := some 0 }], count := 1
                nextWait := 1 }) },
    { name :=
        "a job cancelled on its way into its wait withdraws it in its park: woken as cancelled, its unit kept, the table empty"
      run :=
        match reached [.start 0, .ask 0 0 .parks, .cancel 0, .park 0] with
        | some state =>
          pure
            (state.job 0 == { status := .woken .cancelled, cancelled := true } &&
              state.count == 1 &&
              state.table == [] &&
              state.wakeUps == [0])
        | none => pure false },
    { name :=
        "wake ends a parked wait and takes a unit, ends a service wait keeping the unit, and is refused for a wait not in the table"
      run :=
        pure
          ((reached [.start 0, .ask 0 0 .parks, .park 0, .wake 0 .completed]).map (·.count) ==
              some 1 &&
            (reached [.start 0, .ask 0 0 .service, .serve 0, .wake 0 .completed]).map (·.count) ==
              some 1 &&
            statusAfter [.start 0, .ask 0 0 .service, .serve 0, .wake 0 .completed] 0 ==
              some (.woken .completed) &&
            reached [.start 0, .ask 0 0 .parks, .park 0, .wake 1 .completed] == none &&
            reached [.start 0, .ask 0 0 .parks, .park 0, .wake 0 .completed, .wake 0 .completed] ==
              none) },
    { name :=
        "resume takes a woken job back to running and clears what it recorded; it is refused for a job not woken"
      run :=
        pure
          ((reached [.start 0, .ask 0 0 .parks, .park 0, .wake 0 .completed, .resume 0]).map
                (·.job 0) ==
              some { status := .running } &&
            reached [.start 0, .resume 0] == none) },
    { name :=
        "cancel sets the job's flag and takes what it recorded, for any job, until the loop has ended"
      run :=
        pure
          ((reached [.start 0, .ask 0 0 .parks, .park 0, .cancel 0]).map (·.job 0) ==
              some { status := .parked 0, cancelled := true } &&
            reached [.cancel 0] == none &&
            reached [.start 0, .done 0, .loopEnd, .cancel 0] == none) },
    { name :=
        "done ends a queued or running job and gives its unit back; it is refused for a job in a wait or done"
      run :=
        pure
          (reached [.start 0, .done 0] == some { jobs := [{ status := .done }], count := 0 } &&
            reached [.start 0, .ask 0 0 .service, .serve 0, .done 0] == none &&
            reached [.start 0, .done 0, .done 0] == none) },
    { name := "the loop ends once every cancelled job is done, and only once"
      run :=
        pure
          ((reached [.start 0, .cancel 0, .done 0, .loopEnd]).map (·.ended) == some true &&
            reached [.start 0, .cancel 0, .loopEnd] == none &&
            reached [.loopEnd, .loopEnd] == none) },
    { name := "a replay renames each job's number to its place among the trace's starts"
      run :=
        pure
          (match replay #[.start 7, .start 3, .done 3, .ask 7 5 .service, .serve 7] with
          | .ok state =>
            state.job 0 == { status := .waiting 5, recorded := some 5 } &&
              state.job 1 == { status := .done } &&
              state.count == 1
          | .error _ => false) },
    { name := "a replay refused names the index, the transition and the state it was refused in"
      run :=
        pure
          (match replay #[.start 4, .done 4, .done 4] with
          | .error refusal =>
            refusal.index == 2 && refusal.transition == .done 0 &&
              refusal.state.job 0 == { status := .done }
          | .ok _ => false) },
    { name := "a replay refuses a transition of a job the trace never started"
      run :=
        pure
          (match replay #[.start 1, .done 2] with
          | .error refusal => refusal.index == 1
          | .ok _ => false) },
    { name :=
        "the checker finds no broken invariant in the protocol within 6 steps of one job and 5 of two"
      run :=
        pure
          ((search (protocolMoves 1) State.step State.violation? 6 {}).isNone &&
            (search (protocolMoves 2) State.step State.violation? 5 {}).isNone) },
    { name := "the checker sees a state that breaks each invariant"
      run :=
        pure
          (({ jobs := [{ status := .parked 0 }] } : State).violation? ==
              some .cancelFindsRunningOrRecorded &&
            ({ jobs := [{}] } : State).violation? == some .countZeroIffNoneHolds &&
            ({ jobs := [{ cancelled := true }], count := 1, ended := true } : State).violation? ==
              some .loopEndSettlesCancelled &&
            ({} : State).violation? == none) }]

end ModelTest
