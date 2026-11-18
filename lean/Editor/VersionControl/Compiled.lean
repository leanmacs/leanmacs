import Editor.Config.Registry
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
# The status buffer's commands, its jobs and its mode, as compiled code registers them

What a host is handed so that `vc-status` runs
(`Editor/VersionControl/Status.lean`). A host registers them for the owner
`compiled` when its loop starts, before any config
(`Editor/Config/Registry.lean`, "Compiled commands"), beside the ex line's
(`Editor/Ex/Compiled.lean`), which binds the ex name `vc-status` to the
command of that name.

- **`VersionControl.commands`**: `vc-status`, which opens the status buffer
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
- **`VersionControl.jobs`**: `vc-status-read`, which reads a repository's
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
- **`VersionControl.modes`**: `vc-status`, the status buffer's major mode
  (`VersionControl.mode`), `vc-commit`, the message buffer's
  (`VersionControl.commitMode`), `vc-worktrees`, the worktree list's
  (`VersionControl.worktreesMode`), `vc-review`, the review buffer's
  (`VersionControl.reviewMode`), `vc-log`, the log buffer's
  (`VersionControl.logMode`), and `vc-blame`, the blame buffer's
  (`VersionControl.blameMode`).
- **`VersionControl.segments`**: the mode line's `review`, a review
  buffer's counts (`VersionControl.reviewSegment`), which the default
  order lists (`ModeLine.Order.standard`).

This module is apart from `Editor/VersionControl/Status.lean` because it
names the registry, which is the config session's.

Pinned by `ModelTest.statusBufferChecks`, on the models, and
`ContractTest.statusBufferChecks`, over real git.
-/

namespace Editor.VersionControl

/-- The status buffer's commands, as a host registers them for the owner
`compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := statusName, action := .call statusCommand },
    { name := refreshName, action := .call refreshCommand },
    { name := visitName, action := .call visitCommand },
    { name := toggleName, action := .call toggleCommand },
    { name := stageName, action := .call stageCommand },
    { name := unstageName, action := .call unstageCommand },
    { name := showName, action := .call showCommand },
    { name := stageHunkName, action := .call stageHunkCommand },
    { name := unstageHunkName, action := .call unstageHunkCommand },
    { name := commitName, action := .call commitCommand },
    { name := acceptName, action := .call acceptCommand },
    { name := abortName, action := .call abortCommand },
    { name := worktreesName, action := .call worktreesCommand },
    { name := worktreesRefreshName, action := .call worktreesRefreshCommand },
    { name := worktreesVisitName, action := .call worktreesVisitCommand },
    { name := reviewName, action := .call reviewCommand },
    { name := reviewRefreshName, action := .call reviewRefreshCommand },
    { name := reviewKeepName, action := .call reviewKeepCommand },
    { name := reviewRevertName, action := .call reviewRevertCommand },
    { name := reviewSinceName, action := .call reviewSinceCommand },
    { name := logName, action := .call logCommand },
    { name := logVisitName, action := .call logVisitCommand },
    { name := logRefreshName, action := .call logRefreshCommand },
    { name := blameName, action := .call blameCommand },
    { name := blameVisitName, action := .call blameVisitCommand }]

/-- The status buffer's jobs, as a host registers them for the owner
`compiled`. -/
def jobs : Array Config.JobRegistration :=
  #[{ name := readJob, work := readWork }, { name := applyJob, work := applyWork },
    { name := showJob, work := showWork }, { name := hunkFetchJob, work := hunkFetchWork },
    { name := hunkDiffJob, work := hunkDiffWork }, { name := hunkApplyJob, work := hunkApplyWork },
    { name := commitJob, work := commitWork }, { name := worktreesReadJob, work := listWork },
    { name := worktreeFindJob, work := visitFindWork },
    { name := reviewReadJob, work := reviewReadWork },
    { name := reviewDiffJob, work := reviewDiffWork }, { name := logReadJob, work := logReadWork },
    { name := blameReadJob, work := blameReadWork }]

/-- The version-control gutter's command, `vc-gutter-moved`, which its watch
job posts (`Editor/VersionControl/Gutter.lean`), as a host registers it for
the owner `compiled`. -/
def gutterCommands : Array Config.Registration :=
  #[{ name := movedName, action := .call movedCommand }]

/-- The version-control gutter's jobs, as a host registers them for the owner
`compiled`: `vc-gutter-head`, `vc-gutter-diff` and `vc-gutter-refs`. A host
that is not handed them tracks no buffer, and its windows have no gutter. -/
def gutterJobs : Array Config.JobRegistration :=
  #[{ name := headJob, work := headWork }, { name := diffJob, work := diffWork },
    { name := refsJob, work := refsWork }]

/-- The status buffer's mode, as a host registers it for the owner
`compiled`. -/
def modes : Array Mode :=
  #[mode, commitMode, worktreesMode, reviewMode, logMode, blameMode]

/-- The mode line's segments of version control, as a host registers them
for the owner `compiled`: `review`. -/
def segments : Array Segment :=
  #[reviewSegment]

end Editor.VersionControl
