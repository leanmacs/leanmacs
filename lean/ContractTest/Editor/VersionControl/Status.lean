import ContractTest.Check
import ContractTest.Support.Git
import ContractTest.Support.Jobs
import ContractTest.Support.Projects
import ContractTest.Support.Trees
import ContractTest.Support.VersionControl
import Editor.Api
import Editor.Clipboard
import Editor.Command
import Editor.Command.Real
import Editor.Config.Registry
import Editor.Ffi.Snapshot
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Real
import Editor.Job.Runner
import Editor.Loop
import Editor.State
import Editor.SyntaxTree
import Editor.Text
import Editor.Text.Real
import Editor.VersionControl
import Editor.VersionControl.Commit
import Editor.VersionControl.Contract
import Editor.VersionControl.Model
import Editor.VersionControl.Show
import Editor.VersionControl.Stage
import Editor.VersionControl.Status
import Editor.VersionControl.Worktrees
import Editor.Watch

/-!
# Contract tests: `Editor/VersionControl/Status.lean`

The tests of `Editor/VersionControl/Status.lean`: `statusBufferChecks`: the
status buffer, the worktree list, `vc-show` and the other version-control
commands over real git. The root module `ContractTest` runs them; its module doc
says what each shows.
-/

namespace ContractTest

open Editor

/-- `loop`, over `texts`, once each job of `queue` has run, and every job
their commands start, oldest first, as the model's driver settles
(`ModelTest.settledOn`): each spawned on the rig's services with its posts
collected, waited for, then each post delivered and then its command, with
`keys`, and the jobs those start queued behind the rest. So two commands'
pipelines run interleaved, a step of each in turn, where `settleProjects`
runs each to its end. `none` when a job did not end in time or ended
otherwise than finished, a delivery answered a prompt or was refused, or
more than `depth` jobs ran. -/
partial def settleQueued (rig : ProjectRig) (texts : RealTexts) (loop : Loop TestScheme.scheme)
    (queue : List JobStart) (keys : Loop.Keys TestScheme.scheme)
    (jobs : Array Config.JobRegistration) (depth : Nat := 32) :
    IO (Option (Loop TestScheme.scheme × RealTexts)) := do
  match queue with
  | [] =>
    return some (loop, texts)
  | start :: rest =>
    if depth == 0 then
      return none
    let some work := (jobs.find? (·.name == start.name)).map (·.work start.arguments) | return none
    let posts ← IO.mkRef (#[] : Array Invocation)
    let handle ←
      Job.spawn rig.services work (pure ()) fun invocation => posts.modify (·.push invocation)
    unless ← eventually handle.ended do
      handle.cancel
      return none
    let label := s!"job {start.name}"
    let mut loop := loop
    let mut texts := texts
    let mut queued := rest
    for invocation in ← posts.get do
      let (next, after) ← (loop.deliver keys label (runPosted invocation)).runReal texts rig.display
      let .ok next := next | return none
      unless next.answered.isEmpty do
        return none
      loop := next.loop
      texts := after
      queued := queued ++ next.starts.toList
    let some (.finished command) ← handle.outcome? | return none
    let (next, after) ←
      Job.finishWith rig.held handle (loop.deliver keys label command) texts rig.display
    let .ok next := next | return none
    unless next.answered.isEmpty do
      return none
    settleQueued rig after next.loop (queued ++ next.starts.toList) keys jobs (depth - 1)

/-- The invocation that makes the window's text `text`. -/
def setText (text : String) : Invocation :=
  { command := "set-text", arguments := [.str text] }

/-- The checks of the status buffer (`Editor/VersionControl/Status.lean`),
of the worktree list (`Editor/VersionControl/Worktrees.lean`), of `vc-show`, of staging a hunk (`Editor/VersionControl/Stage.lean`) and of
the message buffer (`Editor/VersionControl/Commit.lean`) over real git: their
jobs run over the library's process, file and diff services in a temporary
repository, the real finder recording the workspace, every child's git kept
from the user's and the system's config. A check that commits runs git
under `pinnedAwayConfig` (`withConfiguredRepository`), whose user a commit
needs. -/
def statusBufferChecks (services : Job.Services) : List Check :=
  [{  name :=
        "criteria 1 and 2 over real git: in a repository with a worktree on feature holding a changed file, vc-worktrees lists both with their branches, and visiting feature's row opens *vc-status: repo@feature* naming that file"
      run :=
        withRepository fun home directory => do
          writeGitRepository home directory (VersionControlContract.clean #[("a.txt", "one\n")])
          let linked := directory.parent.getD directory / "feature"
          discard <|
              gitIn home directory #["worktree", "add", "-q", "-b", "feature", linked.toString]
          writeMaking (linked / "a.txt") "two\n"
          let rig ← ProjectRig.over (onIsolatedGit services home)
          let some (listed, texts) ←
            runSettled rig directory
                [openFile (directory / "a.txt"), { command := VersionControl.worktreesName }]
                statusKeys statusJobs | return false
          let list ← bufferText rig texts listed "*vc-worktrees: repo@main*"
          let some (visited, texts) ←
            runSettledFrom rig listed texts
                [toRow 2, { command := VersionControl.worktreesVisitName }] statusKeys
                statusJobs | return false
          let status ← bufferText rig texts visited "*vc-status: repo@feature*"
          return list ==
                some s!"repo@main: worktrees\nmain: {directory} (this one)\nfeature: {linked}\n" &&
              status == some "repo@feature: on feature\nunstaged: a.txt (modified)\n" },
    { name :=
        "criteria 2 to 4 over real git: vc-status in a file of a repository with a.txt changed and b.txt staged shows one line for each naming its state; toggling on a.txt's line stages it in git and its line then says so, and toggling on b.txt's line unstages it in git"
      run :=
        withRepository fun home directory => do
          writeGitRepository home directory
              { committed := #[("a.txt", "one\n"), ("b.txt", "one\n")]
                index := #[("a.txt", .file "one\n"), ("b.txt", .file "two\n")]
                worktree := #[("a.txt", "two\n"), ("b.txt", "two\n")] }
          let isolated := onIsolatedGit services home
          let rig ← ProjectRig.over isolated
          let name := "*vc-status: repo@main*"
          let some (shown, texts) ←
            runSettled rig directory
                [openFile (directory / "a.txt"), { command := VersionControl.statusName }]
                statusKeys statusJobs | return false
          let first ← bufferText rig texts shown name
          let some (staged, texts) ←
            runSettledFrom rig shown texts [toRow 1, { command := VersionControl.toggleName }]
                statusKeys statusJobs | return false
          let afterStage ←
            gitStatusIs isolated directory
                { head := .branch "main"
                  files :=
                    #[{ path := "a.txt", state := .changed (some .modified) none },
                      { path := "b.txt", state := .changed (some .modified) none }] }
          let second ← bufferText rig texts staged name
          let some (_, _) ←
            runSettledFrom rig staged texts [toRow 2, { command := VersionControl.toggleName }]
                statusKeys statusJobs | return false
          let afterUnstage ←
            gitStatusIs isolated directory
                { head := .branch "main"
                  files :=
                    #[{ path := "a.txt", state := .changed (some .modified) none },
                      { path := "b.txt", state := .changed none (some .modified) }] }
          return first ==
                some "repo@main: on main\nunstaged: a.txt (modified)\nstaged: b.txt (modified)\n" &&
              afterStage &&
              second ==
                some "repo@main: on main\nstaged: a.txt (modified)\nstaged: b.txt (modified)\n" &&
              afterUnstage },
    { name :=
        "criterion 2 over real git: vc-show v1 a.txt, in a.txt of a repository with the tag v1, opens a read-only buffer a.txt@v1 holding what v1 holds, with no file; and with no text the file at HEAD"
      run :=
        withRepository fun home directory => do
          writeGitRepository home directory
              { VersionControlContract.clean #[("a.txt", "now\n")] with
                revisions := #[("v1", #[("a.txt", "then\n")])] }
          let rig ← ProjectRig.over (onIsolatedGit services home)
          let some (shown, texts) ←
            runSettled rig directory
                [openFile (directory / "a.txt"),
                  { command := VersionControl.showName, arguments := [.str "v1 a.txt"] },
                  openFile (directory / "a.txt"), { command := VersionControl.showName }]
                statusKeys statusJobs | return false
          let some old := shown.state.findBuffer "a.txt@v1" | return false
          let some head := shown.state.findBuffer "a.txt@HEAD" | return false
          return (← bufferText rig texts shown "a.txt@v1") == some "then\n" &&
              (← bufferText rig texts shown "a.txt@HEAD") == some "now\n" &&
              (shown.state.buffer? old).map (·.readOnly) == some true &&
              ((shown.state.buffer? old).bind (·.file)).isNone &&
              ((shown.state.buffer? head).bind (·.file)).isNone },
    { name :=
        "criterion 1 through vc-stage-hunk over real git: on a line of the second of two changed hunks, in a buffer with unsaved changes, the buffer is saved and that hunk alone is staged"
      run :=
        withConfiguredRepository
          (VersionControlContract.writing
            (VersionControlContract.clean #[("a.txt", VersionControlContract.tenLines)]) "a.txt"
            VersionControlContract.secondChanged)
          fun home config directory => do
          let isolated := onIsolatedGit services home config
          let rig ← ProjectRig.over isolated
          let some (_, _) ←
            runSettled rig directory
                [openFile (directory / "a.txt"), setText VersionControlContract.twoChanged, toRow 8,
                  { command := VersionControl.stageHunkName }]
                statusKeys statusJobs | return false
          let index ← gitIn home directory #["show", ":a.txt"]
          let written ← IO.FS.readFile (directory / "a.txt")
          let state ←
            gitStatusIs isolated directory
                { head := .branch "main"
                  files :=
                    #[{ path := "a.txt", state := .changed (some .modified) (some .modified) }] }
          return index ==
                VersionControlContract.lineSet VersionControlContract.tenLines 8 "nine\n" &&
              written == VersionControlContract.twoChanged &&
              state },
    { name :=
        "vc-stage-hunk pressed twice on a line before the first has staged, over real git: both take the same hunk, the first stages it, git refuses the second, which is said, and the index holds the hunk once"
      run :=
        withConfiguredRepository
          (VersionControlContract.writing
            (VersionControlContract.clean #[("a.txt", VersionControlContract.tenLines)]) "a.txt"
            VersionControlContract.twoChanged)
          fun home config directory => do
          let rig ← ProjectRig.over (onIsolatedGit services home config)
          let some (opened, texts) ←
            runSettled rig directory [openFile (directory / "a.txt"), toRow 8] statusKeys
                statusJobs | return false
          let press : Invocation := { command := VersionControl.stageHunkName }
          let (first, texts) ← (opened.invoke statusKeys press).runReal texts rig.display
          let .ok first := first | return false
          let (second, texts) ← (first.loop.invoke statusKeys press).runReal texts rig.display
          let .ok second := second | return false
          let some (settled, _) ←
            settleQueued rig texts second.loop (first.starts.toList ++ second.starts.toList)
                statusKeys statusJobs | return false
          let index ← gitIn home directory #["show", ":a.txt"]
          return first.starts.size == 1 && second.starts.size == 1 &&
              index == VersionControlContract.lineSet VersionControlContract.tenLines 8 "nine\n" &&
              settled.state.echo.startsWith
                "vc-stage-hunk: exited with status 1: error: patch failed: a.txt" },
    { name :=
        "criterion 2 over real git: vc-commit, the message typed, vc-commit-accept makes a commit whose message is the buffer's text, and the message buffer is gone"
      run :=
        withConfiguredRepository
          { committed := #[("a.txt", "one\n")], index := #[("a.txt", .file "two\n")]
            worktree := #[("a.txt", "two\n")] } fun home config directory => do
          let message := "Commit from the message buffer\n\n# kept, as typed\n"
          let rig ← ProjectRig.over (onIsolatedGit services home config)
          let some (committed, _) ←
            runSettled rig directory
                [openFile (directory / "a.txt"), { command := VersionControl.commitName },
                  setText message, { command := VersionControl.acceptName }]
                statusKeys statusJobs | return false
          let object ← gitIn home directory #["cat-file", "commit", "HEAD"]
          return object.endsWith s!"\n\n{message}" &&
              (committed.state.findBuffer "*vc-commit: repo@main*").isNone },
    { name :=
        "criterion 3 over real git: a pre-commit hook printing a line on each stream and exiting 1 leaves HEAD as it was, *vc-commit-output: repo@main* shown holding both lines, and the message buffer kept with its text"
      run :=
        withConfiguredRepository
          { committed := #[("a.txt", "one\n")], index := #[("a.txt", .file "two\n")]
            worktree := #[("a.txt", "two\n")]
            hook := some "the hook says no on its output\nthe hook says no on its error\n" }
          fun home config directory => do
          let before ← gitIn home directory #["rev-parse", "HEAD"]
          let rig ← ProjectRig.over (onIsolatedGit services home config)
          let some (refused, texts) ←
            runSettled rig directory
                [openFile (directory / "a.txt"), { command := VersionControl.commitName },
                  setText "refused\n", { command := VersionControl.acceptName }]
                statusKeys statusJobs | return false
          let after ← gitIn home directory #["rev-parse", "HEAD"]
          let output ← bufferText rig texts refused "*vc-commit-output: repo@main*"
          let kept ← bufferText rig texts refused "*vc-commit: repo@main*"
          let shown :=
            match refused.state.findBuffer "*vc-commit-output: repo@main*" with
            | some id => refused.state.windows.any (·.buffer == id)
            | none => false
          return before == after && kept == some "refused\n" && shown &&
              output.any fun text =>
                (text.splitOn "the hook says no on its output").length > 1 &&
                  (text.splitOn "the hook says no on its error").length > 1 }]

end ContractTest
