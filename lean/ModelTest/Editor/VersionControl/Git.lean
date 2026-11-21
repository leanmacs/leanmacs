import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Text.Model
import Editor.VersionControl.Git
import Editor.VersionControl.Git.Model
import ModelTest.Check
import ModelTest.Support.Git
import VcApi
import VcApiTest.Contract
import VcApiTest.Fake

/-!
# Model tests: `Editor/VersionControl/Git.lean`

The model tests of `Editor/VersionControl/Git.lean`: `versionControlGitChecks`,
`versionControlWorktreeGitChecks` and `versionControlShowChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open VcApiTest

/-- The git implementation's staging of `paths` in `/r` on `model`. -/
def gitStage (paths : Array String) (model : JobModel) :
    Job.Outcome (Except VersionControl.Error Unit) × JobModel :=
  (VersionControl.Git.handler "git" "/r" (.stage paths) :
        JobM (Except VersionControl.Error Unit)).runModel
    model

/-- The git implementation's unstaging of `paths` in `/r` on `model`. -/
def gitUnstage (paths : Array String) (model : JobModel) :
    Job.Outcome (Except VersionControl.Error Unit) × JobModel :=
  (VersionControl.Git.handler "git" "/r" (.unstage paths) :
        JobM (Except VersionControl.Error Unit)).runModel
    model

/-- The job model in which `git status` in `/r` answers `reply`, taking
`takes` milliseconds. -/
def statusAnswering (reply : Except ProcessError Process.Ran) (takes : Nat := 0) : JobModel :=
  {
    processes :=
      { scripts := #[{ command := gitRun VersionControl.Git.statusArguments, reply, takes }] } }

/-- The checks of the git implementation (`Editor/VersionControl/Git.lean`)
on the job model: the command lines it runs and how it reads what they
answer. -/
def versionControlGitChecks : List Check :=
  let status := gitStatus
  let statusArguments :=
    #["-c", "status.renames=true", "-c", "diff.renames=true", "status", "--porcelain=v2", "-z",
      "--branch", "--untracked-files=all", "--find-renames"]
  -- The version-control contract's repositories, each read by the git
  -- implementation's status on the job model that prints it
  -- (`Repository.jobModel`): the third way the contract runs.
  (VersionControlContract.properties.map fun property =>
      { name :=
          s!"the git implementation's status on the job model reads the repository of the version-control contract's property {property.name} as the model's"
        run :=
          pure
            ((gitStatus (property.repository.jobModel "git" "/r")).1 ==
              .finished (.ok property.repository.status)) }) ++
    [{  name :=
          "a status read runs git -c status.renames=true -c diff.renames=true status --porcelain=v2 -z --branch --untracked-files=all --find-renames in the root, once, with GIT_DIR, GIT_WORK_TREE and GIT_INDEX_FILE removed, GIT_OPTIONAL_LOCKS=0 and GIT_LITERAL_PATHSPECS=1"
        run :=
          pure <|
            let (read, after) := status (mixedRepository.jobModel "git" "/r")
            read == .finished (.ok mixedStatus) &&
              after.processes.started == #[gitRun statusArguments] },
      { name :=
          "staging runs git add --all -- and the paths, in the root, a path with a space whole"
        run :=
          pure <|
            let (reply, after) :=
              gitStage #["with space.txt", "b.txt"]
                (mixedRepository.jobModel "git" "/r" #[.stage #["with space.txt", "b.txt"]])
            reply == .finished (.ok ()) &&
              after.processes.started ==
                #[gitRun #["add", "--all", "--", "with space.txt", "b.txt"]] },
      { name := "unstaging runs git reset -q -- and the paths, in the root"
        run :=
          pure <|
            let (reply, after) :=
              gitUnstage #["new.txt", "old.txt"]
                (mixedRepository.jobModel "git" "/r" #[.unstage #["new.txt", "old.txt"]])
            reply == .finished (.ok ()) &&
              after.processes.started == #[gitRun #["reset", "-q", "--", "new.txt", "old.txt"]] },
      { name := "with no git to run, a status read could not run, as notFound"
        run := pure (status {} matches (.finished (.error (.couldNotRun (.notFound _))), _)) },
      { name :=
          "a status read git refuses with status 128 failed, with what git said on its standard error"
        run :=
          pure <|
            (status
                  (statusAnswering
                    (.ok
                      { exit := .code 128, stdout := .empty
                        stderr := "fatal: not a git repository\n".toUTF8 }))).1 ==
              .finished (.error (.failed (.code 128) "fatal: not a git repository")) },
      { name := "a write git refuses with status 128 failed, and is not read as a success"
        run :=
          pure <|
            let model : JobModel :=
              {
                processes :=
                  {
                    scripts :=
                      #[{ command := gitRun #["add", "--all", "--", "nope.txt"]
                          reply :=
                            .ok {
                                exit := .code 128, stdout := .empty
                                stderr :=
                                  "fatal: pathspec 'nope.txt' did not match any files\n".toUTF8 } }] } }
            (gitStage #["nope.txt"] model).1 ==
              .finished
                (.error
                  (.failed (.code 128) "fatal: pathspec 'nope.txt' did not match any files")) },
      { name := "a status read past the output limit could not run, and is never read cut short"
        run :=
          pure <|
            (status
                  (statusAnswering
                    (.error (.outputTooLarge .out VersionControl.Git.statusOutput)))).1 ==
              .finished
                (.error (.couldNotRun (.outputTooLarge .out VersionControl.Git.statusOutput))) },
      { name := "a status read past its time limit could not run, as timedOut"
        run :=
          pure <|
            (status
                  (statusAnswering (VersionControl.Model.Repository.ran porcelainClean.toUTF8)
                    (VersionControl.Git.gitTime + 1))).1 ==
              .finished (.error (.couldNotRun (.timedOut VersionControl.Git.gitTime))) },
      { name := "a status read git answers with what cannot be read is unparsable"
        run :=
          pure <|
            (status
                  (statusAnswering
                    (VersionControl.Model.Repository.ran "x what\x00".toUTF8))).1 matches
              .finished (.error (.unparsable _)) }]

/-- The git implementation's worktree list in `/r` on `model`. -/
def gitWorktrees (model : JobModel) :
    Job.Outcome (Except VersionControl.Error (Array VersionControl.Worktree)) × JobModel :=
  (VersionControl.Git.handler "git" "/r" .worktrees :
        JobM (Except VersionControl.Error (Array VersionControl.Worktree))).runModel
    model

/-- The git implementation's branch list in `/r` on `model`. -/
def gitBranches (model : JobModel) :
    Job.Outcome (Except VersionControl.Error (Array String)) × JobModel :=
  (VersionControl.Git.handler "git" "/r" .branches :
        JobM (Except VersionControl.Error (Array String))).runModel
    model

/-- The git implementation's change of `revision` against `against` in `/r`
on `model`. -/
def gitChanges (revision against : String) (model : JobModel) :
    Job.Outcome (Except VersionControl.Error VersionControl.Changes) × JobModel :=
  (VersionControl.Git.handler "git" "/r" (.changes revision against) :
        JobM (Except VersionControl.Error VersionControl.Changes)).runModel
    model

/-- The git implementation's making of a worktree in `/r` on `model`. -/
def gitAddWorktree (path : System.FilePath) (branch : String) (start : Option String)
    (model : JobModel) : Job.Outcome (Except VersionControl.Error Unit) × JobModel :=
  (VersionControl.Git.handler "git" "/r" (.addWorktree path branch start) :
        JobM (Except VersionControl.Error Unit)).runModel
    model

/-- The git implementation's removal of a worktree in `/r` on `model`. -/
def gitRemoveWorktree (path : System.FilePath) (model : JobModel) :
    Job.Outcome (Except VersionControl.Error Unit) × JobModel :=
  (VersionControl.Git.handler "git" "/r" (.removeWorktree path) :
        JobM (Except VersionControl.Error Unit)).runModel
    model

/-- The command that makes or removes a worktree from `/r` with `arguments`:
under the environment of a commit, which git hands its hooks. -/
def gitWorktreeRun (arguments : Array String) : Process.Command :=
  { gitRun arguments with environment := gitCommitRun.environment }

/-- A script of `command` that exits `status` having printed `stdout`, taking
`takes` milliseconds. -/
def printing (command : Process.Command) (stdout : String) (status : Nat := 0) (takes : Nat := 0) :
    Process.Script :=
  { command, takes,
    reply := .ok { exit := .code status, stdout := stdout.toUTF8, stderr := .empty } }

/-- The scripts of a change of `feature` against `main` in `/r`: each name
resolved, their merge base `B`, a raw diff of `a` modified, `c` added, `d`
deleted and a submodule `sub` added, and the batch of the four blobs. -/
def changesScripts : Array Process.Script :=
  #[printing (gitRun #["rev-parse", "--verify", "--quiet", "feature^{commit}"]) "F\n",
    printing (gitRun #["rev-parse", "--verify", "--quiet", "main^{commit}"]) "M\n",
    printing (gitRun #["merge-base", "F", "M"]) "B\n",
    printing (gitRun #["diff-tree", "-r", "-z", "--no-renames", "B", "F"])
      (":100644 100644 a1 a2 M\x00a\x00:000000 100644 0 c1 A\x00c\x00" ++
        ":100644 000000 d1 0 D\x00d\x00:000000 160000 0 s1 A\x00sub\x00"),
    printing (gitRun #["cat-file", "--batch"])
      "a1 blob 2\n1\n\na2 blob 2\n2\n\nc1 blob 4\nnew\n\nd1 blob 2\nd\n\n"]

/-- The checks of the git implementation's worktrees, branches and changes
(`Editor/VersionControl/Git.lean`) on the job model: the command lines, their
environments and limits, and how what they answer is read. -/
def versionControlWorktreeGitChecks : List Check :=
  let listRun := gitRun #["worktree", "list", "--porcelain", "-z"]
  let linked : VersionControl.Model.Repository :=
    { VersionControlContract.clean
        #[("a", "a")] with
      branches := #[("b", "head")]
      linked := #[{ path := "/w", branch := some "b" }, { path := "/d", branch := none }] }
  let changesModel : JobModel := { processes := { scripts := changesScripts } }
  let resolveRun (name : String) :=
    gitRun #["rev-parse", "--verify", "--quiet", s!"{name}^\{commit}"]
  let addRun := gitWorktreeRun #["worktree", "add", "--quiet", "-b", "f", "/f", "HEAD"]
  let existsRun (branch : String) :=
    gitRun #["rev-parse", "--verify", "--quiet", s!"refs/heads/{branch}"]
  let deleteRun := gitRun #["branch", "-D", "f"]
  let addModel (takes : Nat) : JobModel :=
    {
      processes :=
        {
          scripts :=
            #[printing (existsRun "f") "" 1, printing addRun "" (takes := takes),
              printing deleteRun ""] } }
  [{  name :=
        "a worktree list runs git worktree list --porcelain -z in the root, once, under the environment of every read, and reads the main worktree first and the linked ones in path order"
      run :=
        pure <|
          let (reply, after) := gitWorktrees (linked.jobModel "git" "/r")
          reply ==
              .finished
                (.ok
                  #[{ path := "/r", head := .branch "main" }, { path := "/d", head := .detached },
                    { path := "/w", head := .branch "b" }]) &&
            after.processes.started == #[listRun] },
    { name :=
        "a branch list runs git for-each-ref --format=%(refname) refs/heads/ in the root and reads the names"
      run :=
        pure <|
          let run := gitRun #["for-each-ref", "--format=%(refname)", "refs/heads/"]
          let (reply, after) :=
            gitBranches
              { processes := { scripts := #[printing run "refs/heads/main\nrefs/heads/a/b\n"] } }
          reply == .finished (.ok #["a/b", "main"]) && after.processes.started == #[run] },
    { name := "a worktree list git answers with what cannot be read is unparsable"
      run :=
        pure <|
          (gitWorktrees
                { processes := { scripts := #[printing listRun "HEAD 0\x00\x00"] } }).1 matches
            .finished (.error (.unparsable _)) },
    { name :=
        "a change resolves both names to commits, reads their merge base, the raw diff of the revision against it, and every blob in one cat-file --batch fed their ids a line each; a submodule's side is its commit as git prints it"
      run :=
        pure <|
          let (reply, after) := gitChanges "feature" "main" changesModel
          reply ==
              .finished
                (.ok
                  { base := "B", tip := "F"
                    files :=
                      #[{ path := "a", old := some "1\n", new := some "2\n" },
                        { path := "c", old := none, new := some "new\n" },
                        { path := "d", old := some "d\n", new := none },
                        { path := "sub", old := none, new := some "Subproject commit s1\n" }] }) &&
            after.processes.started == changesScripts.map (·.command) &&
            after.processes.fed ==
              #[(gitRun #["cat-file", "--batch"], "a1\na2\nc1\nd1\n".toUTF8)] },
    { name :=
        "a name rev-parse refuses with status 1 is not a commit, refused with status 1, and nothing more runs"
      run :=
        pure <|
          let model : JobModel :=
            { processes := { scripts := #[printing (resolveRun "nope") "" 1] } }
          let (reply, after) := gitChanges "nope" "main" model
          reply == .finished (.error (.failed (.code 1) "nope is not a commit")) &&
            after.processes.started == #[resolveRun "nope"] },
    { name :=
        "two commits merge-base answers with status 1 and nothing printed have no merge base, refused with status 1, and nothing more runs"
      run :=
        pure <|
          let model : JobModel :=
            {
              processes :=
                {
                  scripts :=
                    (changesScripts.extract 0 2) ++
                      #[printing (gitRun #["merge-base", "F", "M"]) "" 1] } }
          let (reply, after) := gitChanges "feature" "main" model
          reply == .finished (.error (.failed (.code 1) "feature and main have no merge base")) &&
            after.processes.started == (changesScripts.extract 0 3).map (·.command) },
    { name := "a batch that does not name an id asked for is unparsable"
      run :=
        pure <|
          let model : JobModel :=
            {
              processes :=
                {
                  scripts :=
                    (changesScripts.extract 0 4) ++
                      #[printing (gitRun #["cat-file", "--batch"]) "a1 blob 2\n1\n\n"] } }
          (gitChanges "feature" "main" model).1 matches .finished (.error (.unparsable _)) },
    { name :=
        "a name that starts with -, and a worktree path that is not absolute, are refused as invalid before any process starts"
      run :=
        pure <|
          let invalid {α : Type} : Job.Outcome (Except VersionControl.Error α) × JobModel → Bool
            | (.finished (.error (.invalid _)), after) => after.processes.started.isEmpty
            | _ => false
          invalid (gitChanges "-x" "main" {}) && invalid (gitChanges "main" "-x" {}) &&
            invalid (gitAddWorktree "f" "f" (some "HEAD") {}) &&
            invalid (gitAddWorktree "/f" "-f" (some "HEAD") {}) &&
            invalid (gitAddWorktree "/f" "f" (some "--orphan") {}) &&
            invalid (gitRemoveWorktree "w" {}) },
    { name :=
        "creating a worktree for a new branch checks there is no local branch of that name, then runs git worktree add --quiet -b and the branch, the path and the start, under a commit's environment, within the worktree time limit and not the read's; one that could not run deletes nothing"
      run :=
        pure <|
          let (reply, after) :=
            gitAddWorktree "/f" "f" (some "HEAD") (addModel (VersionControl.Git.gitTime + 1))
          let (late, lateAfter) :=
            gitAddWorktree "/f" "f" (some "HEAD") (addModel (VersionControl.Git.worktreeTime + 1))
          reply == .finished (.ok ()) && after.processes.started == #[existsRun "f", addRun] &&
            late == .finished (.error (.couldNotRun (.timedOut VersionControl.Git.worktreeTime))) &&
            lateAfter.processes.started == #[existsRun "f", addRun] },
    { name :=
        "creating a worktree for a new branch whose name a local branch has is refused with status 128 before git worktree add runs"
      run :=
        pure <|
          let (reply, after) :=
            gitAddWorktree "/f" "f" (some "HEAD")
              { processes := { scripts := #[printing (existsRun "f") "0\n", printing addRun ""] } }
          reply ==
              .finished (.error (.failed (.code 128) "fatal: a branch named 'f' already exists")) &&
            after.processes.started == #[existsRun "f"] },
    { name :=
        "a worktree for a new branch that git worktree add refuses is refused with git's status and message, and the branch git made first is deleted with git branch -D, so a refusal leaves the branches as they were"
      run :=
        pure <|
          let refusing : Process.Script :=
            { command := addRun,
              reply :=
                .ok {
                    exit := .code 128, stdout := .empty
                    stderr := "fatal: '/f' already exists\n".toUTF8 } }
          let (reply, after) :=
            gitAddWorktree "/f" "f" (some "HEAD")
              {
                processes :=
                  {
                    scripts :=
                      #[printing (existsRun "f") "" 1, refusing, printing deleteRun "" 1] } }
          reply == .finished (.error (.failed (.code 128) "fatal: '/f' already exists")) &&
            after.processes.started == #[existsRun "f", addRun, deleteRun] },
    { name :=
        "creating a worktree on an existing branch checks the branch is a local one, then runs git worktree add --quiet and the path and the branch; a branch that is not there is refused with status 128 before git worktree add runs"
      run :=
        pure <|
          let add := gitWorktreeRun #["worktree", "add", "--quiet", "/f", "b"]
          let (reply, after) :=
            gitAddWorktree "/f" "b" none
              { processes := { scripts := #[printing (existsRun "b") "0\n", printing add ""] } }
          let (missing, refused) :=
            gitAddWorktree "/f" "b" none
              { processes := { scripts := #[printing (existsRun "b") "" 1, printing add ""] } }
          reply == .finished (.ok ()) && after.processes.started == #[existsRun "b", add] &&
            missing == .finished (.error (.failed (.code 128) "fatal: invalid reference: b")) &&
            refused.processes.started == #[existsRun "b"] },
    { name :=
        "removing a worktree runs git -c status.showUntrackedFiles=normal worktree remove and the path, under a commit's environment, and a refusal is git's"
      run :=
        pure <|
          let remove :=
            gitWorktreeRun #["-c", "status.showUntrackedFiles=normal", "worktree", "remove", "/w"]
          let (reply, after) :=
            gitRemoveWorktree "/w" { processes := { scripts := #[printing remove ""] } }
          let (refused, _) :=
            gitRemoveWorktree "/w"
              {
                processes :=
                  {
                    scripts :=
                      #[{ command := remove
                          reply :=
                            .ok {
                                exit := .code 128, stdout := .empty
                                stderr := "fatal: '/w' is a main working tree\n".toUTF8 } }] } }
          reply == .finished (.ok ()) && after.processes.started == #[remove] &&
            refused ==
              .finished (.error (.failed (.code 128) "fatal: '/w' is a main working tree")) }]

/-- The git implementation's read of `path` at `revision` in `/r` on
`model`. -/
def gitShow (revision path : String) (model : JobModel) :
    Job.Outcome (Except VersionControl.Error (Option String)) × JobModel :=
  (VersionControl.Git.handler "git" "/r" (.fileAt revision path) :
        JobM (Except VersionControl.Error (Option String))).runModel
    model

/-- The git implementation's question of what to watch in `/r` on
`model`. -/
def gitWatched (model : JobModel) :
    Job.Outcome (Except VersionControl.Error VersionControl.Watched) × JobModel :=
  (VersionControl.Git.handler "git" "/r" .watched :
        JobM (Except VersionControl.Error VersionControl.Watched)).runModel
    model

/-- The job model in which `git rev-parse --git-dir --git-common-dir` in `/r`
prints `stdout`. -/
def watchedAnswering (stdout : String) : JobModel :=
  {
    processes :=
      {
        scripts :=
          #[{ command := gitRun #["rev-parse", "--git-dir", "--git-common-dir"]
              reply := VersionControl.Model.Repository.ran stdout.toUTF8 }] } }

/-- The checks of the git implementation's `show` and `watched` on the job
model: the command lines they run, and how they read what those answer. -/
def versionControlShowChecks : List Check :=
  let repository : VersionControl.Model.Repository :=
    { VersionControlContract.clean #[("src/a.txt", "one\n")] with
      revisions := #[("v1", #[("src/a.txt", "then\n")])] }
  let blob := VersionControl.Model.blobId
  [{  name :=
        "fileAt runs git rev-parse --verify --quiet <revision>:<path> in the root, then git cat-file blob with the id it printed, and answers the blob's content"
      run :=
        pure <|
          let (head, after) := gitShow "HEAD" "src/a.txt" (repository.jobModel "git" "/r")
          let (named, _) := gitShow "v1" "src/a.txt" (repository.jobModel "git" "/r")
          head == .finished (.ok (some "one\n")) && named == .finished (.ok (some "then\n")) &&
            after.processes.started ==
              #[gitRun #["rev-parse", "--verify", "--quiet", "HEAD:src/a.txt"],
                gitRun #["cat-file", "blob", blob "one\n"]] },
    { name := "fileAt of a path the revision lacks is none: rev-parse exits 1 and no cat-file runs"
      run :=
        pure <|
          let model := repository.jobModel "git" "/r" (missing := #[("HEAD", "n.txt")])
          let (missing, after) := gitShow "HEAD" "n.txt" model
          missing == .finished (.ok none) &&
            after.processes.started ==
              #[gitRun #["rev-parse", "--verify", "--quiet", "HEAD:n.txt"]] },
    { name := "fileAt whose rev-parse fails otherwise failed, with what git said"
      run :=
        pure <|
          let model : JobModel :=
            {
              processes :=
                {
                  scripts :=
                    #[{ command := gitRun #["rev-parse", "--verify", "--quiet", "HEAD:a.txt"]
                        reply :=
                          .ok {
                              exit := .code 128, stdout := .empty
                              stderr := "fatal: not a git repository\n".toUTF8 } }] } }
          (gitShow "HEAD" "a.txt" model).1 ==
            .finished (.error (.failed (.code 128) "fatal: not a git repository")) },
    { name :=
        "watched runs git rev-parse --git-dir --git-common-dir in the root, resolves what is relative against it, and names HEAD and the index of the git directory, the common directory's packed-refs, and its refs as a tree"
      run :=
        pure <|
          let (main, after) := gitWatched (watchedAnswering ".git\n.git\n")
          let (linked, _) := gitWatched (watchedAnswering "/m/.git/worktrees/w\n/m/.git\n")
          main ==
              .finished
                (.ok
                  { directory := "/r/.git",
                    paths := #["/r/.git/HEAD", "/r/.git/index", "/r/.git/packed-refs"]
                    trees := #["/r/.git/refs"] }) &&
            linked ==
              .finished
                (.ok
                  { directory := "/m/.git"
                    paths :=
                      #["/m/.git/worktrees/w/HEAD", "/m/.git/worktrees/w/index",
                        "/m/.git/packed-refs"]
                    trees := #["/m/.git/refs"] }) &&
            after.processes.started == #[gitRun #["rev-parse", "--git-dir", "--git-common-dir"]] },
    { name := "watched whose output is not two lines is unparsable"
      run :=
        pure <|
          (gitWatched (watchedAnswering ".git\n")).1 matches .finished (.error (.unparsable _)) },
    { name :=
        "a change matters at HEAD, the index, packed-refs or under refs, and when changes were missed; not at a lock file, an object or a log"
      run :=
        pure <|
          let watched : VersionControl.Watched :=
            { directory := "/r/.git",
              paths := #["/r/.git/HEAD", "/r/.git/index", "/r/.git/packed-refs"]
              trees := #["/r/.git/refs"] }
          let at_ (path : System.FilePath) (kinds : FileWatch.Kinds := { written := true }) :=
            watched.matters { path, kinds }
          at_ "/r/.git/HEAD" && at_ "/r/.git/index" && at_ "/r/.git/packed-refs" &&
            at_ "/r/.git/refs/heads/main" &&
            at_ "/r/.git" { missed := true } &&
            !at_ "/r/.git/index.lock" &&
            !at_ "/r/.git/refs/heads/main.lock" &&
            !at_ "/r/.git/objects/ab/cdef" &&
            !at_ "/r/.git/logs/HEAD" &&
            !at_ "/r/.git/refsx" },
    { name :=
        "the model answers fileAt from HEAD's files, a named revision's, and the index for the empty revision, and none otherwise; and watched from its git and common directories"
      run :=
        pure <|
          let fileAt (repository : VersionControl.Model.Repository) (revision : String) :
            Except VersionControl.Error (Option String) :=
            (VersionControl.Model.handle (.fileAt revision "src/a.txt") repository).1
          let watched : Except VersionControl.Error VersionControl.Watched :=
            (VersionControl.Model.handle .watched repository).1
          let staged := { repository with index := #[("src/a.txt", .file "staged\n")] }
          fileAt repository "HEAD" == .ok (some "one\n") &&
            fileAt repository "v1" == .ok (some "then\n") &&
            fileAt staged "" == .ok (some "staged\n") &&
            fileAt repository "v2" == .ok none &&
            watched ==
              .ok {
                  directory := "/r/.git",
                  paths := #["/r/.git/HEAD", "/r/.git/index", "/r/.git/packed-refs"]
                  trees := #["/r/.git/refs"] } }]

end ModelTest

namespace ModelTest

open Editor

/-- The git implementation's log of `revision` in `/r` on `model`. -/
def gitLog (revision : String) (limit : Nat) (model : JobModel) :
    Job.Outcome (Except VersionControl.Error (Array VersionControl.LogEntry)) × JobModel :=
  (VersionControl.Git.handler "git" "/r" (.log revision limit) :
        JobM (Except VersionControl.Error (Array VersionControl.LogEntry))).runModel
    model

/-- The git implementation's blame of `path` at `revision` in `/r` on
`model`. -/
def gitBlame (revision path : String) (model : JobModel) :
    Job.Outcome (Except VersionControl.Error (Option VersionControl.Blame)) × JobModel :=
  (VersionControl.Git.handler "git" "/r" (.blame revision path) :
        JobM (Except VersionControl.Error (Option VersionControl.Blame))).runModel
    model

/-- The git implementation's range-diff in `/r` on `model`. -/
def gitRangeDiff (base old new : String) (model : JobModel) :
    Job.Outcome (Except VersionControl.Error VersionControl.RangeDiff) × JobModel :=
  (VersionControl.Git.handler "git" "/r" (.rangeDiff base old new) :
        JobM (Except VersionControl.Error VersionControl.RangeDiff)).runModel
    model

/-- The command that resolves `name` to a commit in `/r`. -/
def resolveRun (name : String) : Process.Command :=
  gitRun #["rev-parse", "--verify", "--quiet", s!"{name}^\{commit}"]

/-- The command a log of the commit `id` runs in `/r`, at most `limit`. -/
def logRun (id : String) (limit : Nat) : Process.Command :=
  gitRun
    #["rev-list", "--first-parent", s!"--max-count={limit}", "--no-commit-header",
      "--encoding=UTF-8", "--format=%H%x00%P%x00%an%x00%at%x00%s", id, "--"]

/-- The command a blame of `path` at the commit `id` runs in `/r`. -/
def blameRun (id path : String) : Process.Command :=
  gitRun #["blame", "--porcelain", "--ignore-revs-file=", id, "--", path]

/-- The checks of the git implementation's history reads
(`Editor/VersionControl/Git.lean`) on the job model: the command lines of
a log, a blame, a range-diff and a change against no base, and how what
they answer is read. -/
def versionControlHistoryGitChecks : List Check :=
  let authored : VersionControl.Authored := { author := "Bé", time := 7, subject := "s" }
  let blamed :=
    "H 1 1 1\nauthor Bé\nauthor-mail <a@example.com>\nauthor-time 7\nsummary s\nfilename a\n\tone\n"
  let rangeRun :=
    gitRun #["range-diff", "--no-color", "--no-notes", "--creation-factor=60", "B", "O", "N"]
  [{  name :=
        "a log resolves its revision to a commit, then runs git rev-list --first-parent --max-count=<limit> --no-commit-header --encoding=UTF-8 with the format of five NUL-separated fields, on the id and --, and reads each commit"
      run :=
        pure <|
          let model : JobModel :=
            {
              processes :=
                {
                  scripts :=
                    #[printing (resolveRun "main") "H\n",
                      printing (logRun "H" 3) "H\x00P\x00Bé\x007\x00s\nP\x00\x00a\x001\x00p\n"] } }
          let (reply, after) := gitLog "main" 3 model
          reply ==
              .finished
                (.ok
                  #[{ id := "H", parents := #["P"], authored },
                    { id := "P", authored := { author := "a", time := 1, subject := "p" } }]) &&
            after.processes.started == #[resolveRun "main", logRun "H" 3] },
    { name :=
        "a log of a name rev-parse refuses is not a commit, refused with status 1, and nothing more runs"
      run :=
        pure <|
          let model : JobModel :=
            { processes := { scripts := #[printing (resolveRun "nope") "" 1] } }
          let (reply, after) := gitLog "nope" 3 model
          reply == .finished (.error (.failed (.code 1) "nope is not a commit")) &&
            after.processes.started == #[resolveRun "nope"] },
    { name := "a log git prints what cannot be read of is unparsable"
      run :=
        pure <|
          let model : JobModel :=
            {
              processes :=
                {
                  scripts :=
                    #[printing (resolveRun "main") "H\n", printing (logRun "H" 3) "H\x00\n"] } }
          (gitLog "main" 3 model).1 matches .finished (.error (.unparsable _)) },
    { name :=
        "a blame resolves its revision, checks the path is there with git rev-parse --verify --quiet <id>:<path>, then runs git blame --porcelain --ignore-revs-file= <id> -- <path> and reads each line's commit and author"
      run :=
        pure <|
          let model : JobModel :=
            {
              processes :=
                {
                  scripts :=
                    #[printing (resolveRun "HEAD") "H\n",
                      printing (gitRun #["rev-parse", "--verify", "--quiet", "H:a"]) "X\n",
                      printing (blameRun "H" "a") blamed] } }
          let (reply, after) := gitBlame "HEAD" "a" model
          reply ==
              .finished
                (.ok
                  (some
                    { commits := #[("H", authored)], lines := #[{ id := "H", text := "one" }] })) &&
            after.processes.started ==
              #[resolveRun "HEAD", gitRun #["rev-parse", "--verify", "--quiet", "H:a"],
                blameRun "H" "a"] },
    { name := "a blame of a path rev-parse says the revision lacks is none, and no blame runs"
      run :=
        pure <|
          let model : JobModel :=
            {
              processes :=
                {
                  scripts :=
                    #[printing (resolveRun "HEAD") "H\n",
                      printing (gitRun #["rev-parse", "--verify", "--quiet", "H:nope"]) "" 1] } }
          let (reply, after) := gitBlame "HEAD" "nope" model
          reply == .finished (.ok none) &&
            after.processes.started ==
              #[resolveRun "HEAD", gitRun #["rev-parse", "--verify", "--quiet", "H:nope"]] },
    { name :=
        "a range-diff resolves its three names, then runs git range-diff --no-color --no-notes --creation-factor=60 on the ids, and reads its pairs and keeps its text"
      run :=
        pure <|
          let printed := "1:  1111111 = 1:  2222222 p\n-:  ------- > 2:  3333333 q\n"
          let model : JobModel :=
            {
              processes :=
                {
                  scripts :=
                    #[printing (resolveRun "base") "B\n", printing (resolveRun "old") "O\n",
                      printing (resolveRun "HEAD") "N\n", printing rangeRun printed] } }
          let (reply, after) := gitRangeDiff "base" "old" "HEAD" model
          reply ==
              .finished
                (.ok
                  { pairs :=
                      #[{ old := some 1, new := some 1, relation := .same },
                        { old := none, new := some 2, relation := .added }]
                    text := printed }) &&
            after.processes.started ==
              #[resolveRun "base", resolveRun "old", resolveRun "HEAD", rangeRun] },
    { name :=
        "a change against no base resolves its revision, hashes the empty tree with git hash-object -t tree --stdin fed nothing, and diffs the revision against it: every file added, the base empty and the tip the revision's id"
      run :=
        pure <|
          let hashRun := gitRun #["hash-object", "-t", "tree", "--stdin"]
          let model : JobModel :=
            {
              processes :=
                {
                  scripts :=
                    #[printing (resolveRun "R") "R\n", printing hashRun "E\n",
                      printing (gitRun #["diff-tree", "-r", "-z", "--no-renames", "E", "R"])
                        ":000000 100644 0 a1 A\x00a\x00",
                      printing (gitRun #["cat-file", "--batch"]) "a1 blob 2\n1\n\n"] } }
          let (reply, after) := gitChanges "R" "" model
          reply ==
              .finished
                (.ok
                  { base := "", tip := "R"
                    files := #[{ path := "a", old := none, new := some "1\n" }] }) &&
            after.processes.started.map (·.arguments) ==
              #[(resolveRun "R").arguments, hashRun.arguments,
                #["diff-tree", "-r", "-z", "--no-renames", "E", "R"], #["cat-file", "--batch"]] &&
            after.processes.fed.find? (·.1 == hashRun) == some (hashRun, .empty) },
    { name :=
        "a log, a blame or a range-diff of a name that starts with - is refused before any process starts"
      run :=
        pure <|
          let refusedFirst {α : Type} :
            Job.Outcome (Except VersionControl.Error α) × JobModel → Bool
            | (.finished (.error (.invalid _)), after) => after.processes.started.isEmpty
            | _ => false
          refusedFirst (gitLog "-x" 1 {}) && refusedFirst (gitBlame "-x" "a" {}) &&
            refusedFirst (gitRangeDiff "b" "o" "--n" {}) }]

end ModelTest
