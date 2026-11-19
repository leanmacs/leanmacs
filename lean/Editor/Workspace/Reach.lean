import Editor.Api
import Editor.Job
import Editor.Workspace.Attach

/-!
# Reaching the workspace at a path

A command that wants the workspace of a directory the table may not know
yet, such as a worktree of the focused workspace's repository, reaches it
here and is handed it by its continuation (`Continuation`): what it does
with the workspace's location, the job its find runs under, the name it
says a refused start under, and what it says of a directory in no
repository. `vc-worktrees-visit` (`Editor/VersionControl/Worktrees.lean`)
and `find-file-in-project` (`Editor/Workspace/FindInProject.lean`) are its
two continuations. Written over the editor API (`Editor/Api.lean`), the job
port (`Editor/Job.lean`) and the finder, as `Editor/Workspace/Attach.lean`
runs it.

## Reaching

`reach`, given the path, the git program and the asking view, asks the
loop for the workspace settings (`RegistryRequest.workspaceSettings`):
config's roots and the config generation. Then, on the table's cached
answer for the path under that generation (`Workspace.Table.cached?`):

- **A workspace**: the continuation is handed its location at once, and no
  job starts.
- **None**, a directory found to be in no repository: the continuation's
  gone sentence is said.
- **No answer**: the continuation's job is started, unkeyed, with an order
  (`Order`): the path, the git program, config's roots, the generation and
  the view, as plain arguments. A start that is refused is said as
  `<name>: <refusal>`.

## The job and its command

- **The job** (`work`, registered under the continuation's job name) runs
  the finder (`Workspace.find`) on the order's path with the order's
  settings. It fails only for arguments that are not an order.
- **Its command** (`found`) records the answer (`recordWorkspace`), as a
  file's open records it, so the workspace's identity, branch and store are
  the finder's, and caches it. Then the continuation is handed the root
  found, or its gone sentence is said.

Each continuation registers its own job name over `work`: a job is started
by name with plain arguments, and the continuation is code, which arguments
cannot carry. One name would need this module to know its callers, or the
continuation to be a command run by name.

Pinned by `ModelTest.reachChecks`, on the loop's driver over the editor's
models and the job model, with a probe continuation; each caller's checks
pin its messages.
-/

namespace Editor.Workspace.Reach

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
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with. -/
def Order.arguments (order : Order) : List Argument :=
  [.str order.path.toString, .str order.git, .nat order.generation, .nat order.view.index] ++
    order.roots.toList.flatMap rootArguments

/-- The order `arguments` are, if they are one (`Order.arguments`). -/
def Order.ofArguments? : List Argument → Option Order
  | .str path :: .str git :: .nat generation :: .nat view :: roots =>
    (rootsOf? roots).map fun roots => { path, git, roots, generation, view := ⟨view⟩ }
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

/-- Reaches the workspace at `path` for `continuation`, from `view`, with the
git program `git` ("Reaching", in the module docs). -/
def reach (continuation : Continuation) (path : System.FilePath) (git : String) (view : ViewId) :
    EditorM Unit := do
  let (settings, generation) ← RegistryRequest.ask .workspaceSettings
  let order : Order := { path, git, roots := settings.roots, generation, view }
  match (← editorState).workspaces.cached? path generation with
  | some (some location) =>
    continuation.reached order location
  | some none =>
    message (continuation.gone path)
  | none =>
    if let .error refusal← startJob continuation.job order.arguments then
      message s!"{continuation.name}: {refusal.describe}"

/-- The command a finished find hands the loop ("The job and its command", in
the module docs): the answer recorded, then the continuation handed the root
found, or its gone sentence said. -/
def found (continuation : Continuation) (order : Order) (answer : Option Found) : EditorM Unit := do
  discard <| EditorState.ask (.recordWorkspace order.path order.generation answer)
  match answer with
  | some found =>
    continuation.reached order (.local found.root)
  | none =>
    message (continuation.gone order.path)

/-- The find job of `continuation`: runs the finder on its order's path with
its order's settings, and finishes with `found`. It fails only for arguments
that are not an order. -/
def work (continuation : Continuation) (arguments : List Argument) : Work := fun _ => do
  let some order :=
    Order.ofArguments? arguments | throw s!"{continuation.job}: its arguments are not an order"
  return found continuation order (← find { roots := order.roots, git := order.git } order.path)

end Editor.Workspace.Reach
