import AgentsApi.Policy

/-!
# What is proved of the permission policy

A policy cannot invent an answer (`AgentsApi/Policy.lean`): whatever it
decides, its answer to a request is none, which asks the user, or one of
the options that request offered. It holds of every policy, config's
among them, because a decision names an option only by its index into the
request's own options (`Decision.choose`), and the proof is by that type
alone. `lake build` checks them: the test library `AgentsApiTest` is a
default target of the package. Each theorem's axioms are pinned below it
(`#print axioms`), so a proof that came to need another axiom, `sorryAx`
among them, fails the build.

- `answer_offered`: every policy's answer is none or an offered option.
- `ask_asks`: the default policy answers none.
-/

namespace AgentsApiTest.AgentsApi.Policy

open _root_.AgentsApi

/-- Every policy's answer to a request is none, which asks, or one of the
options the request offered. -/
theorem answer_offered (policy : PermissionPolicy) (request : PermissionRequest) :
    policy.answer request = none ∨
      ∃ option ∈ request.options, policy.answer request = some option := by
  unfold PermissionPolicy.answer
  cases policy.decide request with
  | ask => exact .inl rfl
  | choose index => exact .inr ⟨request.options[index], Array.getElem_mem index.isLt, rfl⟩

/-- The default policy asks: it answers no option. -/
theorem ask_asks (request : PermissionRequest) : PermissionPolicy.ask.answer request = none :=
  rfl

/--
info: 'AgentsApiTest.AgentsApi.Policy.answer_offered' depends on axioms: [propext, Quot.sound]
-/
#guard_msgs in
#print axioms answer_offered

/--
info: 'AgentsApiTest.AgentsApi.Policy.ask_asks' depends on axioms: [propext, Quot.sound]
-/
#guard_msgs in
#print axioms ask_asks

end AgentsApiTest.AgentsApi.Policy
