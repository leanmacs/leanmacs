import Editor.Job
import Editor.Program
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Services
import Editor.Test.Linked.Trees
import Editor.Workspace
import Workspace.Finder
import WorkspaceTest.Check

/-!
# Linked tests: `Workspace/Finder.lean`

The tests of the workspace finder (`Workspace/Finder.lean`):
`workspaceChecks`, the finder over the real process and file services.
They were the contract test's (`ContractTest.workspaceChecks`,
`lean/ContractTest/Editor/Workspace/Finder.lean`, and before that
`lean/ContractTest/Editor/Workspace.lean`) while the workspaces were modules
of the core. The linked test's root, `WorkspaceTest/Linked.lean`, runs
them; its module doc says what each shows.
-/

namespace WorkspaceTest.Linked

open Editor
open Editor.Test.Linked

/-- Whether `Workspace.find`, with git standing in as the fixture under
`fixtures`, answers each directory of `asked` with its answer, over
`services`; and that every child it ran is reaped. -/
def findsThrough (services : Job.Services) (fixtures : System.FilePath)
    (asked : List (System.FilePath × Option Workspace.Found)) : IO Bool := do
  let before ← Editor.Test.Linked.pendingChildren
  let outcome ←
    runOnTimers services do
        let found ←
          asked.mapM fun (directory, _) =>
              Workspace.find { git := (fixtures / "git").toString } directory
        return found == asked.map (·.2)
  let reaped ← Editor.Test.Linked.childrenReapedTo services before
  return outcome == .finished true && reaped

/-- The tree of the workspace checks under `base`: a main checkout `main`,
whose `.git` is a directory, a worktree-shaped `wt`, whose `.git` is a file,
of the same common directory, each with a `src` directory and the git
fixture's file, and `plain`, which holds only `Cargo.toml` and a `src`
directory. -/
def writeWorkspaceTree (base : System.FilePath) : IO Unit := do
  IO.FS.createDirAll (base / "main" / ".git")
  IO.FS.createDirAll (base / "main" / "src")
  writeMaking (base / "main" / "fixture-git") s!"{base / "main"}\n{base / "main" / ".git"}\nmain\n"
  writeMaking (base / "wt" / ".git") s!"gitdir: {base / "main" / ".git" / "worktrees" / "wt"}\n"
  IO.FS.createDirAll (base / "wt" / "src")
  writeMaking (base / "wt" / "fixture-git") s!"{base / "wt"}\n{base / "main" / ".git"}\nfeature\n"
  writeMaking (base / "plain" / "Cargo.toml") ""
  IO.FS.createDirAll (base / "plain" / "src")

/-- What the workspace finder shows over the real process and file
services, with git standing in as the fixture under `fixtures`
(`tests/workspaces`): a main checkout and a worktree-shaped directory are
two workspaces of one project, as the models say. Each check works in a
temporary directory of its own, which it removes, and none sets a variable
of the test process or changes its working directory. -/
def workspaceChecks (services : Job.Services) (fixtures : System.FilePath) : List Check :=
  [{  name :=
        "over the real process and file services, a main checkout and a worktree-shaped directory resolve to two workspaces, with the fixture's branches, of one project identified by the common git directory; a directory with only a marker resolves through it"
      run :=
        withBase fun base => do
          writeWorkspaceTree base
          let commonDir := base / "main" / ".git"
          let project : Project :=
            { identity := .commonDir commonDir, name := "main", commonDir := some commonDir }
          findsThrough services fixtures
              [(base / "main" / "src",
                  some { root := base / "main", branch := some (.named "main"), project }),
                (base / "wt" / "src",
                  some { root := base / "wt", branch := some (.named "feature"), project }),
                (base / "plain" / "src", some (Workspace.Found.ofMarker (base / "plain")))] },
    { name :=
        "over the real process and file services, with an origin for each, the main checkout and the worktree-shaped directory share the project of the normalised origin"
      run :=
        withBase fun base => do
          writeWorkspaceTree base
          let origin := "git@github.com:o/r.git"
          writeMaking (base / "main" / "fixture-origin") s!"{origin}\n"
          writeMaking (base / "wt" / "fixture-origin") "https://github.com/o/r\n"
          let commonDir := base / "main" / ".git"
          let project (remote : String) : Project :=
            { identity := .remote "github.com/o/r", name := "r", remote := some remote
              commonDir := some commonDir }
          findsThrough services fixtures
              [(base / "main" / "src",
                  some
                    { root := base / "main", branch := some (.named "main"),
                      project := project origin }),
                (base / "wt" / "src",
                  some
                    { root := base / "wt", branch := some (.named "feature")
                      project := project "https://github.com/o/r" })] }]

end WorkspaceTest.Linked
