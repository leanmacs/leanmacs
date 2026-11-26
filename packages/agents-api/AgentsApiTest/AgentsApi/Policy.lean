import AgentsApi.Policy
import AgentsApiTest.Check
import Editor.Config.Packages

/-!
# Model tests: `AgentsApi/Policy.lean`

`policyChecks`: the permission policy, a choice by name at the extension
point `AgentsApi.PermissionPolicy`. The default asks; `Decision.ofKind` and
`Decision.ofId` choose the first offered option of a kind or an id and ask
when none is offered; a choice's answer is the request's own option at its
index; and the point's reader takes the latest of a name, none for a name
nobody registered. The theorems that no policy answers with an option the
request did not offer are built, not run
(`AgentsApiTest/AgentsApi/Policy/Theorems.lean`). The test driver's root,
`AgentsApiTest/Model.lean`, runs them.
-/

namespace AgentsApiTest

open Editor
open AgentsApi

/-- A request offering the adapter's three options, two of them of the kind
`allow_once`: `first`, then `second`, then `reject`. -/
def offering : PermissionRequest :=
  { agent := "claude-code", root := "/work/example", sessionId := "sess-0001", ticket := 1
    turn := some 1, call := { id := "call-edit-1", title := "Edit notes.txt", kind := "edit" }
    options :=
      #[{ id := "first", name := "Yes", kind := "allow_once" },
        { id := "second", name := "Yes again", kind := "allow_once" },
        { id := "reject", name := "No", kind := "reject_once" }] }

/-- The policies `packages` register, in registration order. -/
def registeredPolicies (packages : Array Package) : Array PermissionPolicy :=
  packages.flatMap fun package =>
    package.registered.extensions.filterMap fun (key, value) =>
      if key == TypeName.typeName PermissionPolicy then value.get? PermissionPolicy else none

/-- The checks of `AgentsApi/Policy.lean`. -/
def policyChecks : List Check :=
  [{  name := "the default policy is named default and asks: it answers no option"
      run := do
        let decided := PermissionPolicy.ask.decide offering
        saw
            (PermissionPolicy.ask.name == PermissionPolicy.defaultName &&
              PermissionPolicy.defaultName == "default" &&
              decided matches .ask &&
              PermissionPolicy.ask.answer offering == none)
            s!"{repr (PermissionPolicy.ask.answer offering)}" },
    { name :=
        "a decision by kind chooses the first offered option of that kind, and asks when none is offered"
      run := do
        let chosen := (Decision.ofKind offering "allow_once").option?
        let rejected := (Decision.ofKind offering "reject_once").option?
        let never := (Decision.ofKind offering "reject_always").option?
        saw
            ((chosen.map (·.id)) == some "first" && (rejected.map (·.id)) == some "reject" &&
              never == none)
            s!"chosen {repr chosen}, rejected {repr rejected}, never {repr never}" },
    { name :=
        "a decision by id chooses the offered option of that id, and asks for an id not offered"
      run := do
        let chosen := (Decision.ofId offering "second").option?
        let never := (Decision.ofId offering "allow-always").option?
        saw ((chosen.map (·.id)) == some "second" && never == none)
            s!"chosen {repr chosen}, never {repr never}" },
    { name := "a policy's answer is the request's own option at the index it chose"
      run := do
        let policy : PermissionPolicy :=
          { name := "last",
            decide := fun request =>
              if h : 0 < request.options.size then .choose ⟨request.options.size - 1, by omega⟩
              else .ask }
        let answer := policy.answer offering
        let none' := policy.answer { offering with options := #[] }
        saw (answer == offering.options[2]? && none' == none)
            s!"answer {repr answer}, with none offered {repr none'}" },
    { name :=
        "the permission policy is a choice by name: the latest of a name is chosen, a later policy of another name is not, and a name nobody registered has none"
      run := do
        let package (name : String) (policies : List PermissionPolicy) : Package :=
          { name, setup := policies.forM Extension.add }
        let byKind (name kind : String) : PermissionPolicy :=
          { name, decide := fun request => .ofKind request kind }
        let policies :=
          registeredPolicies
            #[package "a" [PermissionPolicy.ask],
              package "b"
                [byKind PermissionPolicy.defaultName "reject_once", byKind "other" "allow_once"]]
        let answerOf (name : String) :=
          (PermissionPolicy.choose policies name).map fun policy =>
            (policy.answer offering).map (·.id)
        saw
            (policies.size == 3 && answerOf PermissionPolicy.defaultName == some (some "reject") &&
              answerOf "other" == some (some "first") &&
              (PermissionPolicy.choose policies "nobody").isNone)
            s!"registered {policies.size}, default {answerOf PermissionPolicy.defaultName}, other {answerOf "other"}" }]

end AgentsApiTest
