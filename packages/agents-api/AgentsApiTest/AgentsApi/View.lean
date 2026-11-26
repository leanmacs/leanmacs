import AgentsApi.View
import AgentsApiTest.Check
import Editor.Config.Packages

/-!
# Model tests: `AgentsApi/View.lean`

`viewChecks`: the extension point `ConversationView` is a choice by name,
the latest of a name chosen, and none for a name nobody registered, read
from what packages register (`Package.registered`). The test driver's root,
`AgentsApiTest/Model.lean`, runs them.
-/

namespace AgentsApiTest

open Editor
open AgentsApi

/-- A view named `name` whose every field gives the one line `line`. -/
def lineView (name line : String) : ConversationView :=
  { name, header := fun _ => #[line], prompt := fun _ => #[line], message := fun _ => #[line]
    toolCall := fun _ _ => #[line], permission := fun _ _ _ _ => #[line]
    turnEnded := fun _ _ => #[line], note := fun _ => #[line], queued := fun _ _ => #[line] }

/-- The views `packages` register, in registration order. -/
def registeredViews (packages : Array Package) : Array ConversationView :=
  packages.flatMap fun package =>
    package.registered.extensions.filterMap fun (key, value) =>
      if key == TypeName.typeName ConversationView then value.get? ConversationView else none

/-- The checks of `AgentsApi/View.lean`. -/
def viewChecks : List Check :=
  [{  name :=
        "the conversation view is a choice by name: the latest view of the default name is chosen, a later view of another name is not, and a name nobody registered has none"
      run := do
        let package (name : String) (views : List ConversationView) : Package :=
          { name, setup := views.forM Extension.add }
        let views :=
          registeredViews
            #[package "a" [lineView ConversationView.defaultName "first"],
              package "b"
                [lineView ConversationView.defaultName "second", lineView "other" "other"]]
        let chosen := (ConversationView.choose views).map fun view => view.note ""
        saw
            (views.size == 3 && chosen == some #["second"] &&
              ((ConversationView.choose views "other").map fun view => view.note "") ==
                some #["other"] &&
              (ConversationView.choose views "nobody").isNone)
            s!"registered {views.size}, chosen {chosen}" }]

end AgentsApiTest
