import Editor.Package
import Editor.VersionControl.Blame
import Editor.VersionControl.Commit
import Editor.VersionControl.Gutter
import Editor.VersionControl.Log
import Editor.VersionControl.Review
import Editor.VersionControl.Show
import Editor.VersionControl.Stage
import Editor.VersionControl.Status
import Editor.VersionControl.Worktrees

/-!
# The `version-control` and `version-control-gutter` packages

What a host registers so that `vc-status` runs
(`Editor/VersionControl/Status.lean`): the package `version-control`
(`VersionControl.package`, `Editor/Package.lean`), and, for the gutter, the
package `version-control-gutter` (`VersionControl.gutterPackage`). A host
registers each for the owner of its name when its loop starts, before any
config (`Editor/Config/Packages.lean`), beside the `ex` package
(`Editor/Ex/Compiled.lean`), which binds the ex name `vc-status` to the
command of that name.

The `version-control` package:

- **The commands**: `vc-status`, which opens the status buffer
  of the focused buffer's workspace (`VersionControl.statusCommand`);
  `vc-status-refresh`, `vc-status-visit` and `vc-status-toggle`, the
  status buffer's mode's `refresh`, `activate` and `toggle`; and
  `vc-status-stage` and `vc-status-unstage`, its leader suffixes `s` and
  `u`; `vc-show`, which opens a file at a revision as a read-only buffer
  (`VersionControl.showCommand`, `Editor/VersionControl/Show.lean`);
  `vc-stage-hunk` and `vc-unstage-hunk`, which stage and unstage the hunk
  on the cursor's line of a file buffer
  (`Editor/VersionControl/Stage.lean`); and `vc-commit`, the status
  buffer's leader suffix `c`, which opens the message buffer, with
  `vc-commit-accept` and `vc-commit-abort`, its mode's suffixes `c` and `k`
  (`Editor/VersionControl/Commit.lean`); and `vc-worktrees`, the status
  buffer's leader suffix `w`, which opens the worktree list, with
  `vc-worktrees-refresh` and `vc-worktrees-visit`, its mode's `refresh`
  and `activate` (`Editor/VersionControl/Worktrees.lean`); and
  `vc-review`, which opens the review buffer of a branch's change, with
  `vc-review-refresh`, its mode's `refresh`, and `vc-review-keep` and
  `vc-review-revert`, its leader suffixes `k` and `r`, and
  `vc-review-since`, which opens the change since the commit the last
  review recorded (`Editor/VersionControl/Review.lean`); `vc-log`, which
  opens a branch's log, with `vc-log-visit` and `vc-log-refresh`, its
  mode's `activate` and `refresh` (`Editor/VersionControl/Log.lean`); and
  `vc-blame`, which opens a file's blame, with `vc-blame-visit`, its mode's
  `activate` (`Editor/VersionControl/Blame.lean`).
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
  status, and says so when one is asked for.
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

The `version-control-gutter` package: the gutter's command,
`vc-gutter-moved`, which its watch job posts
(`Editor/VersionControl/Gutter.lean`), and its jobs, `vc-gutter-head`,
`vc-gutter-diff` and `vc-gutter-refs`. A host that is not handed it tracks
no buffer, and its windows have no gutter.

This module is apart from `Editor/VersionControl/Status.lean` because it is
what a host is handed, not what config calls.

Pinned by `ModelTest.statusBufferChecks`, on the models, and
`ContractTest.statusBufferChecks`, over real git.
-/

namespace Editor.VersionControl

/-- The package `version-control`: the status buffer's commands and those
of the buffers it opens, their jobs, their modes, and the mode line's
segment `review`. -/
def package : Package :=
  { name := "version-control"
    setup := do
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
      workJob applyJob applyWork
      workJob showJob showWork
      workJob hunkFetchJob hunkFetchWork
      workJob hunkDiffJob hunkDiffWork
      workJob hunkApplyJob hunkApplyWork
      workJob commitJob commitWork
      workJob worktreesReadJob listWork
      workJob worktreeFindJob visitFindWork
      workJob reviewReadJob reviewReadWork
      workJob reviewDiffJob reviewDiffWork
      workJob logReadJob logReadWork
      workJob blameReadJob blameReadWork
      for mode in [mode, commitMode, worktreesMode, reviewMode, logMode, blameMode] do
        defineMode mode
      defineSegment reviewSegment.name reviewSegment.fields }

/-- The package `version-control-gutter`: the gutter's command,
`vc-gutter-moved`, which its watch job posts
(`Editor/VersionControl/Gutter.lean`), and its jobs, `vc-gutter-head`,
`vc-gutter-diff` and `vc-gutter-refs`. A host that is not handed it tracks
no buffer, and its windows have no gutter. -/
def gutterPackage : Package :=
  { name := "version-control-gutter"
    setup := do
      commandWith movedName movedCommand
      workJob headJob headWork
      workJob diffJob diffWork
      workJob refsJob refsWork }

end Editor.VersionControl
