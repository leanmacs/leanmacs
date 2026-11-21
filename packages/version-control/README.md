# version-control

A default package: version control, as two packages. `version-control`
registers git's implementation of the core's version-control interface
(`vc-api`'s backend `git`) and the buffers over it: `vc-status`, a
workspace's changed files, staged and unstaged from the list; the worktree
list (`vc-worktrees`); `vc-show`, a file at a revision; staging and
unstaging the hunk on the cursor's line; the message buffer, `vc-commit`;
the review buffer, `vc-review` and `vc-review-since`; the log, `vc-log`;
and the blame, `vc-blame`; with their twelve ex names, and the mode
line's `review` segment. Its reviews are kept across a restart.
`version-control-gutter` registers the gutter's three jobs, which mark a
buffer's changed lines against `HEAD`. An editor without it has no version-control command,
ex name or gutter mark; the working sets then write their sets with no
commit.

Its design record is in [packages.md](../../docs/design/packages.md),
"The default packages of the features-as-packages roadmap's phase 6", and
what it does in [version-control.md](../../docs/design/version-control.md).

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `version-control`.
   It requires the core, `editor-core`, by path (`../../lean`), declares
   the library `VersionControl`, the test library `VersionControlTest` and
   the test driver `version-control-test`, and turns every Lean linter on
   with warnings as errors.
2. [`VersionControl/EditorPackage.lean`](VersionControl/EditorPackage.lean):
   the entry module. It imports `VersionControl.Compiled`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.VersionControl.package, Editor.VersionControl.gutterPackage]
   ```
3. [`VersionControl/Compiled.lean`](VersionControl/Compiled.lean): the two
   `Package` values: the commands, ex names, modes, jobs, review store,
   backend and segment of `version-control`, and the gutter's jobs.
4. [`VersionControl/Git.lean`](VersionControl/Git.lean), with the readers
   of what git prints ([`Porcelain.lean`](VersionControl/Porcelain.lean),
   [`Plumbing.lean`](VersionControl/Plumbing.lean),
   [`HistoryRead.lean`](VersionControl/HistoryRead.lean)): git's
   implementation, run as jobs over the core's process port.
5. The buffers: [`Status.lean`](VersionControl/Status.lean),
   [`Worktrees.lean`](VersionControl/Worktrees.lean),
   [`Show.lean`](VersionControl/Show.lean),
   [`Hunk.lean`](VersionControl/Hunk.lean) and
   [`Stage.lean`](VersionControl/Stage.lean),
   [`Commit.lean`](VersionControl/Commit.lean),
   [`ReviewHunks.lean`](VersionControl/ReviewHunks.lean) and
   [`Review.lean`](VersionControl/Review.lean),
   [`Log.lean`](VersionControl/Log.lean),
   [`Blame.lean`](VersionControl/Blame.lean), and what they share,
   [`Views.lean`](VersionControl/Views.lean).
6. [`VersionControl/Gutter.lean`](VersionControl/Gutter.lean): the gutter's
   jobs, over the core's reconciler (`Editor/Gutter/Track.lean`).

The interface is the core's interface library `vc-api` (`lean/VcApi.lean`),
and a workspace is reached through `project-api` (`lean/ProjectApi.lean`).
The declarations keep their names, `Editor.VersionControl.…`, from when
they were modules of the core.

## Its tests

- **The test driver**, [`VersionControlTest/Model.lean`](VersionControlTest/Model.lean),
  run by `lake test`: the model checks, one module under
  [`VersionControlTest/VersionControl/`](VersionControlTest/VersionControl)
  for each module of the library, with no git: on what git printed,
  captured as fixtures, the model of a repository and the job model.
- **The linked test**, [`VersionControlTest/Linked.lean`](VersionControlTest/Linked.lean),
  run by the package steps in `mise run ffi-test`: the contract of the
  version-control interface and the buffers over real git, and the gutter
  through the headless host, in
  [`VersionControlTest/Linked/VersionControl/`](VersionControlTest/Linked/VersionControl).
- It has no headless fixture of its own. The core's `tests/headless/ex`,
  run on the default set's editor, lists its ex names.

## Dropping it

`:package-remove version-control` rebuilds your editor without it; the
`vc-` commands and ex names are gone, and no gutter marks a changed line
([installing-packages.md](../../docs/packages/installing-packages.md)).
