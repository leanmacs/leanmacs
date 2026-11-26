import AgentsApiTest.Protocol

/-!
# What is proved of the protocol's model

The three rules of the Agent Client Protocol the client keeps
(`AgentsApiTest/Protocol.lean`), over every reachable state. `lake build`
checks them: the test library `AgentsApiTest` is a default target of the
package. Each theorem's axioms are pinned below it (`#print axioms`), so a
proof that came to need another axiom, `sorryAx` among them, fails the
build.

- `respond_answers_exactly_one`: the outstanding requests hold no request
  twice, a response answers the one outstanding request it names and takes
  it out, and a response to a request that is not outstanding is refused.
- `parked_answered_exactly_once`: no ticket is answered twice, no parked
  ticket is answered, and once the connection is closed every ticket asked
  has been answered exactly once.
- `cancel_leaves_none_pending`: no permission request of a cancelled turn
  is parked, one that arrived after the cancel included.

The proofs go through one inductive invariant (`Inv`).
-/

namespace AgentsApiTest.Protocol

/-- The states the protocol reaches from its initial state. -/
inductive Reachable : State → Prop where
  /-- The initial state. -/
  | init : Reachable State.init
  /-- One step on from a reachable state. -/
  |
  step {state after : State} {action : Action} :
    Reachable state → state.step action = some after → Reachable after

/-- The invariant every reachable state keeps. -/
structure Inv (state : State) : Prop where
  /-- No request is outstanding twice. -/
  outstanding : state.outstanding.Nodup
  /-- No ticket is answered twice. -/
  answers : state.answers.Nodup
  /-- No ticket is parked twice. -/
  parked : (state.parked.map (·.1)).Nodup
  /-- No parked ticket is answered. -/
  apart : ∀ ticket, ticket ∈ state.parked.map (·.1) → ticket ∉ state.answers
  /-- A ticket asked is answered or parked, and nothing else is. -/
  asked : ∀ ticket, ticket ∈ state.asked ↔ ticket ∈ state.answers ∨ ticket ∈ state.parked.map (·.1)
  /-- No request of a cancelled turn is parked. -/
  cancelled : ∀ turn ∈ state.cancelled, ∀ entry ∈ state.parked, entry.2 ≠ some turn
  /-- A closed connection parks nothing. -/
  closed : state.closed = true → state.parked = []

/-- Two entries of a list whose first parts are distinct are equal when their
first parts are. -/
theorem eq_of_fst_eq {α β : Type} :
    ∀ {entries : List (α × β)},
      (entries.map (·.1)).Nodup →
        ∀ {one two : α × β}, one ∈ entries → two ∈ entries → one.1 = two.1 → one = two
  | [], _, _, _, inOne, _, _ => by simp at inOne
  | head :: rest, distinct, one, two, inOne, inTwo, same => by
    rw [List.map_cons, List.nodup_cons] at distinct
    obtain ⟨fresh, distinctRest⟩ := distinct
    rcases List.mem_cons.mp inOne with oneHead | oneRest <;>
      rcases List.mem_cons.mp inTwo with twoHead | twoRest
    · exact oneHead.trans twoHead.symm
    · exact absurd (oneHead ▸ same ▸ List.mem_map_of_mem (f := (·.1)) twoRest) fresh
    · exact absurd (twoHead ▸ same.symm ▸ List.mem_map_of_mem (f := (·.1)) oneRest) fresh
    · exact eq_of_fst_eq distinctRest oneRest twoRest same

/-- A filter of a list of distinct first parts keeps them distinct. -/
theorem nodup_map_filter {α β : Type} {entries : List (α × β)} (keep : α × β → Bool)
    (distinct : (entries.map (·.1)).Nodup) : ((entries.filter keep).map (·.1)).Nodup :=
  distinct.sublist (List.filter_sublist.map _)

/-- A list of distinct items, with one more not among them, holds distinct
items. -/
theorem nodup_snoc {α : Type} {items : List α} {item : α} (distinct : items.Nodup)
    (fresh : item ∉ items) : (items ++ [item]).Nodup :=
  List.nodup_append.mpr
    ⟨distinct, List.nodup_cons.mpr ⟨List.not_mem_nil, List.nodup_nil⟩, fun _ inItems _ inOne same =>
      fresh (List.mem_singleton.mp inOne ▸ same ▸ inItems)⟩

/-- The initial state keeps the invariant. -/
theorem inv_init : Inv State.init :=
  { outstanding := List.nodup_nil, answers := List.nodup_nil, parked := List.nodup_nil
    apart := by simp [State.init]
    asked := by simp [State.init]
    cancelled := by simp [State.init]
    closed := by simp [State.init] }

/-- Every step keeps the invariant. -/
theorem inv_step {state after : State} {action : Action} (inv : Inv state)
    (stepped : state.step action = some after) : Inv after := by
  cases action with
  | send request turn =>
    simp only [State.step] at stepped
    split at stepped
    · contradiction
    · rename_i fresh
      rw [not_or] at fresh
      cases stepped
      exact { inv with outstanding := nodup_snoc inv.outstanding fresh.2 }
  | respond request =>
    simp only [State.step] at stepped
    split at stepped
    · contradiction
    · cases stepped
      exact { inv with outstanding := inv.outstanding.erase request }
  | ask ticket =>
    simp only [State.step] at stepped
    split at stepped
    · contradiction
    · rename_i fresh
      rw [not_or] at fresh
      have unasked : ticket ∉ state.answers ∧ ticket ∉ state.parked.map (·.1) :=
        not_or.mp fun answered => fresh.2 ((inv.asked ticket).mpr answered)
      split at stepped
      · cases stepped
        refine
          { inv with
            answers := nodup_snoc inv.answers unasked.1, apart := ?_, asked := ?_ }
        · intro other parkedOther
          simp only [List.mem_append, List.mem_singleton, not_or]
          exact ⟨inv.apart other parkedOther, fun same => unasked.2 (same ▸ parkedOther)⟩
        · intro other
          simp only [List.mem_append, List.mem_singleton]
          rw [inv.asked other]
          constructor
          · rintro ((inAnswers | inParked) | same)
            · exact .inl (.inl inAnswers)
            · exact .inr inParked
            · exact .inl (.inr same)
          · rintro ((inAnswers | same) | inParked)
            · exact .inl (.inl inAnswers)
            · exact .inr same
            · exact .inl (.inr inParked)
      · rename_i uncancelled
        cases stepped
        refine
          { inv with
            parked := ?_, apart := ?_, asked := ?_, cancelled := ?_, closed := ?_ }
        · rw [List.map_append]
          exact nodup_snoc inv.parked unasked.2
        · intro other parkedOther
          simp only [List.map_append, List.mem_append, List.map_cons, List.map_nil,
            List.mem_singleton] at parkedOther
          rcases parkedOther with parkedOther | same
          · exact inv.apart other parkedOther
          · exact same ▸ unasked.1
        · intro other
          simp only [List.mem_append, List.mem_singleton, List.map_append, List.map_cons,
            List.map_nil]
          rw [inv.asked other]
          constructor
          · rintro ((inAnswers | inParked) | same)
            · exact .inl inAnswers
            · exact .inr (.inl inParked)
            · exact .inr (.inr same)
          · rintro (inAnswers | inParked | same)
            · exact .inl (.inl inAnswers)
            · exact .inl (.inr inParked)
            · exact .inr same
        · intro turn inCancelled entry inParked
          rw [List.mem_append, List.mem_singleton] at inParked
          rcases inParked with inParked | isNew
          · exact inv.cancelled turn inCancelled entry inParked
          · intro same
            rw [isNew] at same
            exact uncancelled ⟨turn, inCancelled, same⟩
        · intro closed
          exact absurd closed fresh.1
  | answer ticket =>
    simp only [State.step] at stepped
    split at stepped
    · contradiction
    · rename_i parked
      rw [not_or, Classical.not_not] at parked
      obtain ⟨open', isParked⟩ := parked
      have isParked : ticket ∈ state.parked.map (·.1) := isParked
      cases stepped
      refine
        { inv with
          answers := nodup_snoc inv.answers (inv.apart ticket isParked)
          parked := nodup_map_filter _ inv.parked
          apart := ?_
          asked := ?_
          cancelled := ?_
          closed := ?_ }
      · intro other kept
        simp only [List.mem_map, List.mem_filter, bne_iff_ne, ne_eq] at kept
        obtain ⟨kept, keptParked, same⟩ := kept
        rw [← same]
        simp only [List.mem_append, List.mem_singleton, not_or]
        exact ⟨inv.apart _ (List.mem_map_of_mem keptParked.1), keptParked.2⟩
      · intro other
        simp only [List.mem_append, List.mem_singleton, List.mem_map, List.mem_filter, bne_iff_ne,
          ne_eq]
        rw [inv.asked other]
        constructor
        · rintro (inAnswers | inParked)
          · exact .inl (.inl inAnswers)
          · obtain ⟨found, foundParked, same⟩ := List.mem_map.mp inParked
            by_cases isTicket : found.1 = ticket
            · exact .inl (.inr (same ▸ isTicket))
            · exact .inr ⟨found, ⟨foundParked, isTicket⟩, same⟩
        · rintro ((inAnswers | isTicket) | ⟨found, ⟨foundParked, _⟩, same⟩)
          · exact .inl inAnswers
          · exact .inr (isTicket ▸ isParked)
          · exact .inr (same ▸ List.mem_map_of_mem foundParked)
      · intro turn inCancelled kept inKept
        exact inv.cancelled turn inCancelled kept (List.mem_filter.mp inKept).1
      · intro closed
        exact absurd closed open'
  | cancel =>
    simp only [State.step] at stepped
    split at stepped
    · contradiction
    · rename_i open'
      split at stepped
      · cases stepped
        exact inv
      · rename_i turn _
        cases stepped
        refine
          { inv with
            answers := ?_
            parked := nodup_map_filter _ inv.parked
            apart := ?_
            asked := ?_
            cancelled := ?_
            closed := ?_ }
        · refine List.nodup_append.mpr ⟨inv.answers, nodup_map_filter _ inv.parked, ?_⟩
          intro a inA b inB same
          simp only [List.mem_map, List.mem_filter] at inB
          obtain ⟨entry, ⟨inParked, _⟩, isB⟩ := inB
          exact inv.apart _ (List.mem_map_of_mem inParked) (isB ▸ same ▸ inA)
        · intro other kept
          simp only [List.mem_map, List.mem_filter, bne_iff_ne, ne_eq] at kept
          obtain ⟨kept, ⟨keptParked, keptTurn⟩, isOther⟩ := kept
          rw [← isOther]
          simp only [List.mem_append, List.mem_map, List.mem_filter, beq_iff_eq, not_or, not_exists,
            not_and]
          refine ⟨inv.apart _ (List.mem_map_of_mem keptParked), ?_⟩
          intro withdrawn withdrawnParked same
          have := eq_of_fst_eq inv.parked withdrawnParked.1 keptParked same
          exact keptTurn (this ▸ withdrawnParked.2)
        · intro other
          simp only [List.mem_append, List.mem_map, List.mem_filter, bne_iff_ne, ne_eq, beq_iff_eq]
          rw [inv.asked other]
          constructor
          · rintro (inAnswers | inParked)
            · exact .inl (.inl inAnswers)
            · obtain ⟨found, foundParked, same⟩ := List.mem_map.mp inParked
              by_cases ofTurn : found.2 = some turn
              · exact .inl (.inr ⟨found, ⟨foundParked, ofTurn⟩, same⟩)
              · exact .inr ⟨found, ⟨foundParked, ofTurn⟩, same⟩
          · rintro ((inAnswers | ⟨found, ⟨foundParked, _⟩, same⟩) | ⟨found, ⟨foundParked, _⟩, same⟩)
            · exact .inl inAnswers
            · exact .inr (same ▸ List.mem_map_of_mem foundParked)
            · exact .inr (same ▸ List.mem_map_of_mem foundParked)
        · intro cancelledTurn inCancelled kept inKept
          simp only [List.mem_filter, bne_iff_ne, ne_eq] at inKept
          split at inCancelled
          · exact inv.cancelled cancelledTurn inCancelled kept inKept.1
          · rw [List.mem_append, List.mem_singleton] at inCancelled
            rcases inCancelled with inCancelled | isTurn
            · exact inv.cancelled cancelledTurn inCancelled kept inKept.1
            · exact isTurn ▸ inKept.2
        · intro closed
          exact absurd closed open'
  | close =>
    simp only [State.step] at stepped
    split at stepped
    · contradiction
    · cases stepped
      refine
        { outstanding := List.nodup_nil
          answers := ?_
          parked := List.nodup_nil
          apart := by simp
          asked := ?_
          cancelled := by simp
          closed := fun _ => rfl }
      · exact
          List.nodup_append.mpr
            ⟨inv.answers, inv.parked, fun a inA b inB same => inv.apart b inB (same ▸ inA)⟩
      · intro other
        simp only [List.mem_append, List.map_nil, List.not_mem_nil, or_false]
        exact inv.asked other

/-- Every reachable state keeps the invariant. -/
theorem Reachable.inv {state : State} : Reachable state → Inv state
  | .init => inv_init
  | .step reached stepped => inv_step reached.inv stepped

/-- Every response answers exactly one outstanding request (AC1a): in every
reachable state no request is outstanding twice; a response that the
protocol takes names an outstanding request and takes that one request out;
and a response to a request that is not outstanding is refused. -/
theorem respond_answers_exactly_one {state : State} (reached : Reachable state) :
    state.outstanding.Nodup ∧
      (∀ request after,
        state.step (.respond request) = some after →
          request ∈ state.outstanding ∧ after.outstanding = state.outstanding.erase request) ∧
      ∀ request, request ∉ state.outstanding → state.step (.respond request) = none := by
  refine ⟨reached.inv.outstanding, ?_, ?_⟩
  · intro request after stepped
    simp only [State.step] at stepped
    split at stepped
    · contradiction
    · rename_i outstanding
      rw [not_or, Classical.not_not] at outstanding
      cases stepped
      exact ⟨outstanding.2, rfl⟩
  · intro request missing
    simp only [State.step]
    split
    · rfl
    · rename_i outstanding
      rw [not_or, Classical.not_not] at outstanding
      exact absurd outstanding.2 missing

/-- Every parked request is answered exactly once (AC1b): in every reachable
state no ticket is answered twice and no parked ticket is answered; and once
the connection is closed, every ticket asked has been answered exactly
once. -/
theorem parked_answered_exactly_once {state : State} (reached : Reachable state) :
    state.answers.Nodup ∧
      (∀ entry ∈ state.parked, entry.1 ∉ state.answers) ∧
      (state.closed = true → ∀ ticket ∈ state.asked, state.answers.count ticket = 1) := by
  have inv := reached.inv
  refine ⟨inv.answers, fun entry inParked => inv.apart _ (List.mem_map_of_mem inParked), ?_⟩
  intro closed ticket inAsked
  have parkedNone := inv.closed closed
  have answered : ticket ∈ state.answers := by
    rcases (inv.asked ticket).mp inAsked with inAnswers | inParked
    · exact inAnswers
    · simp [parkedNone] at inParked
  rw [inv.answers.count]
  simp [answered]

/-- After a cancel, no permission request of that turn is still pending
(AC1c): in every reachable state, no parked request is of a cancelled turn,
which covers a request that arrives after the cancel. -/
theorem cancel_leaves_none_pending {state : State} (reached : Reachable state) :
    ∀ turn ∈ state.cancelled, ∀ entry ∈ state.parked, entry.2 ≠ some turn :=
  reached.inv.cancelled

/-! ## The axioms each theorem rests on

At most `propext`, `Classical.choice` and `Quot.sound`: `sorryAx`, or any
new axiom, changes a message below and fails the build. -/

/--
info: 'AgentsApiTest.Protocol.respond_answers_exactly_one' depends on axioms: [propext, Classical.choice, Quot.sound]
-/
#guard_msgs in
#print axioms respond_answers_exactly_one

/--
info: 'AgentsApiTest.Protocol.parked_answered_exactly_once' depends on axioms: [propext, Classical.choice, Quot.sound]
-/
#guard_msgs in
#print axioms parked_answered_exactly_once

/--
info: 'AgentsApiTest.Protocol.cancel_leaves_none_pending' depends on axioms: [propext, Classical.choice, Quot.sound]
-/
#guard_msgs in
#print axioms cancel_leaves_none_pending

end AgentsApiTest.Protocol
