import Editor.Api
import Editor.Job
import ProjectApi
import Workspace.Attach

/-!
# Reaching the workspace at a path

A command that wants the workspace of a directory the table may not know
yet, such as a worktree of the focused workspace's repository, reaches it
here and is handed it by its continuation (`Continuation`): what it does
with the workspace's location, the job its find runs under, the name it
says a refused start under, and what it says of a directory in no
repository. `vc-worktrees-visit` (`Editor/VersionControl/Worktrees.lean`)
and `find-file-in-project` (`Workspace/FindInProject.lean`) are its
two continuations. Written over the editor API (`Editor/Api.lean`), the job
port (`Editor/Job.lean`) and the finder, as `Workspace/Attach.lean`
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
  (`Order`): the path, the git program, config's roots, the generation, the
  view and the arguments the caller carries (`reach`'s `carried`), as plain
  arguments, the carried ones after their count. A start that is refused is
  said as `<name>: <refusal>`.

The continuation is handed the order in every case, so what a caller
carries reaches it whether or not a job ran: `find-file-in-project` carries
the text typed in the file finder it stepped out of.

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

The order and the continuation are the interface library `project-api`'s
(`ProjectApi.lean`), which callers in other features build, and the
workspace package registers `reach` and `work` as its `ProjectApi.Workspaces`
value, which they reach it through.

Pinned by `WorkspaceTest.reachChecks`, on the loop's driver over the editor's
models and the job model, with a probe continuation; each caller's checks
pin its messages; and by `project-api`'s contract, which
`WorkspaceTest.workspacePackageChecks` runs over the workspace package.
-/

namespace Editor.Workspace.Reach

/-- Reaches the workspace at `path` for `continuation`, from `view`, with the
git program `git`, handing the continuation `carried` on its order
("Reaching", in the module docs). -/
def reach (continuation : Continuation) (path : System.FilePath) (git : String) (view : ViewId)
    (carried : List Argument := []) : EditorM Unit := do
  let (settings, generation) ← RegistryRequest.ask .workspaceSettings
  let order : Order := { path, git, roots := settings.roots, generation, view, carried }
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
