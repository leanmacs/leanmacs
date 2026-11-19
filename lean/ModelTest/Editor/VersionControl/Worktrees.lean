import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Keymap
import Editor.Loop
import Editor.Loop.Driver
import Editor.Mode
import Editor.Process
import Editor.Process.Model
import Editor.Role
import Editor.Scene
import Editor.State
import Editor.Store
import Editor.Test.Driver
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Shell
import Editor.Test.Workspace
import Editor.VersionControl
import Editor.VersionControl.Contract
import Editor.VersionControl.Model
import Editor.VersionControl.Status
import Editor.VersionControl.Worktrees
import Editor.Workspace
import Editor.Workspace.Model
import ModelTest.Check
import ModelTest.Support.Git
import ModelTest.Support.VersionControl

/-!
# Model tests: `Editor/VersionControl/Worktrees.lean`

The model tests of `Editor/VersionControl/Worktrees.lean`: `worktreeViewChecks`
and `worktreeBufferChecks`. The root module `ModelTest` runs them; its module
doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The worktrees of the worktree list checks: `/r` on `main`, `/d` detached
and `/w` on `feature`. -/
def listedWorktrees : Array VersionControl.Worktree :=
  #[{ path := "/r", head := .branch "main" }, { path := "/d", head := .detached },
    { path := "/w", head := .branch "feature" }]

/-- The text of the worktree list of `listedWorktrees`, asked from `/r`. -/
def worktreesText : String :=
  "r@main: worktrees\nmain: /r (this one)\ndetached: /d\nfeature: /w\n"

/-- The checks of the worktree list's pure view and record
(`Editor/VersionControl/Worktrees.lean`). -/
def worktreeViewChecks : List Check :=
  [{  name :=
        "the worktree list renders its head line, then one row per worktree naming its branch or detached and its path, the asking root's row marked"
      run :=
        pure (VersionControl.WorktreeView.render "r@main" "/r" listedWorktrees == worktreesText) },
    { name := "the worktree on a row is the row's: none on the head line or past the last"
      run :=
        pure <|
          VersionControl.WorktreeView.entryAt listedWorktrees 0 == none &&
            VersionControl.WorktreeView.entryAt listedWorktrees 1 == listedWorktrees[0]? &&
            VersionControl.WorktreeView.entryAt listedWorktrees 3 == listedWorktrees[2]? &&
            VersionControl.WorktreeView.entryAt listedWorktrees 4 == none },
    { name :=
        "a worktree list's record reads back as it was written, a detached worktree and a buffer of none among them"
      run :=
        pure <|
          let record : VersionControl.WorktreesRecord :=
            { buffer := some 3, worktrees := listedWorktrees }
          let store := VersionControl.worktreesStore
          store.decode (store.encode record) == some record &&
            store.decode (store.encode {}) == some {} &&
            store.version == 1 },
    { name :=
        "the mode vc-worktrees fills refresh and activate with the worktree list's commands, has no leader suffix, and nothing is wrong with it"
      run :=
        pure <|
          VersionControl.worktreesMode.name == "vc-worktrees" &&
            VersionControl.worktreesMode.roles ==
              [(Role.refresh, VersionControl.worktreesRefreshName),
                (Role.activate, VersionControl.worktreesVisitName)] &&
            VersionControl.worktreesMode.locals == [] &&
            VersionControl.worktreesMode.problems == [] }]

/-- The repository checked out in `/w` of the worktree list checks: on
`feature`, with `a.txt` changed in the working tree. -/
def featureRepository : VersionControl.Model.Repository :=
  {
    VersionControlContract.writing (VersionControlContract.clean #[("a.txt", "a\n")]) "a.txt"
      "b\n" with
    head := .branch "feature" }

/-- The jobs of the worktree list checks: the status buffer checks', and the
worktree list's read and find jobs. -/
def worktreeJobs (name : String) : Option (List Argument → Work) :=
  if name == VersionControl.worktreesReadJob then some VersionControl.listWork
  else
    if name == VersionControl.worktreeFindJob then some VersionControl.visitFindWork
    else statusJobs name

/-- The keys of the worktree list checks: the status buffer checks', and
`C-v l` (`vc-worktrees`), `C-v e` (`vc-worktrees-visit`) and `C-v f`
(`vc-worktrees-refresh`). -/
def worktreeKeys : Loop.Keys TestScheme.scheme :=
  let keys :=
    dispatchKeys
      (statusBindings ++
        [("C-v l", invoke VersionControl.worktreesName),
          ("C-v e", invoke VersionControl.worktreesVisitName),
          ("C-v f", invoke VersionControl.worktreesRefreshName)])
      statusCommands
  { statusKeys with
    command? := keys.command?,
    maps := fun state view => statusKeys.maps state view ++ keys.maps state view }

/-- The driver of the worktree list checks: the status buffer checks' over a
repository in `/r` with `feature` checked out in `/w` and `/d` detached,
whose git in `/w` meets `featureRepository`, and whose finder finds `/w`, a
worktree of `/r`'s repository on `feature` (`workspaceWorld`), and nothing
at `/d`, whose directory is gone. -/
def worktreeDriver : Option TestDriver :=
  let repository : VersionControl.Model.Repository :=
    { VersionControlContract.clean
        #[("a.txt", "a\n")] with
      branches := #[("feature", "head")]
      linked := #[{ path := "/w", branch := some "feature" }, { path := "/d", branch := none }] }
  (statusDriverOf repository (registered := worktreeJobs) (keys := worktreeKeys)).map fun driver =>
    let extra :=
      (featureRepository.jobModel "git" "/w").processes.scripts ++
        (workspaceWorld.jobModel "git" #["/w", "/d"]).processes.scripts
    { driver with
      jobs :=
        { driver.jobs with
          processes :=
            { driver.jobs.processes with scripts := driver.jobs.processes.scripts ++ extra } } }

/-- The name of the worktree list of `/r`. -/
def worktreesBufferName : String :=
  "*vc-worktrees: r@main*"

/-- The checks of the worktree list (`Editor/VersionControl/Worktrees.lean`),
on the loop's driver over the editor's models, the job model, the models of
two repositories in `/r` and `/w` and the finder's world. -/
def worktreeBufferChecks : List Check :=
  let listRun := gitRun #["worktree", "list", "--porcelain", "-z"]
  let shownList (driver : TestDriver) := settledAfter (settledAfter driver "C-o a") "C-v l"
  [{  name :=
        "criterion 1: vc-worktrees in a repository with a main and two linked worktrees, one detached, shows *vc-worktrees: r@main* read-only in the mode vc-worktrees, one row for each with its branch, and runs git worktree list --porcelain -z in the root once"
      run :=
        pure <|
          match worktreeDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let asking := (fedTo opened (presses "C-v l")).1
            let shown := shownList driver
            let state := shown.loop.state
            asking.pending.map (fun job => (job.name, job.key)) ==
                #[(VersionControl.worktreesReadJob, some "vc-worktrees local /r")] &&
              match state.findBuffer worktreesBufferName with
              | none => false
              | some id =>
                (state.buffer? id).map (·.readOnly) == some true &&
                  (state.buffer? id).bind (·.major) == some VersionControl.worktreesModeName &&
                  (state.workspaceOf? id).map (·.1.location) == some (.local "/r") &&
                  (showingFocused shown).map (·.id) == some id &&
                  namedText shown worktreesBufferName == some worktreesText &&
                  gitStarted shown == #[listRun] },
    { name :=
        "criterion 2: visiting a linked worktree's row runs the finder there, records its workspace, and shows *vc-status: r@feature* with that worktree's status; a second visit finds it in the table and runs no finder"
      run :=
        pure <|
          match worktreeDriver with
          | none => false
          | some driver =>
            let visited := settledAfter (shownList driver) "C-v 3 C-v e"
            let again := settledAfter (settledAfter visited "C-v l") "C-v 3 C-v e"
            let name := "*vc-status: r@feature*"
            let finds (driver : TestDriver) :=
              (driver.jobs.processes.started.filter
                  (· == Workspace.Git.revParseCommand "git" "/w")).size
            finds visited == 1 && finds again == 1 &&
              namedText visited name ==
                some "r@feature: on feature\nunstaged: a.txt (modified)\n" &&
              (showingFocused visited).map (·.buffer.name) == some name &&
              (visited.loop.state.findBuffer name).bind
                  (fun id => (visited.loop.state.workspaceOf? id).map (·.1.location)) ==
                some (.local "/w") &&
              visited.loop.state.workspaces.cached? "/w" 0 == some (some (.local "/w")) },
    { name := "visiting this workspace's own row shows its status buffer without a find"
      run :=
        pure <|
          match worktreeDriver with
          | none => false
          | some driver =>
            let visited := settledAfter (shownList driver) "C-v 1 C-v e"
            (showingFocused visited).map (·.buffer.name) == some statusBufferName &&
              !visited.jobs.processes.started.contains (Workspace.Git.revParseCommand "git" "/r") },
    { name :=
        "visiting a worktree whose directory is gone says it is not a repository any more and opens nothing; on the head line there is no worktree"
      run :=
        pure <|
          match worktreeDriver with
          | none => false
          | some driver =>
            let shown := shownList driver
            let gone := settledAfter shown "C-v 2 C-v e"
            let head := settledAfter shown "C-v 0 C-v e"
            echoOf gone == some "vc-worktrees-visit: /d is not a repository any more" &&
              (gone.loop.state.buffers.filterMap id).all (!·.name.startsWith "*vc-status") &&
              echoOf head == some "vc-worktrees: no worktree on this line" },
    { name :=
        "refreshing reads the list again into the same buffer; outside a worktree list it says the buffer is not one, and vc-worktrees in a buffer with no workspace says so and starts nothing"
      run :=
        pure <|
          match worktreeDriver with
          | none => false
          | some driver =>
            let shown := shownList driver
            let refreshed := settledAfter shown "C-v f"
            let outside := settledAfter (settledAfter driver "C-o a") "C-v f"
            let bare := settledAfter driver "C-v l"
            gitStarted refreshed == #[listRun, listRun] &&
              ((refreshed.loop.state.buffers.filterMap id).filter
                    (·.name.startsWith "*vc-worktrees")).size ==
                1 &&
              ((echoOf outside).map fun echo =>
                  echo.startsWith "vc-worktrees-refresh: " &&
                    echo.endsWith " is not a worktree list") ==
                some true &&
              echoOf bare == some s!"vc-worktrees: {EditorState.scratchName} has no workspace" &&
              gitStarted bare == #[] }]

end ModelTest
