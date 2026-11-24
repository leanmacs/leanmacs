import Editor.Job
import Editor.Program
import Editor.RealHost
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Trees
import VcApi
import VcApiTest.Contract
import VcApiTest.Fake
import VersionControl.Git
import VersionControlTest.Check
import VersionControlTest.Git.Model
import VersionControlTest.Linked.Support.Git
import VersionControlTest.Linked.VersionControl.Lanes

/-!
# Linked tests: `VersionControl/Git.lean`

The tests of `VersionControl/Git.lean`: `versionControlChecks`, the git
implementation of the version-control interface over real git, and
`versionControlContractChecks`, the contract of the interface
library `vc-api` (`VcApiTest/Contract.lean`) run against the git
implementation over real git, the implementation version control registers
as `vc-api`'s backend (D7 (c): `vc-api` keeps the model's run,
`VcApiTest.versionControlContractFailures`, in `vc-api`). The linked test's root,
`VersionControlTest/Linked.lean`, runs them; its module doc says what each
shows.

It runs a port's contract against its real adapter, outside the rule of the
wiring set (`docs/dev-practices/real-thread-checks.md`): it declares
`.contract` because its root hands it the real services (W44).
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.VersionControlTest.Linked.VersionControl.Git : Editor.WiringSet :=
  .contract "VersionControlContract against real git"

namespace VersionControlTest.Linked

open Editor
open Editor.Test.Linked
open VcApiTest.Linked

/-- The checks of the git implementation over real git of what the model has
no value for: a branch's change asked from each of two worktrees made with
git itself, files added with intent to add, which git alone makes, what to
watch in a linked worktree, and a commit's message, which the model does
not keep. -/
def versionControlChecks (services : Job.Services) : List Check :=
  [{  name :=
        "criterion 4: in a temporary repository whose linked worktree on feature committed a.txt modified, c.txt added and d.txt deleted, while main committed m.txt after they forked, changes asked from the linked worktree (HEAD against main) and from the main one (feature against main) each answer those three files with their old and new content, and fileAt of the base reads a.txt's old content"
      run :=
        withRepository services fun home directory => do
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
        withRepository services fun home directory => do
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
        withRepository services fun home directory => do
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
        withConfiguredRepository services
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

/-- The version-control contract's properties
(`VersionControl/Contract.lean`) against the git implementation over the
library's process service, as one check: each property's repository
written out with real git in a temporary directory and home of its own
(`writeGitRepository`), every child's git kept from the system's config
and given `pinnedAwayConfig` as the user's (`onIsolatedGit`). Each
property's directory is removed only once the process and file services
have worked what was handed to them (`withRepository`, a flushed bracket);
that each child is reaped is the process service's own contract
(`ContractTest.processFailures`), not pinned here. The properties run
`versionControlLanes` at a time (`inLanes`, `Lanes.lean`), and the check
fails through `saw` with the name and outcome of each that does not hold,
in the contract's order. Property 1 is the phase's adapter test of git
against the model. -/
def versionControlContractChecks (services : Job.Services) : List Check :=
  [{  name :=
        s!"the version-control interface's contract holds over git, its {VersionControlContract.properties.length} properties in {versionControlLanes} lanes"
      run := do
        let outcomes ←
          inLanes versionControlLanes VersionControlContract.properties (failed :=
              fun property error => some s!"{property.name} ({error})") fun property =>
              withRepository services fun home directory => do
                try
                  writeGitRepository home directory property.repository
                  let config := home / "gitconfig"
                  IO.FS.writeFile config pinnedAwayConfig
                  let outcome ←
                    runOnTimers (onIsolatedGit services home config)
                        (property.holds.runM (VersionControl.Git.handler "git" directory))
                  return if outcome == .finished true then none
                    else some s!"{property.name} ({repr outcome})"
                catch error =>
                  return some s!"{property.name} (writing its repository: {error})"
        let failed := outcomes.filterMap id
        saw failed.isEmpty s!"{failed.map (s!"the version-control interface over git: {·}")}" }]

end VersionControlTest.Linked
