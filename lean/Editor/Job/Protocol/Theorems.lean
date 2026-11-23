import Editor.Job.Protocol

/-!
# What is proved of the job runner's protocol

The safety invariants of the runner's protocol (`Editor/Job/Protocol.lean`),
over every reachable state, and over every run for the one that counts
transitions. `lake build` checks them: `Editor/Core.lean` imports this
module. Each theorem's axioms are pinned below it (`#print axioms`), so a
proof that came to need another axiom, `sorryAx` among them, fails the
build.

- `cancel_finds_running_or_recorded`: a job not cancelled and not done is on
  its thread (`queued`, `running` or `asking`, where it sees the token
  itself) or has its wait recorded, which a cancel takes and withdraws.
- `count_zero_iff_none_holds`: the runner's share of the activity count is
  0 exactly when no job holds a unit: none is running or in a service wait,
  and no wake-up is queued.
- `done_matches_start`: in every run, each job starts at most once, and is
  done at most as often as it started; with `Run.prefix`, every `done` has
  its one `start` before it.
- `loopEnd_settles_cancelled`: once the loop has ended, every cancelled job
  is done: its wake-up has been handled and its unit given back.
- `run_iff_Run`: the executable replay (`Protocol.run`) reaches a state
  exactly when the trace is a run.
- `checker_agrees`: the decidable checker the model tests search with
  (`State.violation?`) finds nothing in a reachable state.

The proofs go through one inductive invariant (`Inv`): the count is the
number of jobs that hold a unit, every job not cancelled has recorded the
wait it is in (`JobState.good`), and after loop-end every cancelled job is
done.
-/

namespace Editor.Job.Protocol

/-- The states the protocol reaches from its initial state. -/
inductive Reachable : State → Prop where
  /-- The initial state. -/
  | init : Reachable {}
  /-- One step on from a reachable state. -/
  |
  step {state after : State} {transition : Transition} :
    Reachable state → state.step transition = some after → Reachable after

/-- A trace the protocol takes from its initial state, and the state it
reaches, built by appending one step. -/
inductive Run : List Transition → State → Prop where
  /-- The empty trace. -/
  | nil : Run [] {}
  /-- One step after a run. -/
  |
  snoc {trace : List Transition} {state after : State} {transition : Transition} :
    Run trace state → state.step transition = some after → Run (trace ++ [transition]) after

/-- The replay of a trace with one step more. -/
theorem run_snoc (trace : List Transition) (transition : Transition) :
    run (trace ++ [transition]) = (run trace).bind (·.step transition) := by
  unfold run
  rw [List.foldlM_append]
  generalize List.foldlM (fun (state : State) transition => state.step transition) {} trace = before
  cases before with
  | none => rfl
  | some state =>
    show state.step transition >>= pure = state.step transition
    cases state.step transition <;> rfl

/-- A replay that reaches a state is a run to it, for a trace given
reversed. -/
theorem run_Run_reversed :
    ∀ (reversed : List Transition) (state : State),
      run reversed.reverse = some state → Run reversed.reverse state
  | [], state, reached => by
    have : ({} : State) = state := by simpa [run] using reached
    exact this ▸ Run.nil
  | transition :: rest, state, reached => by
    rw [List.reverse_cons] at reached ⊢
    rw [run_snoc] at reached
    cases before : run rest.reverse with
    | none => simp [before] at reached
    | some previous =>
      simp only [before, Option.bind_some] at reached
      exact Run.snoc (run_Run_reversed rest previous before) reached

/-- The executable replay reaches a state exactly when the trace is a run
to it. -/
theorem run_iff_Run (trace : List Transition) (state : State) :
    run trace = some state ↔ Run trace state := by
  constructor
  · intro reached
    have := run_Run_reversed trace.reverse state (by simpa using reached)
    simpa using this
  · intro ran
    induction ran with
    | nil => rfl
    | snoc _ stepped ih =>
      rw [run_snoc, ih]; exact stepped

/-- A run is to a reachable state. -/
theorem Run.reachable {trace : List Transition} {state : State} (ran : Run trace state) :
    Reachable state := by
  induction ran with
  | nil => exact Reachable.init
  | snoc _ stepped ih => exact Reachable.step ih stepped

/-- A prefix of a run is a run. -/
theorem Run.prefix {front back : List Transition} {state : State}
    (ran : Run (front ++ back) state) : ∃ before, Run front before := by
  rw [← run_iff_Run] at ran
  unfold run at ran
  rw [List.foldlM_append] at ran
  cases reached : run front with
  | none =>
    unfold run at reached
    rw [reached] at ran
    cases ran
  | some before => exact ⟨before, (run_iff_Run front before).mp reached⟩

/-! ## One job's step -/

/-- Whether a job not cancelled has recorded the wait it is in, and has a
wait recorded while its continuation is queued. -/
def JobState.good (job : JobState) : Bool :=
  job.cancelled ||
    match job.status with
    | .waiting wait | .parked wait => job.recorded == some wait
    | .woken _ => job.recorded.isSome
    | _ => true

/-- A job's step moves the count by what its holding changed, and gives a
unit back only from a job that held one. -/
theorem JobState.step_holds {job after : JobState} {move : Move} {transition : Transition}
    (stepped : job.step transition = some (after, move)) :
    move.apply job.holds.toNat = after.holds.toNat ∧ (move = .give → job.holds = true) := by
  rcases job with ⟨status, cancelled, recorded⟩
  cases transition <;> cases status <;>
    simp only [JobState.step, JobState.enter, JobState.wake] at stepped <;>
    repeat' split at stepped
  all_goals try simp only [Option.some.injEq, Prod.mk.injEq, reduceCtorEq] at stepped
  all_goals obtain ⟨rfl, rfl⟩ := stepped
  all_goals simp_all [JobState.holds, Status.holds, Move.apply]

/-- A job's step keeps it good. -/
theorem JobState.step_good {job after : JobState} {move : Move} {transition : Transition}
    (good : job.good = true) (stepped : job.step transition = some (after, move)) :
    after.good = true := by
  rcases job with ⟨status, cancelled, recorded⟩
  cases transition <;> cases status <;>
    simp only [JobState.step, JobState.enter, JobState.wake] at stepped <;>
    repeat' split at stepped
  all_goals try simp only [Option.some.injEq, Prod.mk.injEq, reduceCtorEq] at stepped
  all_goals obtain ⟨rfl, rfl⟩ := stepped
  all_goals simp_all [JobState.good]
  all_goals obtain cancelled | recorded := good <;> simp [*]

/-- A job's step leaves it done exactly when it was done, or the step is its
`done`, which is enabled only for a job not done. -/
theorem JobState.step_done {job after : JobState} {move : Move} {transition : Transition}
    (stepped : job.step transition = some (after, move)) :
    (after.status = .done ↔ (job.status = .done ∨ ∃ index, transition = .done index)) ∧
      ∀ index, transition = .done index → job.status ≠ .done := by
  rcases job with ⟨status, cancelled, recorded⟩
  cases transition <;> cases status <;>
    simp only [JobState.step, JobState.enter, JobState.wake] at stepped <;>
    repeat' split at stepped
  all_goals try simp only [Option.some.injEq, Prod.mk.injEq, reduceCtorEq] at stepped
  all_goals obtain ⟨rfl, rfl⟩ := stepped
  all_goals simp_all

/-- A job's step keeps it cancelled, and cancels it only as its `cancel`. -/
theorem JobState.step_cancelled {job after : JobState} {move : Move} {transition : Transition}
    (stepped : job.step transition = some (after, move)) :
    after.cancelled = true → (job.cancelled = true ∨ ∃ index, transition = .cancel index) := by
  rcases job with ⟨status, cancelled, recorded⟩
  cases transition <;> cases status <;>
    simp only [JobState.step, JobState.enter, JobState.wake] at stepped <;>
    repeat' split at stepped
  all_goals try simp only [Option.some.injEq, Prod.mk.injEq, reduceCtorEq] at stepped
  all_goals obtain ⟨rfl, rfl⟩ := stepped
  all_goals simp_all

/-- A good job is one a cancel finds on its thread or with its wait
recorded, when it is not cancelled and not done. -/
theorem JobState.good_reachable {job : JobState} (good : job.good = true) :
    job.reachable = true := by
  rcases job with ⟨status, cancelled, recorded⟩
  cases status <;> cases cancelled <;> cases recorded <;>
    simp_all [JobState.good, JobState.reachable, Status.onThread]

/-! ## Lists -/

/-- The sum over a list with one element replaced, plus the old element's
term, is the old sum plus the new element's term. -/
theorem sum_set {α : Type} (f : α → Nat) :
    ∀ (items : List α) (index : Nat) (item : α) (inside : index < items.length),
      ((items.set index item).map f).sum + f items[index] = (items.map f).sum + f item
  | [], _, _, inside => absurd inside (Nat.not_lt_zero _)
  | head :: tail, 0, item, _ => by
    simp; omega
  | head :: tail, index + 1, item, inside => by
    have := sum_set f tail index item (by simpa using inside)
    simp only [List.set_cons_succ, List.map_cons, List.sum_cons, List.getElem_cons_succ]
    omega

/-- A sum of naturals is 0 exactly when every term is. -/
theorem sum_zero {α : Type} (f : α → Nat) :
    ∀ items : List α, (items.map f).sum = 0 ↔ ∀ item ∈ items, f item = 0
  | [] => by simp
  | head :: tail => by
    simp only [List.map_cons, List.sum_cons, List.mem_cons, forall_eq_or_imp]
    rw [← sum_zero f tail]
    omega

/-- Every element of a list with one replaced is an old one or the new
one. -/
theorem all_set {α : Type} {p : α → Bool} {items : List α} {index : Nat} {item : α}
    (all : items.all p = true) (fresh : p item = true) : (items.set index item).all p = true := by
  simp only [List.all_eq_true] at all ⊢
  intro other member
  rcases List.mem_or_eq_of_mem_set member with old | new
  · exact all other old
  · exact new ▸ fresh

/-- The job at a place inside the list is the list's element there. -/
theorem State.job_lt {state : State} {index : Nat} (inside : index < state.jobs.length) :
    state.job index = state.jobs[index] := by simp [State.job, inside]

/-! ## The invariant -/

/-- The inductive invariant: the count is the number of jobs that hold a
unit, every job is good, and after loop-end every cancelled job is done. -/
def Inv (state : State) : Prop :=
  state.count = (state.jobs.map (·.holds.toNat)).sum ∧
    state.jobs.all (·.good) = true ∧ (state.ended = true → state.cancelledDone = true)

/-- The initial state keeps the invariant. -/
theorem inv_init : Inv {} := by simp [Inv]

/-- A job's step applied to the state keeps the invariant, unless it is a
cancel after loop-end. -/
theorem inv_applyAt {state after : State} {index : Nat} {transition : Transition} (inv : Inv state)
    (stepped : state.applyAt index transition = some after)
    (cancelOpen : ∀ job, transition = .cancel job → state.ended = false) : Inv after := by
  obtain ⟨counted, good, settled⟩ := inv
  unfold State.applyAt at stepped
  split at stepped
  · cases stepped
  · rename_i job found
    split at stepped
    · cases stepped
    · rename_i changed move steppedJob
      cases stepped
      have inside : index < state.jobs.length := by
        rcases List.getElem?_eq_some_iff.mp found with ⟨inside, _⟩
        exact inside
      have atIndex : state.jobs[index] = job := by
        rcases List.getElem?_eq_some_iff.mp found with ⟨_, there⟩
        exact there
      have member : job ∈ state.jobs := atIndex ▸ List.getElem_mem inside
      obtain ⟨moved, gave⟩ := JobState.step_holds steppedJob
      have summed := sum_set (·.holds.toNat) state.jobs index changed inside
      rw [atIndex] at summed
      refine ⟨?_, ?_, ?_⟩
      · show move.apply state.count = _
        cases move <;> simp only [Move.apply] at moved ⊢
        · omega
        · omega
        · have : job.holds = true := gave rfl
          simp only [this, Bool.toNat_true] at moved summed
          omega
      · exact all_set good (JobState.step_good (List.all_eq_true.mp good job member) steppedJob)
      · intro ended
        simp only at ended
        have wasDone := settled ended
        apply all_set wasDone
        simp only [Bool.or_eq_true, Bool.not_eq_true', beq_iff_eq]
        cases cancelled : changed.cancelled
        · exact Or.inl rfl
        · right
          rcases JobState.step_cancelled steppedJob cancelled with before | ⟨job', isCancel⟩
          · have := List.all_eq_true.mp wasDone job member
            simp only [Bool.or_eq_true, Bool.not_eq_true', beq_iff_eq, before] at this
            rcases this with no | done
            · cases no
            · exact (JobState.step_done steppedJob).1.mpr (Or.inl done)
          · simp [cancelOpen job' isCancel] at ended

/-- Every step keeps the invariant. -/
theorem inv_step {state after : State} {transition : Transition} (inv : Inv state)
    (stepped : state.step transition = some after) : Inv after := by
  cases transition with
  | start index =>
    simp only [State.step] at stepped
    split at stepped
    · rename_i fresh
      cases stepped
      obtain ⟨counted, good, settled⟩ := inv
      simp only [Bool.and_eq_true, beq_iff_eq, Bool.not_eq_true'] at fresh
      refine ⟨?_, ?_, ?_⟩
      · simp [counted, JobState.started, JobState.holds, Status.holds]
      · rw [List.all_append, good]
        simp [JobState.started, JobState.good]
      · simp [fresh.2]
    · cases stepped
  | ask index wait kind =>
    simp only [State.step] at stepped
    split at stepped
    · cases applied : state.applyAt index (.ask index wait kind) with
      | none => simp [applied] at stepped
      | some changed =>
        simp only [applied, Option.map_some, Option.some.injEq] at stepped
        cases stepped
        have := inv_applyAt inv applied (by simp)
        exact this
    · cases stepped
  | park index => exact inv_applyAt inv stepped (by simp)
  | serve index => exact inv_applyAt inv stepped (by simp)
  | wake wait completion =>
    simp only [State.step] at stepped
    split at stepped
    · exact inv_applyAt inv stepped (by simp)
    · cases stepped
  | resume index => exact inv_applyAt inv stepped (by simp)
  | cancel index =>
    simp only [State.step] at stepped
    split at stepped
    · cases stepped
    · rename_i notEnded
      exact inv_applyAt inv stepped (fun _ _ => by simpa using notEnded)
  | done index => exact inv_applyAt inv stepped (by simp)
  | loopEnd =>
    simp only [State.step] at stepped
    split at stepped
    · rename_i allowed
      cases stepped
      obtain ⟨counted, good, _⟩ := inv
      simp only [Bool.and_eq_true, Bool.not_eq_true'] at allowed
      exact ⟨counted, good, fun _ => allowed.2⟩
    · cases stepped

/-- Every reachable state keeps the invariant. -/
theorem Reachable.inv {state : State} (reachable : Reachable state) : Inv state := by
  induction reachable with
  | init => exact inv_init
  | step _ stepped ih => exact inv_step ih stepped

/-! ## The invariants -/

/-- A cancel finds its job on its thread or its wait recorded: a job that is
not cancelled and not done is `queued`, `running` or `asking`, where it
looks at the token itself, or has recorded the wait it is in, which the
cancel takes and withdraws. -/
theorem cancel_finds_running_or_recorded {state : State} (reachable : Reachable state) {index : Nat}
    (inside : index < state.jobs.length) (live : (state.job index).cancelled = false)
    (notDone : (state.job index).status ≠ .done) :
    (state.job index).status.onThread = true ∨ (state.job index).recorded.isSome = true := by
  obtain ⟨_, good, _⟩ := reachable.inv
  have isGood := List.all_eq_true.mp good _ (List.getElem_mem inside)
  rw [← State.job_lt inside] at isGood
  have := JobState.good_reachable isGood
  simp only [JobState.reachable, Bool.or_eq_true, live, beq_iff_eq, notDone] at this
  simpa using this

/-- The runner's share of the activity count is 0 exactly when no job holds
a unit: none is running or in a service wait, and no wake-up is queued. -/
theorem count_zero_iff_none_holds {state : State} (reachable : Reachable state) :
    state.count = 0 ↔ ∀ index < state.jobs.length, (state.job index).holds = false := by
  obtain ⟨counted, _, _⟩ := reachable.inv
  rw [counted, sum_zero]
  constructor
  · intro none index inside
    rw [State.job_lt inside]
    have := none _ (List.getElem_mem inside)
    simpa using this
  · intro none job member
    obtain ⟨index, inside, atIndex⟩ := List.getElem_of_mem member
    have := none index inside
    rw [State.job_lt inside, atIndex] at this
    simp [this]

/-- Once the loop has ended, every cancelled job is done: its wake-up has
been handled and its unit given back, and no transition can change that,
since a done job moves no more and no job is cancelled after loop-end. -/
theorem loopEnd_settles_cancelled {state : State} (reachable : Reachable state)
    (ended : state.ended = true) {index : Nat} (inside : index < state.jobs.length)
    (cancelled : (state.job index).cancelled = true) : (state.job index).status = .done := by
  obtain ⟨_, _, settled⟩ := reachable.inv
  have := List.all_eq_true.mp (settled ended) _ (List.getElem_mem inside)
  rw [← State.job_lt inside] at this
  simpa [cancelled] using this

/-- The checker the model tests search with finds nothing in a reachable
state: it agrees with the theorems above. -/
theorem checker_agrees {state : State} (reachable : Reachable state) : state.violation? = none := by
  obtain ⟨counted, good, settled⟩ := reachable.inv
  have reaches : state.jobs.all (·.reachable) = true := by
    simp only [List.all_eq_true] at good ⊢
    exact fun job member => JobState.good_reachable (good job member)
  have zero : (state.count == 0) = state.jobs.all (!·.holds) := by
    have := sum_zero (·.holds.toNat) state.jobs
    rw [← counted] at this
    apply Bool.eq_iff_iff.mpr
    simp only [beq_iff_eq, this, List.all_eq_true, Bool.not_eq_true']
    constructor
    · intro none job member
      have := none job member
      simpa using this
    · intro none job member
      simp [none job member]
  unfold State.violation?
  cases ended : state.ended
  · simp [reaches, zero]
  · simp [reaches, zero, settled ended]

/-! ## Starts and dones -/

/-- A job's step applied to the state keeps the number of jobs, and leaves
a job done exactly when it was, or the step is the `done` of that job, which
was not done. -/
theorem applyAt_done {state after : State} {index : Nat} {transition : Transition}
    (stepped : state.applyAt index transition = some after) :
    after.jobs.length = state.jobs.length ∧
      index < state.jobs.length ∧
      (∀ other, other ≠ index → after.job other = state.job other) ∧
      ((after.job index).status = .done ↔
        ((state.job index).status = .done ∨ ∃ job, transition = .done job)) ∧
      ∀ job, transition = .done job → (state.job index).status ≠ .done := by
  unfold State.applyAt at stepped
  split at stepped
  · cases stepped
  · rename_i job found
    split at stepped
    · cases stepped
    · rename_i changed move steppedJob
      cases stepped
      obtain ⟨inside, atIndex⟩ := List.getElem?_eq_some_iff.mp found
      have before : state.job index = job := by rw [State.job_lt inside, atIndex]
      have now :
        ({ state with
                  jobs := state.jobs.set index changed, count := move.apply state.count } :
                State).job
            index =
          changed := by
        simp [State.job, inside]
      obtain ⟨doneIff, notBefore⟩ := JobState.step_done steppedJob
      refine ⟨by simp, inside, ?_, ?_, ?_⟩
      · intro other differs
        simp [State.job, Ne.symm differs]
      · simp only [now, before]
        exact doneIff
      · rw [before]
        exact notBefore

/-- A step that is neither a start nor a done keeps the number of jobs, and
which of them are done. -/
theorem step_keeps_done {state after : State} {transition : Transition}
    (stepped : state.step transition = some after) (notStart : ∀ job, transition ≠ .start job)
    (notDone : ∀ job, transition ≠ .done job) :
    after.jobs.length = state.jobs.length ∧
      ∀ job, (after.job job).status = .done ↔ (state.job job).status = .done := by
  have viaApply :
    ∀ {index : Nat} {changed : State},
      state.applyAt index transition = some changed →
        changed.jobs.length = state.jobs.length ∧
          ∀ job, (changed.job job).status = .done ↔ (state.job job).status = .done := by
    intro index changed applied
    obtain ⟨length, _, others, doneIff, _⟩ := applyAt_done applied
    refine ⟨length, fun job => ?_⟩
    by_cases same : job = index
    · subst same
      rw [doneIff]
      simp [notDone]
    · rw [others job same]
  cases transition
  case start index => exact absurd rfl (notStart index)
  case done index => exact absurd rfl (notDone index)
  case ask index wait kind =>
    simp only [State.step] at stepped
    split at stepped
    · cases applied : state.applyAt index (.ask index wait kind) with
      | none => simp [applied] at stepped
      | some changed =>
        simp only [applied, Option.map_some, Option.some.injEq] at stepped
        cases stepped
        have kept := viaApply applied
        exact kept
    · cases stepped
  case wake wait completion =>
    simp only [State.step] at stepped
    split at stepped
    · exact viaApply stepped
    · cases stepped
  case cancel index =>
    simp only [State.step] at stepped
    split at stepped
    · cases stepped
    · exact viaApply stepped
  case loopEnd =>
    simp only [State.step] at stepped
    split at stepped
    · cases stepped
      exact ⟨rfl, fun _ => Iff.rfl⟩
    · cases stepped
  all_goals exact viaApply stepped

/-- Along a run, each job has started once if it is among the state's jobs
and never otherwise, and is done once if it is done there and never
otherwise. -/
theorem Run.counts {trace : List Transition} {state : State} (ran : Run trace state) :
    ∀ job,
      trace.count (.start job) = (if job < state.jobs.length then 1 else 0) ∧
        trace.count (.done job) =
          (if job < state.jobs.length ∧ (state.job job).status = .done then 1 else 0) := by
  induction ran with
  | nil =>
    intro job; simp
  | @snoc trace state after transition _ stepped
    ih =>
    intro job
    obtain ⟨started, finished⟩ := ih job
    simp only [List.count_append, List.count_singleton, started, finished]
    cases transition
    case start index =>
      simp only [State.step] at stepped
      split at stepped
      · rename_i fresh
        cases stepped
        simp only [Bool.and_eq_true, beq_iff_eq] at fresh
        have newJob :
          ({ state with
                    jobs := state.jobs ++ [JobState.started.1], count := state.count + 1 } :
                  State).job
              job =
            if job < state.jobs.length then state.job job
            else if job = state.jobs.length then {} else {} := by
          simp only [State.job, JobState.started]
          by_cases inside : job < state.jobs.length
          · simp [inside, List.getElem?_append_left]
          · by_cases last : job = state.jobs.length
            · subst last; simp
            · simp only [inside, ite_false, last]
              rw [List.getElem?_eq_none
                  (by
                    simp; omega)]
              rfl
        rw [newJob]
        by_cases inside : job < state.jobs.length
        · have : index ≠ job := by omega
          simp [inside, this, Nat.lt_succ_of_lt inside]
        · by_cases last : job = state.jobs.length
          · subst last
            simp [fresh.1]
          · have : index ≠ job := by omega
            have : ¬job < state.jobs.length + 1 := by omega
            have : state.jobs.length ≠ job := Ne.symm last
            simp [*]
      · cases stepped
    case done
      index =>
      obtain ⟨length, inside, others, doneIff, notBefore⟩ := applyAt_done stepped
      rw [length]
      by_cases same : job = index
      · subst same
        have isDone : (after.job job).status = .done := doneIff.mpr (Or.inr ⟨job, rfl⟩)
        simp [inside, isDone, notBefore job rfl]
      · rw [others job same]
        simp [Ne.symm same]
    all_goals
      obtain ⟨length, same⟩ := step_keeps_done stepped (by simp) (by simp)
      simp [length, same job]

/-- Every `done` matches exactly one `start`: in every run each job starts
at most once, and is done at most as often as it started, so a `done` comes
only for a job that started, once. With `Run.prefix`, the `start` of a job
done in a run comes before its `done`. -/
theorem done_matches_start {trace : List Transition} {state : State} (ran : Run trace state)
    (job : Nat) :
    trace.count (.start job) ≤ 1 ∧ trace.count (.done job) ≤ trace.count (.start job) := by
  obtain ⟨started, finished⟩ := ran.counts job
  rw [started, finished]
  by_cases inside : job < state.jobs.length
  · simp only [inside, true_and, ite_true]
    split <;> simp
  · simp [inside]

/-! ## The axioms each theorem rests on

At most `propext`, `Classical.choice` and `Quot.sound`: `sorryAx`, or any
new axiom, changes a message below and fails the build. -/

/--
info: 'Editor.Job.Protocol.cancel_finds_running_or_recorded' depends on axioms: [propext, Classical.choice, Quot.sound]
-/
#guard_msgs in
#print axioms cancel_finds_running_or_recorded

/--
info: 'Editor.Job.Protocol.count_zero_iff_none_holds' depends on axioms: [propext, Classical.choice, Quot.sound]
-/
#guard_msgs in
#print axioms count_zero_iff_none_holds

/--
info: 'Editor.Job.Protocol.done_matches_start' depends on axioms: [propext, Quot.sound]
-/
#guard_msgs in
#print axioms done_matches_start

/--
info: 'Editor.Job.Protocol.loopEnd_settles_cancelled' depends on axioms: [propext, Classical.choice, Quot.sound]
-/
#guard_msgs in
#print axioms loopEnd_settles_cancelled

/--
info: 'Editor.Job.Protocol.run_iff_Run' depends on axioms: [propext, Quot.sound]
-/
#guard_msgs in
#print axioms run_iff_Run

/--
info: 'Editor.Job.Protocol.checker_agrees' depends on axioms: [propext, Classical.choice, Quot.sound]
-/
#guard_msgs in
#print axioms checker_agrees

end Editor.Job.Protocol
