import WorkspaceTest.Check
import WorkspaceTest.Finder.Contract
import WorkspaceTest.Workspace.Attach
import WorkspaceTest.Workspace.Compiled
import WorkspaceTest.Workspace.Contract
import WorkspaceTest.Workspace.FindFile
import WorkspaceTest.Workspace.FindInProject
import WorkspaceTest.Workspace.Lister
import WorkspaceTest.Workspace.Modes
import WorkspaceTest.Workspace.Projects
import WorkspaceTest.Workspace.Reach
import WorkspaceTest.WorkspaceTest.FixtureSupport

/-!
# The test driver of the package `workspace`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks and the two contracts'
failure lists.

Each test module mirrors the module it tests: the checks of
`Workspace/<X>.lean` are in `WorkspaceTest/Workspace/<X>.lean`, and those
of the finder's contract (`WorkspaceTest/Finder/Contract.lean`, with its
pure model `WorkspaceTest/Finder/Model.lean`) in
`WorkspaceTest/Workspace/Contract.lean`; those of the package's fixture
support (`WorkspaceTest/FixtureSupport.lean`) in
`WorkspaceTest/WorkspaceTest/FixtureSupport.lean`. They run on the workspace's test
kit (`WorkspaceTest/Kit.lean`), the finder checks' driver
(`WorkspaceTest/Support/FindFile.lean`) and the core's kit. They were the
core's (`ModelTest.<name>`) while the workspaces were modules of the core,
and moved here with their sentences as they were, in the order the core ran
them.

- `workspacePackageChecks`: the `Package` value (`Workspace/Compiled.lean`)
  held to the contract of `project-api` (`ProjectApiTest.contractChecks`),
  with a check that it bites; the jobs it leaves to its owner to start
  again after a restart, never counted as stopped, `find-workspace`,
  `find-mode-markers` and `compile-list`; and what it registers alone: the
  finder's command, source and job, the picker's command, source and three
  jobs, the escape's command and its one binding, `C-x C-d` in the category
  `workspace-file` (these four were `ConfigTest.shippedChecks`' over the
  core's hosts while the workspace package was among the core's);
- `workspaceChecks`: a file's workspace found and attached at `files-api`'s
  `Opened` hook, and `workspace-current` (`Workspace/Attach.lean`), on the
  workspace driver;
- `workspaceListerChecks`: which command lists a workspace's files
  (`Workspace/Lister.lean`), pure: config's lister for the root,
  then for the project, then git's for a workspace git found, then the
  fallback; their exact command lines, the fallback's records without
  `./`, its exit 1 a partial listing and no other's, and a lister as plain
  arguments;
- `findFileChecks`: `find-file-in-workspace`
  (`Workspace/FindFile.lean`) on the loop's driver over the
  editor's models and the job model of the workspace driver's world, each
  lister and filter scripted by its exact command line: the eight criteria
  of project navigation's phase 2, the lister run in the buffer's workspace
  alone, config's listers, the fallback, the accept through `open-file`,
  an absolute typed answer opened as it is, a refused prompt said,
  the label, the working directory of a buffer with no workspace, the
  refusals, that no step runs a process, a fallback that exits 1
  still listing what it printed, and the text after a location typed
  into the input, the list opened matched against it;
- `projectWorkspaceChecks`: the project's workspaces
  (`Workspace/Projects.lean`), pure: the worktrees in the reply's
  order, those not found labelled by `Workspace.labelOf`, then the table's
  others, one per location, the current one last; the table's label for a
  worktree it knows, a detached worktree by its directory, two entries of
  one label told apart by their annotation, and what is asked through its
  arguments' round trip, and split from what follows it;
- `findInProjectChecks`: `find-file-in-project`
  (`Workspace/FindInProject.lean`) on the finder checks' driver,
  with `/r`'s repository model and a third worktree `/u`: the five
  criteria of project navigation's phase 3, the three worktrees listed by
  `name@branch` with no file opened in two of them, the choice reaching
  `find-file-in-workspace` rooted there, by a choice or by a typed text,
  a worktree first reached added with the finder's identity and branch
  and found once, a gone worktree said, a registered workspace listed and
  refused, two of one label told apart, no project said, a project with
  no git, a failing worktree list said, and one that fails only when the
  accept lists again said by the command, with no prompt and no find; and
  the four criteria of phase 4: the escape key in the finder opening the
  picker, the choice opening the finder with the typed text, through a
  reach or the table, the key doing nothing new in any other prompt, under
  the Vim scheme too, and config's key in the category stepping out;
- `reachChecks`: reaching the workspace at a path the table has no
  answer for (`Workspace/Reach.lean`), with a probe continuation,
  on the workspace driver: the find job started and its answer recorded
  and handed on, a cached answer handed on with no job, a path in no
  repository said by the gone sentence and cached, an unregistered job
  said under the continuation's name, the arguments a caller carries
  through the find job handed on, and the order's round trip;
- `workspaceModesChecks`: the workspace's modes on markers
  (`Workspace/Modes.lean`), on the workspace driver: over the
  listing checks' world, a file under a root holding a marker turns its
  mode on through the marker search, whose listing runs after it once; over
  a world of markers (they were `CompileTest.compileHookChecks`' until the
  compile mode's tests took stand-ins for the workspace), which markers
  turn which modes on, with which roots, nearest first, a marker above the
  workspace's root or, with no workspace, outside the file's directory
  turning none on, no marker job with no contribution, a cached directory's
  second file searched with no git run, and the marker order's round
  trip;
- `fixtureSupportChecks`: the package's fixture support
  (`WorkspaceTest/FixtureSupport.lean`), pure: the default config's
  fixture runs the shipped config in an empty working directory, where the
  finder's default source with no workspace finds nothing, its lister and
  filter answered as in an empty directory.
- `workspaceFinderFailures` and `modeMarkerFailures`, failure lists: the
  properties of the workspace finder's contract and of the mode marker
  search's (`WorkspaceTest/Finder/Contract.lean`) that do not hold of the
  pure model (`World.find`, `World.presentMarkers`) or of the real finder
  and search on the job model of the property's world.
-/

/-- Every check of the test driver, in the order they run. -/
def WorkspaceTest.checks : List WorkspaceTest.Check :=
  WorkspaceTest.workspacePackageChecks ++ WorkspaceTest.workspaceChecks ++
    WorkspaceTest.workspaceListerChecks ++
    WorkspaceTest.findFileChecks ++
    WorkspaceTest.projectWorkspaceChecks ++
    WorkspaceTest.findInProjectChecks ++
    WorkspaceTest.reachChecks ++
    WorkspaceTest.workspaceModesChecks ++
    WorkspaceTest.fixtureSupportChecks

/-- Runs the checks and the contracts' failure lists, and prints each that
failed; the exit status is 1 when one did. -/
def main : IO UInt32 := do
  let failed :=
    (← WorkspaceTest.failures WorkspaceTest.checks) ++ (← WorkspaceTest.workspaceFinderFailures) ++
      (← WorkspaceTest.modeMarkerFailures)
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println
        s!"workspace-test: {WorkspaceTest.checks.length} checks passed, {(Editor.Workspace.FinderContract.properties "/").length} properties of the workspace finder hold of its model and of the finder on the job model, and {(Editor.Workspace.MarkerContract.properties "/").length} properties of the mode marker search hold of its model and of the search on the job model"
    return 0
  else
    return 1
