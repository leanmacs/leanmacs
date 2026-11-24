import Editor.Extension
import Editor.Package
import VersionControl.Blame
import VersionControl.Commit
import VersionControl.Gutter
import VersionControl.Log
import VersionControl.Review
import VersionControl.Show
import VersionControl.Stage
import VersionControl.Status
import VersionControl.Worktrees

/-!
# The `version-control` and `version-control-gutter` packages

What a host registers so that `vc-status` runs
(`VersionControl/Status.lean`): the package `version-control`
(`VersionControl.package`, `Editor/Package.lean`), and, for the gutter, the
package `version-control-gutter` (`VersionControl.gutterPackage`). A host
of a set that holds this Lake package registers each for the owner of its
name when its loop starts, before any config
(`Editor/Config/Packages.lean`), after the `shell` package: the entry module
(`VersionControl/EditorPackage.lean`) lists both, the gutter's second.

The `version-control` package:

- **The commands**: `vc-status`, which opens the status buffer
  of the focused buffer's workspace (`VersionControl.statusCommand`);
  `vc-status-refresh`, `vc-status-visit` and `vc-status-toggle`, the
  status buffer's mode's `refresh`, `activate` and `toggle`; and
  `vc-status-stage` and `vc-status-unstage`, its leader suffixes `s` and
  `u`; `vc-show`, which opens a file at a revision as a read-only buffer
  (`VersionControl.showCommand`, `VersionControl/Show.lean`);
  `vc-stage-hunk` and `vc-unstage-hunk`, which stage and unstage the hunk
  on the cursor's line of a file buffer
  (`VersionControl/Stage.lean`); and `vc-commit`, the status
  buffer's leader suffix `c`, which opens the message buffer, with
  `vc-commit-accept` and `vc-commit-abort`, its mode's suffixes `c` and `k`
  (`VersionControl/Commit.lean`); and `vc-worktrees`, the status
  buffer's leader suffix `w`, which opens the worktree list, with
  `vc-worktrees-refresh` and `vc-worktrees-visit`, its mode's `refresh`
  and `activate` (`VersionControl/Worktrees.lean`); and
  `vc-review`, which opens the review buffer of a branch's change, with
  `vc-review-refresh`, its mode's `refresh`, and `vc-review-keep` and
  `vc-review-revert`, its leader suffixes `k` and `r`, and
  `vc-review-since`, which opens the change since the commit the last
  review recorded (`VersionControl/Review.lean`); `vc-log`, which
  opens a branch's log, with `vc-log-visit` and `vc-log-refresh`, its
  mode's `activate` and `refresh` (`VersionControl/Log.lean`); and
  `vc-blame`, which opens a file's blame, with `vc-blame-visit`, its mode's
  `activate` (`VersionControl/Blame.lean`).
- **The jobs**: `vc-status-read`, which reads a repository's
  status and shows it (`VersionControl.readWork`), and `vc-status-apply`,
  which stages or unstages and then starts a read
  (`VersionControl.applyWork`); and `vc-show-read`, which reads a file at a
  revision and shows it (`VersionControl.showWork`); `vc-hunk-fetch`,
  `vc-hunk-diff` and `vc-hunk-apply`, the steps of staging a hunk; and
  `vc-commit-run`, which commits; `vc-worktrees-read`, which reads the
  worktree list and shows it (`VersionControl.listWork`), and
  `vc-worktree-find`, which finds a listed worktree's workspace and opens
  its status (`VersionControl.visitFindWork`); `vc-review-read` and
  `vc-review-diff`, the steps of the review (`VersionControl.reviewReadWork`,
  `VersionControl.reviewDiffWork`); `vc-log-read`, which reads a log and
  shows it (`VersionControl.logReadWork`), and `vc-blame-read`, which reads a
  blame and shows it (`VersionControl.blameReadWork`). A host that is not handed them shows no
  status, and says so when one is asked for. `vc-status-apply`,
  `vc-hunk-apply` and `vc-commit-run` are reported: one running when the
  process ends is said stopped by the next start's restore.
- **Kept across a restart**: a workspace's reviews (`vc-review`), their
  rounds and decisions, the number of their review buffer dropped, which
  means nothing in the next process. Not the status, commit, worktree and
  log records, which hold buffer numbers.
- **The modes**: `vc-status`, the status buffer's major mode
  (`VersionControl.mode`), `vc-commit`, the message buffer's
  (`VersionControl.commitMode`), `vc-worktrees`, the worktree list's
  (`VersionControl.worktreesMode`), `vc-review`, the review buffer's
  (`VersionControl.reviewMode`), `vc-log`, the log buffer's
  (`VersionControl.logMode`), and `vc-blame`, the blame buffer's
  (`VersionControl.blameMode`).
- **The segment**: the mode line's `review`, a review
  buffer's counts (`VersionControl.reviewSegment`), which the default
  order lists (`ModeLine.Order.standard`).
- **The ex names** (`exCommand`), each bound to the command of its name,
  in this order, which the ex names' completion source keeps. `vc-status`
  takes nothing: it opens the status buffer of the workspace of the buffer
  the line was asked from. `vc-show` takes text, a revision and a path: it
  opens that file at that revision as a read-only buffer. `vc-stage-hunk`
  and `vc-unstage-hunk` take nothing: they stage, or unstage, the hunk on
  the cursor's line of the focused file buffer. No key binds them; binding
  one is config's. `vc-commit` takes nothing: it opens the message buffer.
  `vc-worktrees` takes nothing: it opens the worktree list of the focused
  buffer's workspace's repository. `vc-commit-accept` and `vc-commit-abort`
  take nothing: they commit with the message buffer's text, and give it up.
  `vc-review` takes text, a branch, or nothing for the main worktree's: it
  opens the review buffer of `HEAD`'s change against that branch.
  `vc-review-since` takes nothing: it opens the change since the commit the
  last review recorded. `vc-log` takes text, a revision, or nothing for
  `HEAD`: it opens the log buffer of that revision's commits. `vc-blame`
  takes text, a revision, or nothing for `HEAD`: it opens the blame of the
  focused buffer's file at that revision. A host must be handed the `ex`
  package (`packages/ex/Ex/Compiled.lean`) for a line to run them; neither
  package names the other.

It registers the git implementation as the version-control backend of the
interface library `vc-api` (`VcApi.Backend`, named `git`, connecting with
`Git.handler`), which working-set's write and find-in-project's jobs
connect through. Together with the gutter's package it is held to
`vc-api`'s registration check (`VcApiTest.registrationChecks`).

The `version-control-gutter` package: the gutter's command,
`vc-gutter-moved`, which its watch job posts
(`VersionControl/Gutter.lean`), and its jobs, `vc-gutter-head`,
`vc-gutter-diff` and `vc-gutter-refs`. A host that is not handed it tracks
no buffer, and its windows have no gutter.

This module is apart from `VersionControl/Status.lean` because it is
what a host is handed, not what config calls.

Pinned by `VersionControlTest.versionControlPackageChecks` and
`VersionControlTest.statusBufferChecks`, on the models.
-/

namespace Editor.VersionControl

/-- The package `version-control`: the status buffer's commands and those
of the buffers it opens, their jobs, their modes, the mode line's segment
`review`, the `vc-…` ex names, and the backend `git` at `VcApi.Backend`. -/
def package : Package :=
  { name := "version-control"
    setup := do
      Extension.add ({ name := VcApi.gitBackendName, connect := Git.handler } : VcApi.Backend)
      commandWith statusName statusCommand
      commandWith refreshName refreshCommand
      commandWith visitName visitCommand
      commandWith toggleName toggleCommand
      commandWith stageName stageCommand
      commandWith unstageName unstageCommand
      commandWith showName showCommand
      commandWith stageHunkName stageHunkCommand
      commandWith unstageHunkName unstageHunkCommand
      commandWith commitName commitCommand
      commandWith acceptName acceptCommand
      commandWith abortName abortCommand
      commandWith worktreesName worktreesCommand
      commandWith worktreesRefreshName worktreesRefreshCommand
      commandWith worktreesVisitName worktreesVisitCommand
      commandWith reviewName reviewCommand
      commandWith reviewRefreshName reviewRefreshCommand
      commandWith reviewKeepName reviewKeepCommand
      commandWith reviewRevertName reviewRevertCommand
      commandWith reviewSinceName reviewSinceCommand
      commandWith logName logCommand
      commandWith logVisitName logVisitCommand
      commandWith logRefreshName logRefreshCommand
      commandWith blameName blameCommand
      commandWith blameVisitName blameVisitCommand
      workJob readJob readWork
      workJob applyJob applyWork (reported := true)
      workJob showJob showWork
      workJob hunkFetchJob hunkFetchWork
      workJob hunkDiffJob hunkDiffWork
      workJob hunkApplyJob hunkApplyWork (reported := true)
      workJob commitJob commitWork (reported := true)
      workJob worktreesReadJob listWork
      Extension.workJob ProjectApi.Workspaces worktreeFindJob visitFindWork
      workJob reviewReadJob reviewReadWork
      workJob reviewDiffJob reviewDiffWork
      workJob logReadJob logReadWork
      workJob blameReadJob blameReadWork
      reviewStore.keptAcrossRestart (keep := fun kept => { kept with buffer := none })
      for mode in [mode, commitMode, worktreesMode, reviewMode, logMode, blameMode] do
        defineMode mode
      defineSegment reviewSegment.name reviewSegment.fields
      exCommand "vc-status" statusName
      exCommand "vc-show" showName (takes := .text)
      exCommand "vc-stage-hunk" stageHunkName
      exCommand "vc-unstage-hunk" unstageHunkName
      exCommand "vc-commit" commitName
      exCommand "vc-worktrees" worktreesName
      exCommand "vc-commit-accept" acceptName
      exCommand "vc-commit-abort" abortName
      exCommand "vc-review" reviewName (takes := .text)
      exCommand "vc-review-since" reviewSinceName
      exCommand "vc-log" logName (takes := .text)
      exCommand "vc-blame" blameName (takes := .text) }

/-- The package `version-control-gutter`: the gutter's command,
`vc-gutter-moved`, which its watch job posts
(`VersionControl/Gutter.lean`), and its jobs, `vc-gutter-head`,
`vc-gutter-diff` and `vc-gutter-refs`. A host that is not handed it tracks
no buffer, and its windows have no gutter. Its jobs are registered
restarted (`workJob … (restarted := true)`): its reconciler starts them
again for each buffer it tracks once a restore puts it back, so one
running at a restart is not counted as stopped by it. -/
def gutterPackage : Package :=
  { name := "version-control-gutter"
    setup := do
      commandWith movedName movedCommand
      workJob headJob headWork (restarted := true)
      workJob diffJob diffWork (restarted := true)
      workJob refsJob refsWork (restarted := true) }

end Editor.VersionControl
