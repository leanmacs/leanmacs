import Editor.Job
import Editor.Program
import Editor.Test.Linked.Jobs
import VcApi
import VcApiTest.Fake
import VcApiTest.Linked.Repositories
import VersionControl.Git

/-!
# Linked tests: support: Git

Real git as the version-control checks meet it: the config whose settings
the git implementation's command lines pin away, a repository written out
under it, and its status read by the git implementation. Git isolated from
the user's configuration and the writer of a repository are `vc-api`'s
linked test support (`VcApiTest/Linked/Repositories.lean`). A command with its own `PATH` is the
linked test kit's (`Editor/Test/Linked/Rig.lean`, `onChanged`). Shared by
several test modules; it holds no checks of its own.
-/

namespace VersionControlTest.Linked

open Editor
open Editor.Test.Linked
open VcApiTest.Linked

/-- A user's global git config asking for what the git implementation's
command line pins away (`VersionControl/Git.lean`, "The command
lines"): copies found as well as renames, by `status.renames` and by
`diff.renames`, and no untracked files listed; a commit's message
stripped of lines that start with `#`; and a patch's whitespace fixed and
its context matched loosely; and remote branches guessed for a new worktree
and every new branch tracking its start, neither of which may change what
is made; and every commit but `HEAD`'s ignored by blame, through
`blame.ignoreRevsFile` naming the writer's `<home>/ignore-revs`. It names a user, since no commit runs without
one and the writer's own does not reach the editor's runs, and turns
signing off. The editor runs git under the user's config, so the contract
runs it under this one. -/
def pinnedAwayConfig : String :=
  "[status]\n\trenames = copies\n\tshowUntrackedFiles = no\n[diff]\n\trenames = copies\n" ++
    "[worktree]\n\tguessRemote = true\n[branch]\n\tautoSetupMerge = always\n" ++
    "[user]\n\tname = a\n\temail = a@example.com\n" ++
    "[commit]\n\tgpgSign = false\n\tcleanup = strip\n" ++
    "[apply]\n\twhitespace = fix\n\tignoreWhitespace = change\n" ++
    "[blame]\n\tignoreRevsFile = ~/ignore-revs\n"

/-- `check` handed a home holding `pinnedAwayConfig` as the file `gitconfig`,
whose path it is also handed, and a repository directory, both its own
(`withRepository`), with `repository` written out in the directory. A
commit needs the config's user: git run without one would guess an address
from the host's name, and fails where that has no domain. -/
def withConfiguredRepository {α : Type} (repository : VersionControl.Model.Repository)
    (check : System.FilePath → System.FilePath → System.FilePath → IO α) : IO α :=
  withRepository fun home directory => do
    writeGitRepository home directory repository
    let config := home / "gitconfig"
    IO.FS.writeFile config pinnedAwayConfig
    check home config directory

/-- Whether the git implementation reads the status of the repository at
`directory` as `expected`, over `services`. -/
def gitStatusIs (services : Job.Services) (directory : System.FilePath)
    (expected : VersionControl.Status) : IO Bool := do
  let read : JobM Bool := do
    return (← Program.runM (VersionControl.Git.handler "git" directory) VersionControl.status) ==
        .ok expected
  return (← runOnTimers services read) == .finished true

end VersionControlTest.Linked
