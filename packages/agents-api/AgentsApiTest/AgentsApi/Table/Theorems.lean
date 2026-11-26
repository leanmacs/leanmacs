import AgentsApi.Table

/-!
# What is proved of the agent table

Activity never feeds attention (`AgentsApi/Table.lean`): a record's
attention reads only its pending tickets, its prompt on its way, its turn
in flight and its unread mark, so neither its work nor its stall changes
it, and the stall watchdog's verdict, which changes only the stall, keeps
it. `lake build` checks them: the test library `AgentsApiTest` is a
default target of the package. Each theorem's axioms are pinned below it
(`#print axioms`), so a proof that came to need another axiom, `sorryAx`
among them, fails the build.

- `attention_ignores_activity`: a record's work and stall do not change its
  attention.
- `stalled_keeps_attention`: the watchdog's verdict keeps a record's
  attention.
-/

namespace AgentsApiTest.AgentsApi.Table

open _root_.AgentsApi

/-- A record's work and stall do not change its attention. -/
theorem attention_ignores_activity (record : AgentRecord) (work : Array WorkItem) (stalled : Bool) :
    ({ record with
          work, stalled }).attention =
      record.attention :=
  rfl

/-- The stall watchdog's verdict keeps a record's attention. -/
theorem stalled_keeps_attention (record : AgentRecord) (heard : Nat) :
    (record.apply (.stalled heard)).attention = record.attention := by
  simp only [AgentRecord.apply]
  split <;> rfl

/--
info: 'AgentsApiTest.AgentsApi.Table.attention_ignores_activity' does not depend on any axioms
-/
#guard_msgs in
#print axioms attention_ignores_activity

/--
info: 'AgentsApiTest.AgentsApi.Table.stalled_keeps_attention' depends on axioms: [propext]
-/
#guard_msgs in
#print axioms stalled_keeps_attention

end AgentsApiTest.AgentsApi.Table
