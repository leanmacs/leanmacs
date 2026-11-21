import Editor.Config.Packages
import Editor.Extension
import ProjectApi

/-!
# The fake of `project-api`

A `ProjectApi.Workspaces` value that hands every continuation the workspace
a function given to it answers for the path (`fakeWith answer`), or one
workspace for every path (`fakeOver found`): `reach` records the answer as
the finder's for the path, under the config generation now, and hands the
continuation its root at once, with the carried arguments on its order, or
says its gone sentence for none; `work`, the continuation's find job, does
the same once it runs. It runs no finder. The package, named `workspace`, also registers stand-ins under the
interface's command names and its job. A consumer's tests register it in
place of the workspace feature.
-/

namespace ProjectApiTest

open Editor
open Editor.Workspace

/-- The workspace the fake hands every continuation by default: `/fake`, of
the project `fake`, on `main`. -/
def fakeFound : Workspace.Found :=
  { root := "/fake", branch := some (.named "main")
    project := { identity := .root "/fake", name := "fake" } }

/-- Records `answer`'s workspace for `order`'s path, under its generation, and
hands the continuation its root; says the continuation's gone sentence when
`answer` has none for the path. -/
def handOn (answer : System.FilePath → Option Workspace.Found) (continuation : Reach.Continuation)
    (order : Reach.Order) : EditorM Unit := do
  let found := answer order.path
  discard <| EditorState.ask (.recordWorkspace order.path order.generation found)
  match found with
  | some found =>
    continuation.reached order (.local found.root)
  | none =>
    message (continuation.gone order.path)

/-- The fake's `Workspaces` value over `answer`, the workspace it gives each
path, or none. -/
def workspacesWith (answer : System.FilePath → Option Workspace.Found) : ProjectApi.Workspaces :=
  { name := ProjectApi.implementationName
    reach := fun continuation path git view carried => do
      let (_, generation) ← RegistryRequest.ask .workspaceSettings
      handOn answer continuation { path, git, generation, view, carried }
    work := fun continuation arguments _ => do
      let some order := Reach.Order.ofArguments? arguments
        | throw s!"{continuation.job}: its arguments are not an order"
      return handOn answer continuation order }

/-- The fake's `Workspaces` value that gives every path `found`. -/
def workspacesOver (found : Workspace.Found) : ProjectApi.Workspaces :=
  workspacesWith fun _ => some found

/-- The fake over `answer`: its `Workspaces` value, and stand-ins under the
interface's command names, each saying it is the fake's, and its job, which
finishes with nothing. -/
def fakeWith (answer : System.FilePath → Option Workspace.Found) : Package :=
  { name := ProjectApi.implementationName
    setup := do
      for name in ProjectApi.names do
        command name (message s!"{name}: the fake finds nothing")
      for job in ProjectApi.jobs do
        workJob job fun _ _ => pure (pure ())
      Extension.add (workspacesWith answer) }

/-- The fake that gives every path `found`. -/
def fakeOver (found : Workspace.Found) : Package :=
  fakeWith fun _ => some found

/-- The fake over `fakeFound`. -/
def fake : Package :=
  fakeOver fakeFound

/-- The values registered at each extension point when only `values` are,
at `ProjectApi.Workspaces`: what a test hands a job registered over the
point (`JobRegistration.workWith`). -/
def workspacesValues (values : Array ProjectApi.Workspaces) (key : Lean.Name) : Array Dynamic :=
  if key == TypeName.typeName ProjectApi.Workspaces then values.map (.mk ·) else #[]

end ProjectApiTest
