import ContractTest.Check
import ContractTest.Support.Git
import ContractTest.Support.Jobs
import ContractTest.Support.Trees
import Editor.Ffi.Processes
import Editor.Job
import Editor.Job.Runner
import Editor.Process
import Editor.Workspace.FindFile
import Editor.Workspace.Lister

/-!
# Contract tests: `Editor/Workspace/Lister.lean`

The tests of `Editor/Workspace/Lister.lean`: `workspaceListerChecks`, git's
lister and the fallback run by the finder's source (`FindFile.found`) over
the real process service, with real git and find, and the fixture that
stands for fzf (`tests/completion/filter`). The root module `ContractTest`
runs them; its module doc says what each shows.
-/

namespace ContractTest

open Editor

/-- Whether the records `lister` lists at `root`, filtered by the fixture
filter under `fixtures` with the empty text, which keeps them all, as
`FindFile.found` answers them over `services`, are `expected` as a set
(both sorted), and every child it ran was reaped. -/
def listsAt (services : Job.Services) (fixtures : System.FilePath) (lister : Workspace.Lister)
    (root : System.FilePath) (expected : Array String) : IO Bool := do
  let before ← Ffi.processesPending
  let separator : Completion.Filtering.Separator := if lister.nul then .nul else .newline
  let filter : Process.Command :=
    { program := (fixtures / "filter").toString
      arguments :=
        match separator with
        | .nul => #["--read0", "--print0", "--filter"]
        | .newline => #["--filter"]
      directory := root }
  let outcome ←
    runOnTimers services do
        match
          ←
            Workspace.FindFile.found (Workspace.FindFile.filtering lister root filter) lister
                "" with
        | .ok records =>
          return records.qsort (· < ·) == expected.qsort (· < ·)
        | .error _ =>
          return false
  let reaped ← eventually (return (← Ffi.processesPending) == before)
  return outcome == .finished true && reaped

/-- The global git config of the checks, at `home/config`: its excludes file
is `home/ignore`, which ignores `*.log`. -/
def withGlobalExcludes (home : System.FilePath) : IO System.FilePath := do
  writeMaking (home / "ignore") "*.log\n"
  writeMaking (home / "config") s!"[core]\n\texcludesFile = {home / "ignore"}\n"
  return home / "config"

/-- What git's lister and the fallback list over the real process service,
with real git and find and the fixture under `fixtures` (`tests/completion`)
standing for fzf. Each check works in a temporary directory of its own,
which it removes; git is isolated from the user's config (`onIsolatedGit`),
and none sets a variable of the test process or changes its working
directory. -/
def workspaceListerChecks (services : Job.Services) (fixtures : System.FilePath) : List Check :=
  [{  name :=
        "git's lister, run at a repository's root over the real process service, lists its tracked files and its untracked files that no ignore rule names: none that .gitignore, info/exclude or the global excludes file ignore"
      run :=
        withRepository fun home directory => do
          let global ← withGlobalExcludes home
          discard <| gitIn home directory #["init", "-q", "-b", "main"]
          writeMaking (directory / "a.txt") "a\n"
          writeMaking (directory / "src" / "b.txt") "b\n"
          writeMaking (directory / ".gitignore") "build/\n"
          discard <| gitIn home directory #["add", "a.txt", "src/b.txt", ".gitignore"]
          discard <|
              gitIn home directory #["-c", "commit.gpgsign=false", "commit", "-q", "-m", "first"]
          writeMaking (directory / "c.txt") "c\n"
          writeMaking (directory / "build" / "x.o") "x\n"
          writeMaking (directory / ".git" / "info" / "exclude") "secret.txt\n"
          writeMaking (directory / "secret.txt") "s\n"
          writeMaking (directory / "debug.log") "d\n"
          listsAt (onIsolatedGit services home global) fixtures (.git "git") directory
              #[".gitignore", "a.txt", "c.txt", "src/b.txt"] },
    { name :=
        "git's lister lists a linked worktree's files at its own root and not at the main checkout's: a file committed only on the worktree's branch is listed there alone"
      run :=
        withRepository fun home directory => do
          discard <| gitIn home directory #["init", "-q", "-b", "main"]
          writeMaking (directory / "a.txt") "a\n"
          discard <| gitIn home directory #["add", "a.txt"]
          discard <|
              gitIn home directory #["-c", "commit.gpgsign=false", "commit", "-q", "-m", "first"]
          let linked := directory.parent.getD directory / "feature"
          discard <|
              gitIn home directory #["worktree", "add", "-q", "-b", "feature", linked.toString]
          writeMaking (linked / "only-feature.txt") "f\n"
          discard <| gitIn home linked #["add", "only-feature.txt"]
          discard <|
              gitIn home linked #["-c", "commit.gpgsign=false", "commit", "-q", "-m", "feature"]
          let isolated := onIsolatedGit services home
          let atMain ← listsAt isolated fixtures (.git "git") directory #["a.txt"]
          let atLinked ←
            listsAt isolated fixtures (.git "git") linked #["a.txt", "only-feature.txt"]
          return atMain && atLinked },
    { name :=
        "the fallback, find . -type f -not -path */.git/* -print0 over the real process service, lists a directory's files without ./ and none under a .git directory"
      run :=
        withBase fun base => do
          writeMaking (base / "a") "a\n"
          writeMaking (base / "d" / "e") "e\n"
          writeMaking (base / "x" / ".git" / "config") "c\n"
          listsAt services fixtures .fallback base #["a", "d/e"] }]

end ContractTest
