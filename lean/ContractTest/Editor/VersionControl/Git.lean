import ContractTest.Check
import ContractTest.Support.Git
import Editor.Job
import Editor.Job.Runner
import Editor.Program
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Trees
import Editor.VersionControl
import Editor.VersionControl.Contract
import Editor.VersionControl.Git
import Editor.VersionControl.Model

/-!
# Contract tests: `Editor/VersionControl/Git.lean`

The tests of `Editor/VersionControl/Git.lean`: `versionControlChecks`, the git
implementation of the version-control interface over real git. The root module
`ContractTest` runs them; its module doc says what each shows.
-/

namespace ContractTest

open Editor
open Editor.Test.Linked

/-- The checks of the git implementation over real git of what the model has
no value for: a branch's change asked from each of two worktrees made with
git itself, files added with intent to add, which git alone makes, what to
watch in a linked worktree, and a commit's message, which the model does
not keep. -/
def versionControlChecks (services : Job.Services) : List Check :=
  [{  name :=
        "criterion 4: in a temporary repository whose linked worktree on feature committed a.txt modified, c.txt added and d.txt deleted, while main committed m.txt after they forked, changes asked from the linked worktree (HEAD against main) and from the main one (feature against main) each answer those three files with their old and new content, and fileAt of the base reads a.txt's old content"
      run :=
        withRepository fun home directory => do
          writeGitRepository home directory
              (VersionControlContract.clean #[("a.txt", "1\n"), ("b.txt", "b\n"), ("d.txt", "d\n")])
          let linked := directory.parent.getD directory / "feature"
          discard <|
              gitIn home directory #["worktree", "add", "-q", "-b", "feature", linked.toString]
          writeMaking (linked / "a.txt") "2\n"
          writeMaking (linked / "c.txt") "new\n"
          IO.FS.removeFile (linked / "d.txt")
          discard <| gitIn home linked #["add", "-A"]
          discard <|
              gitIn home linked #["-c", "commit.gpgsign=false", "commit", "-q", "-m", "feature"]
          writeMaking (directory / "m.txt") "m\n"
          discard <| gitIn home directory #["add", "-A"]
          discard <|
              gitIn home directory #["-c", "commit.gpgsign=false", "commit", "-q", "-m", "main"]
          let expected : Array VersionControl.FileChange :=
            #[{ path := "a.txt", old := some "1\n", new := some "2\n" },
              { path := "c.txt", old := none, new := some "new\n" },
              { path := "d.txt", old := some "d\n", new := none }]
          let asked (root : System.FilePath) (revision : String) : JobM Bool := do
            let handler := VersionControl.Git.handler "git" root
            match ← Program.runM handler (VersionControl.changes revision "main") with
            | .ok change =>
              return change.files == expected &&
                  (← Program.runM handler (VersionControl.fileAt change.base "a.txt")) ==
                    .ok (some "1\n")
            | .error _ =>
              return false
          let fromLinked ← runOnTimers (onIsolatedGit services home) (asked linked "HEAD")
          let fromMain ← runOnTimers (onIsolatedGit services home) (asked directory "feature")
          return fromLinked == .finished true && fromMain == .finished true },
    { name :=
        "in a linked worktree, watched names the main repository's git directory to watch, and HEAD and the index of the worktree's own git directory under it"
      run :=
        withRepository fun home directory => do
          writeGitRepository home directory (VersionControlContract.clean #[("a.txt", "a\n")])
          let linked := directory.parent.getD directory / "linked"
          discard <| gitIn home directory #["worktree", "add", "-q", "--detach", linked.toString]
          -- git spells the common directory as it found it, which may be
          -- through a link (a temporary directory's on macOS), so the
          -- answer is held to the names of what it names.
          let asked : JobM Bool := do
            match
              ← Program.runM (VersionControl.Git.handler "git" linked) VersionControl.watched with
            | .ok answer =>
              let common := answer.directory
              let own := common / "worktrees" / "linked"
              return common.toString.endsWith "/repo/.git" &&
                  answer.paths == #[own / "HEAD", own / "index", common / "packed-refs"] &&
                  answer.trees == #[common / "refs"]
            | .error _ =>
              return false
          return (← runOnTimers (onIsolatedGit services home) asked) == .finished true },
    { name :=
        "files moved in the working tree and added with intent to add, which git reads as renames in the working tree, read as each origin's unstaged deletion, joined with its staged change, and each new path's unstaged addition"
      run :=
        withRepository fun home directory => do
          writeGitRepository home directory
              { committed := #[("a.txt", "a\n"), ("b.txt", "b\n")]
                index := #[("a.txt", .file "a\n"), ("b.txt", .file "staged\n")]
                worktree := #[("a.txt", "a\n"), ("b.txt", "staged\n")] }
          IO.FS.rename (directory / "a.txt") (directory / "c.txt")
          IO.FS.rename (directory / "b.txt") (directory / "d.txt")
          discard <| gitIn home directory #["add", "-N", "--", "c.txt", "d.txt"]
          gitStatusIs (onIsolatedGit services home) directory
              { head := .branch "main"
                files :=
                  #[{ path := "a.txt", state := .changed none (some .deleted) },
                    { path := "b.txt", state := .changed (some .modified) (some .deleted) },
                    { path := "c.txt", state := .changed none (some .added) },
                    { path := "d.txt", state := .changed none (some .added) }] } },
    { name :=
        "a commit's message is the message given, a line that starts with # kept, under a user config whose commit.cleanup is strip"
      run :=
        withConfiguredRepository
          { committed := #[("a.txt", "one\n")], index := #[("a.txt", .file "two\n")]
            worktree := #[("a.txt", "two\n")] } fun home config directory => do
          let message := "Subject\n\n# kept\nbody\n"
          let committed : JobM Bool := do
            return (←
                  Program.runM (VersionControl.Git.handler "git" directory)
                      (VersionControl.commit message)) matches
                .ok ()
          let ran ← runOnTimers (onIsolatedGit services home config) committed
          let object ← gitIn home directory #["cat-file", "commit", "HEAD"]
          return ran == .finished true && object.endsWith s!"\n\n{message}" }]

end ContractTest
