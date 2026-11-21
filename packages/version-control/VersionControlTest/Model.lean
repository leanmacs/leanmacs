import VersionControlTest.Check
import VersionControlTest.VersionControl.Blame
import VersionControlTest.VersionControl.Commit
import VersionControlTest.VersionControl.Compiled
import VersionControlTest.VersionControl.Git
import VersionControlTest.VersionControl.Git.Model
import VersionControlTest.VersionControl.Gutter
import VersionControlTest.VersionControl.HistoryRead
import VersionControlTest.VersionControl.Hunk
import VersionControlTest.VersionControl.Log
import VersionControlTest.VersionControl.Plumbing
import VersionControlTest.VersionControl.Porcelain
import VersionControlTest.VersionControl.Review
import VersionControlTest.VersionControl.ReviewHunks
import VersionControlTest.VersionControl.Show
import VersionControlTest.VersionControl.Stage
import VersionControlTest.VersionControl.Status
import VersionControlTest.VersionControl.Views
import VersionControlTest.VersionControl.Worktrees

/-!
# The test driver of the package `version-control`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Each test module mirrors the module it tests: the checks of
`VersionControl/<X>.lean` are in `VersionControlTest/VersionControl/<X>.lean`,
and those of git's half of the repository model
(`VersionControlTest/Git/Model.lean`) in
`VersionControlTest/VersionControl/Git/Model.lean`. They run with no git:
against what git printed, captured as fixtures
(`VersionControlTest/Support/Git.lean` says how), the model of a repository
(`vc-api`'s fake, `VcApiTest/Fake.lean`) and the job model, on the
version-control checks' driver (`VersionControlTest/Support/VersionControl.lean`)
and the core's kit. They were the core's (`ModelTest.<name>`) while
version control was modules of the core, and moved here with their
sentences as they were, in the order the core ran them, but for two checks
of `versionControlPackageChecks` new with the move (which jobs it reports
and which codec it registers, which `ModelTest.packageSetChecks` held over
the core's list).

- `versionControlPackageChecks`: the two `Package` values
  (`VersionControl/Compiled.lean`): `vc-api`'s registration check and that
  it bites, the twelve `vc-` ex names, the gutter's three jobs restarted by
  their owner, the three jobs reported, and the one codec, `vc-review`;
- `versionControlParserChecks`: the reader of git's porcelain status
  (`VersionControl/Porcelain.lean`), on the fixtures, and the
  records it refuses;
- `versionControlPlumbingChecks`: the readers of git's plumbing
  (`VersionControl/Plumbing.lean`): the worktree list, the branches,
  a raw diff and a batch of blobs, and what each refuses;
- `versionControlHistoryParserChecks`: the readers of git's history
  (`VersionControl/HistoryRead.lean`): a log, a blame with two
  authors and a commit named twice, and a range-diff of each relation, on
  fixtures, and what each refuses;
- `gitModelChecks`: git's half of that model
  (`VersionControl/Git/Model.lean`): the real parser reads what its
  printer prints as the model's status, in every state and for every
  repository of the contract;
- `versionControlGitChecks`, `versionControlWorktreeGitChecks`,
  `versionControlHistoryGitChecks` and `versionControlShowChecks`: the git
  implementation (`VersionControl/Git.lean`) on the job model: its
  status read of each of the contract's repositories on the job model that
  prints it (`Repository.jobModel`), the
  command lines it runs for the status and its writes, for worktrees,
  branches and changes, for a log, a blame, a range-diff and a change
  against no base, and for `show` and `watched`, their environments and limits, and how it
  reads what they answer;
- `hunkChecks`: the pure core of staging a hunk
  (`VersionControl/Hunk.lean`) and the patch the git implementation
  feeds `git apply` (`Git.patch`);
- `reviewHunkChecks`, `reviewOrderChecks` and `reviewRecordChecks`: the
  pure core of the review buffer (`VersionControl/ReviewHunks.lean`):
  a change's hunks with their context and git's numbers, on strings; the
  order of a change's files, over the change the version-control model
  gives; and the record, its counts and the hunk at an offset;
- `statusViewChecks` and `worktreeViewChecks`: the pure views of the status
  buffer (`VersionControl/Status.lean`) and of the worktree list
  (`VersionControl/Worktrees.lean`), on values the model gives;
- `statusBufferChecks`, `worktreeBufferChecks`, `revisionBufferChecks`
  (`vc-show`, `VersionControl/Show.lean`), `stageHunkChecks`
  (`VersionControl/Stage.lean`) and `commitBufferChecks` (the
  message buffer, `VersionControl/Commit.lean`): the commands, on
  the loop's driver over the editor's models, the job model, the model of
  files and the model of a repository in `/r`, whose git answers as the
  model does; and, with no implementation of an interface they reach
  registered (`Editor.Test.withoutExtension`), what each says or does:
  `vc-status-visit` and `vc-stage-hunk` with no files implementation,
  `vc-worktrees-visit` with no workspace implementation, each saying so and
  starting no job, and a commit made and `vc-commit-abort` with no buffers
  implementation, which keep the message buffer;
- `gutterChecks`: the version-control gutter
  (`VersionControl/Gutter.lean`) on that driver and the model of
  watches, whose waiting jobs it holds parked: the head fetched, the marks
  of a diff, and what a commit made outside the editor and HEAD moving
  while a fetch or a diff runs change;
- `reviewBufferChecks`: the review buffer
  (`VersionControl/Review.lean`) on that driver (and `vc-review`
  kept across a restart without its buffer's number), its read run over
  the version-control interface's model (`Model.readHandler`): the four
  criteria of the excerpts roadmap's phase 4, its refusals, refresh, the
  old buffers a round that ends early removes, the rounds its store keeps,
  the commit each records and the store's migration, edits through its
  excerpts, a commit's review, and `vc-review-since`, into a review buffer
  and, past a rewritten branch, the range-diff buffer; and, with no files
  implementation registered, a changed file left out as a refused load is;
- `logViewChecks` and `logBufferChecks`, `blameViewChecks` and
  `blameBufferChecks`: the log buffer (`VersionControl/Log.lean`)
  and the blame view (`VersionControl/Blame.lean`), their pure views
  on values and their commands on that driver, their reads over the
  interface's model: what each lists, with each commit's author, and the
  review a row's visit opens;
- `versionControlViewsChecks`: what the version-control buffers share
  (`VersionControl/Views.lean`), on values: a day as the log's and
  the blame's rows show it;
-/

/-- Every check of the test driver, in the order they run. -/
def VersionControlTest.checks : List VersionControlTest.Check :=
  VersionControlTest.versionControlPackageChecks ++ VersionControlTest.versionControlParserChecks ++
    VersionControlTest.versionControlPlumbingChecks ++
    VersionControlTest.versionControlHistoryParserChecks ++
    VersionControlTest.gitModelChecks ++
    VersionControlTest.versionControlGitChecks ++
    VersionControlTest.versionControlWorktreeGitChecks ++
    VersionControlTest.versionControlHistoryGitChecks ++
    VersionControlTest.hunkChecks ++
    VersionControlTest.reviewHunkChecks ++
    VersionControlTest.reviewOrderChecks ++
    VersionControlTest.reviewRecordChecks ++
    VersionControlTest.versionControlShowChecks ++
    VersionControlTest.statusViewChecks ++
    VersionControlTest.statusBufferChecks ++
    VersionControlTest.worktreeViewChecks ++
    VersionControlTest.worktreeBufferChecks ++
    VersionControlTest.revisionBufferChecks ++
    VersionControlTest.gutterChecks ++
    VersionControlTest.stageHunkChecks ++
    VersionControlTest.commitBufferChecks ++
    VersionControlTest.reviewBufferChecks ++
    VersionControlTest.logViewChecks ++
    VersionControlTest.logBufferChecks ++
    VersionControlTest.blameViewChecks ++
    VersionControlTest.blameBufferChecks ++
    VersionControlTest.versionControlViewsChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← VersionControlTest.failures VersionControlTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"version-control-test: {VersionControlTest.checks.length} checks passed"
    return 0
  else
    return 1
