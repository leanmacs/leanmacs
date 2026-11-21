import Editor.Extension
import Editor.Job
import Editor.ProjectMode.Listing

/-!
# The interface library `project-api`

The interface library `project-api`, staged in the core's Lake package as
its own `lean_lib` with the layout and names it will have as the package
`packages/project-api/` (`lean/lakefile.lean`, `lean_lib ProjectApi`): the
contract between the workspace feature (`Editor/Workspace/`), which
implements it, and what others ask of the project and workspace a path is
in. It imports only the core's API, and its test library (`ProjectApiTest`)
only that, this library and the core's test kit.

The project and the workspace a path is in are met three ways. For a path
whose workspace is known, the core's state answers
(`EditorState.workspaceOf?`, the workspace table). For one not found yet,
`Workspaces.reach` does. Attaching a buffer that takes in a file to its
workspace is the workspace's value at `files-api`'s hook `FilesApi.Opened`.

## What a caller builds

What a caller hands a reach, which keeps the names the workspace's reach
gave them (`Editor/Workspace/Reach.lean`): the order a find is started with
(`Workspace.Reach.Order`, with its codec, over the root codecs
`Workspace.rootArguments` and `Workspace.rootsOf?`), and the continuation
(`Workspace.Reach.Continuation`): what is done with the workspace reached,
the job its find runs under, the name it says a refused start under, and
what it says of a directory in no repository.

## Its extension point

**`Workspaces`, a choice** under `implementationName`, `workspace`, read
with `workspaces?`: `reach`, which hands a continuation the workspace at a
path, at once from the table's cache or through the continuation's job; and
`work`, the work of that job, which a caller registers under its
continuation's job name over this point (`Extension.workJob`). The latest
value of the name wins. With none a caller says so.

## Its names

`find-file-in-workspace` and `find-file-in-project`, which the default
config reaches, and the job `compile-list`, the core's
(`Compile.listJob`), which the core starts and the workspace registers.

Its test library publishes a fake (`ProjectApiTest.fake`, a `Workspaces`
value that hands every continuation a workspace given to it) and the
contract check every implementation runs (`ProjectApiTest.contractChecks`).
-/

namespace Editor.Workspace

/-- A config root as arguments: its path, then its project's name, or
`false` for none. -/
def rootArguments (root : ConfigRoot) : List Argument :=
  .str root.root.toString ::
    match root.project with
    | some project => [.str project]
    | none => [.bool false]

/-- The roots `arguments` are, if they are (`rootArguments`). -/
def rootsOf? : List Argument → Option (Array ConfigRoot)
  | [] => some #[]
  | .str root :: .str project :: rest =>
    (rootsOf? rest).map (#[{ root, project := some project }] ++ ·)
  | .str root :: .bool false :: rest => (rootsOf? rest).map (#[{ root }] ++ ·)
  | _ => none

namespace Reach

/-- What a find is started with: the directory, the git program, config's
roots, the config generation and the asking view. -/
structure Order where
  /-- The directory. -/
  path : System.FilePath
  /-- The git program. -/
  git : String
  /-- Config's workspace roots. -/
  roots : Array ConfigRoot := #[]
  /-- The config generation the answer is found under. -/
  generation : Nat
  /-- The view that asked. -/
  view : ViewId
  /-- Plain arguments the caller hands its own continuation through the find
  job. -/
  carried : List Argument := []
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with: the path, the git
program, the generation, the view, the count of the carried arguments and
they, then the roots. -/
def Order.arguments (order : Order) : List Argument :=
  [.str order.path.toString, .str order.git, .nat order.generation, .nat order.view.index,
      .nat order.carried.length] ++
    order.carried ++
    order.roots.toList.flatMap rootArguments

/-- The order `arguments` are, if they are one (`Order.arguments`). -/
def Order.ofArguments? : List Argument → Option Order
  | .str path :: .str git :: .nat generation :: .nat view :: .nat count :: rest =>
    if rest.length < count then none
    else
      (rootsOf? (rest.drop count)).map fun roots =>
        { path, git, roots, generation, view := ⟨view⟩, carried := rest.take count }
  | _ => none

/-- What a command does once it reaches a workspace, and how it says it could
not ("Reaching", in the module docs). -/
structure Continuation where
  /-- The name the find job is registered under. -/
  job : String
  /-- The name a refused start is said under. -/
  name : String
  /-- What is said of a directory in no repository. -/
  gone : System.FilePath → String
  /-- What is done with the workspace at the location, for the order. -/
  reached : Order → Location → EditorM Unit

end Reach

end Editor.Workspace

namespace ProjectApi

open Editor
open Editor.Workspace

/-- What the workspace feature does for others: a choice, under
`implementationName`. -/
structure Workspaces where
  /-- The value's name. -/
  name : String
  /-- Reaches the workspace at the path for the continuation, from the view,
  with the git program, handing the continuation the carried arguments on
  its order. -/
  reach : Reach.Continuation → System.FilePath → String → ViewId → List Argument → EditorM Unit
  /-- The work of the continuation's find job, given the arguments it is
  started with. -/
  work : Reach.Continuation → List Argument → Work
  deriving TypeName

/-- The name the workspace feature registers its `Workspaces` value under. -/
def implementationName : String :=
  "workspace"

/-- The `Workspaces` value of the implementation's name, the latest
registered; `none` when there is none. -/
def workspaces? : EditorM (Option Workspaces) :=
  Extension.named Workspaces (·.name) implementationName

/-- The value of the implementation's name among `values`, the latest: what a
job registered over the point reads. -/
def workspacesIn (values : Array Workspaces) : Option Workspaces :=
  values.findRev? (·.name == implementationName)

/-- The work of `continuation`'s find job over `values`, the values at the
point when it starts: the implementation's, or, with none, a work that
fails saying so. -/
def workOver (values : Array Workspaces) (continuation : Reach.Continuation)
    (arguments : List Argument) : Work :=
  match workspacesIn values with
  | some workspaces => workspaces.work continuation arguments
  | none => fun _ => throw s!"{continuation.job}: no workspace implementation"

/-- What a caller named `name` says when there is no `Workspaces` value. -/
def noImplementation (name : String) : String :=
  s!"{name}: no workspace implementation"

/-- The name of the command that finds a file in a workspace. -/
def findFileInWorkspaceName : String :=
  "find-file-in-workspace"

/-- The name of the command that finds a file in a workspace of the project. -/
def findFileInProjectName : String :=
  "find-file-in-project"

/-- The name of the job that lists a mode's computed commands: the core's
(`Compile.listJob`). -/
def compileListJob : String :=
  Compile.listJob

/-- Every command name this interface declares. -/
def names : Array String :=
  #[findFileInWorkspaceName, findFileInProjectName]

/-- Every job name this interface declares. -/
def jobs : Array String :=
  #[compileListJob]

end ProjectApi
