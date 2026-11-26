import AgentsApiTest.Check
import AgentsApiTest.Protocol

/-!
# Model tests: `AgentsApiTest/Protocol.lean`

The checks of the protocol's model (`AgentsApiTest.Protocol`): what `step`
takes and refuses, and what `replay` says of a trace. The theorems over
every reachable state are `AgentsApiTest/Protocol/Theorems.lean`'s; these
pin the steps one at a time, so a change to a rule fails a sentence that
says which.
-/

namespace AgentsApiTest

open AgentsApiTest.Protocol

/-- The state `actions` reach from the initial state, or `none` when a step
is refused. -/
private def after (actions : List Action) : Option State :=
  (replay actions).toOption

/-- A turn begun by the prompt `request` as turn `turn`. -/
private def prompt (request turn : Nat) : Action :=
  .send request (some turn)

/-- The checks of the protocol's model. -/
def protocolChecks : List Check :=
  [{  name := "a response to a request that is not outstanding is refused"
      run := do
        let refused := (State.init.step (.respond 1)).isNone
        let answeredTwice := (after [prompt 1 1, .respond 1, .respond 1]).isNone
        saw (refused && answeredTwice) s!"refused {refused}, answered twice {answeredTwice}" },
    { name :=
        "a response answers the one outstanding request it names, and a request already outstanding is not sent again"
      run := do
        let state := after [prompt 1 1, .send 2 none, .respond 1]
        let again := (after [prompt 1 1, prompt 1 2]).isNone
        saw (state.map (·.outstanding) == some [2] && again)
            s!"outstanding {repr (state.map (·.outstanding))}, sent again refused {again}" },
    { name :=
        "a parked permission request is answered once: a second answer, and an answer to a ticket never asked, are refused"
      run := do
        let once := after [prompt 1 1, .ask 1, .answer 1]
        let twice := (after [prompt 1 1, .ask 1, .answer 1, .answer 1]).isNone
        let unknown := (after [prompt 1 1, .answer 7]).isNone
        let asked := (after [prompt 1 1, .ask 1, .ask 1]).isNone
        saw
            (once.map (·.answers) == some [1] && once.map (·.parked) == some [] && twice &&
              unknown &&
              asked)
            s!"once {repr (once.map (·.answers))}, twice refused {twice}, unknown refused {unknown}, asked again refused {asked}" },
    { name :=
        "a cancel answers every parked request of the current turn, marks the turn cancelled and leaves another turn's"
      run := do
        let state := after [prompt 1 1, .ask 1, prompt 2 2, .ask 2, .ask 3, .cancel]
        saw
            (state.map (·.parked) == some [(1, some 1)] && state.map (·.answers) == some [2, 3] &&
              state.map (·.cancelled) == some [2])
            s!"{repr state}" },
    { name :=
        "a permission request that arrives after its turn's cancel is answered at once and never parked"
      run := do
        let state := after [prompt 1 1, .ask 1, .cancel, .ask 2]
        saw
            (state.map (·.parked) == some [] && state.map (·.answers) == some [1, 2] &&
              state.map (·.asked) == some [1, 2])
            s!"{repr state}" },
    { name :=
        "a close answers every parked request, as a dropped responder does, clears the outstanding requests and refuses every step after it"
      run := do
        let state := after [prompt 1 1, .ask 1, prompt 2 2, .ask 2, .close]
        let later := (after [prompt 1 1, .close, .ask 1]).isNone
        saw
            (state.map (·.parked) == some [] && state.map (·.answers) == some [1, 2] &&
              state.map (·.outstanding) == some [] &&
              state.map (·.closed) == some true &&
              later)
            s!"{repr state}, a step after the close refused {later}" },
    { name := "replay names the first step a trace breaks, and its index"
      run := do
        let broken := replay [prompt 1 1, .ask 1, .answer 1, .answer 1, .cancel]
        let held :=
          match broken with
          | .error violation => violation.index == 3 && violation.action == .answer 1
          | .ok _ => false
        saw held s!"{repr broken}" }]

end AgentsApiTest
