import Editor.InputScheme.Test
import Editor.Loop
import Editor.Loop.Driver
import Editor.Mode
import Editor.Process
import Editor.Process.Model
import Editor.Role
import Editor.State
import Editor.Text
import Editor.VersionControl
import Editor.VersionControl.Contract
import Editor.VersionControl.Git
import Editor.VersionControl.Model
import Editor.VersionControl.Status
import Editor.Workspace
import ModelTest.Check
import ModelTest.Support.Driver
import ModelTest.Support.Git
import ModelTest.Support.Keys
import ModelTest.Support.Shell
import ModelTest.Support.VersionControl
import ModelTest.Support.Workspace

/-!
# Model tests: `Editor/VersionControl/Status.lean`

The model tests of `Editor/VersionControl/Status.lean`: `statusViewChecks` and
`statusBufferChecks`. The root module `ModelTest` runs them; its module doc says
what each shows.
-/

namespace ModelTest

open Editor

/-- What the status buffer of `r@main` shows of the contract's first
repository (`VersionControlContract.criterionStatus`): the head line, then
one line per file naming its state. -/
def criterionText : String :=
  "r@main: on main\n" ++ "conflicted: conflict.txt (both modified)\n" ++
    "renamed: new.txt (from old.txt)\n" ++
    "staged: staged.txt (modified)\n" ++
    "unstaged: unstaged.txt (modified)\n" ++
    "untracked: untracked.txt\n"

/-- The sentence `reply` refuses with; empty for a request. -/
def requestRefusal (reply : Except String VersionControl.Request) : String :=
  match reply with
  | .error sentence => sentence
  | .ok _ => ""

/-- The checks of the status buffer's pure view
(`Editor/VersionControl/Status.lean`, `StatusView`), on values the model
gives. -/
def statusViewChecks : List Check :=
  let files := VersionControlContract.criterionStatus.files
  let file (path : String) (state : VersionControl.FileState) : VersionControl.FileStatus :=
    { path, state }
  [{  name :=
        "criterion 2: the status of the contract's first repository renders as its head, then one line per changed file naming its state: conflicted, renamed, staged, unstaged and untracked"
      run :=
        pure
          (VersionControl.StatusView.render "r@main" VersionControlContract.criterionStatus ==
            criterionText) },
    { name := "a status with no files renders as its head and a line saying there are no changes"
      run :=
        pure <|
          VersionControl.StatusView.render "r@x" { head := .detached } ==
            "r@x: detached\nno changes\n" },
    { name :=
        "a file staged and unstaged, a rename changed since, a staged addition, an unstaged deletion and each kind of conflict each say so on their line"
      run :=
        pure <|
          (#[file "m.txt" (.changed (some .modified) (some .modified)),
                  file "n.txt" (.renamed "o.txt" (some .modified)),
                  file "a.txt" (.changed (some .added) none),
                  file "g.txt" (.changed none (some .deleted)), file "c1" (.conflicted .bothAdded),
                  file "c2" (.conflicted .bothDeleted), file "c3" (.conflicted .addedByUs),
                  file "c4" (.conflicted .addedByThem), file "c5" (.conflicted .deletedByUs),
                  file "c6" (.conflicted .deletedByThem)].map
              VersionControl.StatusView.line) ==
            #["staged, unstaged: m.txt (modified, modified)",
              "renamed, unstaged: n.txt (from o.txt, modified)", "staged: a.txt (added)",
              "unstaged: g.txt (deleted)", "conflicted: c1 (both added)",
              "conflicted: c2 (both deleted)", "conflicted: c3 (added by us)",
              "conflicted: c4 (added by them)", "conflicted: c5 (deleted by us)",
              "conflicted: c6 (deleted by them)"] },
    { name := "the file on a row is the row's line's: none on the head line or past the last"
      run :=
        pure <|
          VersionControl.StatusView.fileAt files 0 == none &&
            VersionControl.StatusView.fileAt files 1 == files[0]? &&
            VersionControl.StatusView.fileAt files 5 == files[4]? &&
            VersionControl.StatusView.fileAt files 6 == none },
    { name :=
        "a file is deleted when it is gone from the working tree: an unstaged deletion, a change deleted since, a rename deleted since and a staged deletion its status does not also list untracked; not a staged deletion still on disk, a modification, an untracked file or a conflict, whose file the status cannot say is gone"
      run :=
        pure <|
          let deleted := VersionControl.StatusView.deleted
          let removed := file "r" (.changed (some .deleted) none)
          let kept := file "k" (.changed (some .deleted) none)
          let onDisk := #[kept, file "k" .untracked]
          deleted #[] (file "g" (.changed none (some .deleted))) &&
            deleted #[] (file "m" (.changed (some .modified) (some .deleted))) &&
            deleted #[] (file "n" (.renamed "o" (some .deleted))) &&
            deleted #[removed, file "k" .untracked] removed &&
            !deleted onDisk kept &&
            !deleted #[] (file "s" (.changed (some .modified) none)) &&
            !deleted #[] (file "u" (.changed none (some .modified))) &&
            !deleted #[] (file "t" .untracked) &&
            !deleted #[] (file "c" (.conflicted .bothDeleted)) &&
            !deleted #[] (file "d" (.conflicted .deletedByUs)) },
    { name :=
        "toggling stages an untracked, a conflicted or an unstaged file, and unstages a staged one, a staged rename by both its paths"
      run :=
        pure <|
          let toggle := VersionControl.StatusView.toggleRequest
          toggle (file "u" .untracked) == .stage #["u"] &&
            toggle (file "c" (.conflicted .bothModified)) == .stage #["c"] &&
            toggle (file "m" (.changed (some .modified) (some .modified))) == .stage #["m"] &&
            toggle (file "w" (.changed none (some .deleted))) == .stage #["w"] &&
            toggle (file "n" (.renamed "o" (some .modified))) == .stage #["n"] &&
            toggle (file "s" (.changed (some .modified) none)) == .unstage #["s"] &&
            toggle (file "n" (.renamed "o" none)) == .unstage #["n", "o"] },
    { name :=
        "staging explicitly refuses a file with nothing to stage, and unstaging one with nothing staged, each with a sentence"
      run :=
        pure <|
          requestRefusal
                (VersionControl.StatusView.stageRequest
                  (file "s" (.changed (some .modified) none))) ==
              "vc-status-stage: s has nothing to stage" &&
            requestRefusal (VersionControl.StatusView.unstageRequest (file "u" .untracked)) ==
              "vc-status-unstage: u has nothing staged" &&
            requestRefusal
                (VersionControl.StatusView.unstageRequest (file "c" (.conflicted .bothModified))) ==
              "vc-status-unstage: c has nothing staged" &&
            (VersionControl.StatusView.stageRequest
                  (file "m" (.changed (some .modified) (some .modified)))).toOption ==
              some (.stage #["m"]) &&
            (VersionControl.StatusView.unstageRequest
                  (file "m" (.changed (some .modified) (some .modified)))).toOption ==
              some (.unstage #["m"]) &&
            (VersionControl.StatusView.unstageRequest
                  (file "n" (.renamed "o" (some .modified)))).toOption ==
              some (.unstage #["n", "o"]) }]

/-- The writes the status buffer checks expect git to be asked for in `/r`. -/
def statusWrites : Array VersionControl.Request :=
  #[.stage #["unstaged.txt"], .unstage #["staged.txt"], .unstage #["new.txt", "old.txt"]]

/-- The driver of the status buffer checks over the contract's first
repository, answering `statusWrites` (`statusDriverOf`). -/
def statusDriver : Option TestDriver :=
  statusDriverOf VersionControlContract.criterionRepository statusWrites

/-- The byte offset where the row `row` of `text` starts. -/
def rowOffset (text : String) (row : Nat) : Nat :=
  ((text.splitOn "\n").take row).foldl (fun offset line => offset + line.utf8ByteSize + 1) 0

/-- The checks of the status buffer (`Editor/VersionControl/Status.lean`), on
the loop's driver over the editor's models, the job model and the model of a
repository in `/r`. -/
def statusBufferChecks : List Check :=
  let statusRead := gitRun VersionControl.Git.statusArguments
  [{  name :=
        "vc-status in a buffer with no workspace says so, and makes no buffer and starts no job"
      run :=
        pure <|
          match statusDriver with
          | none => false
          | some driver =>
            let asked := settledAfter driver "C-v s"
            echoOf asked == some s!"vc-status: {EditorState.scratchName} has no workspace" &&
              (asked.loop.state.buffers.filterMap id).all (!·.name.startsWith "*vc-status") &&
              gitStarted asked == #[] },
    { name := "vc-status in a workspace that cannot run commands says so, and starts no job"
      run :=
        pure <|
          match statusDriver with
          | none => false
          | some driver =>
            let asked := settledAfter (settledAfter (settledAfter driver "C-o a") "C-v k") "C-v s"
            ((echoOf asked).map fun echo =>
                  echo.startsWith "vc-status: " && echo.endsWith " cannot run commands") ==
                some true &&
              (gitStarted asked).all (· != statusRead) },
    { name :=
        "criterion 2: vc-status starts vc-status-read under its workspace's key; once it is settled the buffer *vc-status: r@main* is read-only, in the mode vc-status, of the workspace /r, focused, and shows one line per changed file naming its state"
      run :=
        pure <|
          match statusDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let asking := (fedTo opened (presses "C-v s")).1
            let shown := settledAfter opened "C-v s"
            let state := shown.loop.state
            asking.pending.map (fun job => (job.name, job.key)) ==
                #[(VersionControl.readJob, some "vc-status local /r")] &&
              match state.findBuffer statusBufferName with
              | none => false
              | some id =>
                (state.buffer? id).map (·.readOnly) == some true &&
                  (state.buffer? id).bind (·.major) == some VersionControl.modeName &&
                  (state.workspaceOf? id).map (·.1.location) == some (.local "/r") &&
                  (showingFocused shown).map (·.id) == some id &&
                  namedText shown statusBufferName == some criterionText &&
                  gitStarted shown == #[statusRead] },
    { name :=
        "criterion 3: toggling on an unstaged file's line runs git add --all -- and that path in the root, then reads the status again into the same buffer, the cursor kept on its row"
      run :=
        pure <|
          match statusDriver with
          | none => false
          | some driver =>
            let shown := settledAfter (settledAfter driver "C-o a") "C-v s"
            let toggled := settledAfter shown "C-v 4 C-v t"
            gitStarted toggled ==
                #[statusRead, gitRun #["add", "--all", "--", "unstaged.txt"], statusRead] &&
              namedText toggled statusBufferName == some criterionText &&
              ((showingFocused toggled).bind (·.cursors)).map (·.map (·.head)) ==
                some #[rowOffset criterionText 4] &&
              ((toggled.loop.state.buffers.filterMap id).filter
                    (·.name.startsWith "*vc-status")).size ==
                1 },
    { name :=
        "criterion 4: toggling on a staged file's line runs git reset -q -- and that path in the root, and on a staged rename's line both its paths"
      run :=
        pure <|
          match statusDriver with
          | none => false
          | some driver =>
            let shown := settledAfter (settledAfter driver "C-o a") "C-v s"
            let staged := settledAfter shown "C-v 3 C-v t"
            let renamed := settledAfter shown "C-v 2 C-v t"
            gitStarted staged ==
                #[statusRead, gitRun #["reset", "-q", "--", "staged.txt"], statusRead] &&
              gitStarted renamed ==
                #[statusRead, gitRun #["reset", "-q", "--", "new.txt", "old.txt"], statusRead] },
    { name :=
        "the explicit stage and unstage run the same writes, and say so when the line's file has nothing to stage or nothing staged"
      run :=
        pure <|
          match statusDriver with
          | none => false
          | some driver =>
            let shown := settledAfter (settledAfter driver "C-o a") "C-v s"
            let staged := settledAfter shown "C-v 4 C-v a"
            let unstaged := settledAfter shown "C-v 3 C-v u"
            let nothingStaged := settledAfter shown "C-v 5 C-v u"
            let nothingToStage := settledAfter shown "C-v 3 C-v a"
            gitStarted staged ==
                #[statusRead, gitRun #["add", "--all", "--", "unstaged.txt"], statusRead] &&
              gitStarted unstaged ==
                #[statusRead, gitRun #["reset", "-q", "--", "staged.txt"], statusRead] &&
              echoOf nothingStaged == some "vc-status-unstage: untracked.txt has nothing staged" &&
              gitStarted nothingStaged == #[statusRead] &&
              echoOf nothingToStage == some "vc-status-stage: staged.txt has nothing to stage" &&
              gitStarted nothingToStage == #[statusRead] },
    { name :=
        "visiting on a file's line opens the file under the root; on the head line it says there is no file there"
      run :=
        pure <|
          match statusDriver with
          | none => false
          | some driver =>
            let shown := settledAfter (settledAfter driver "C-o a") "C-v s"
            let visited := settledAfter shown "C-v 4 C-v v"
            let head := settledAfter shown "C-v 0 C-v v"
            ((showingFocused visited).bind (·.buffer.file)).map (·.path) ==
                some ("/r/unstaged.txt" : System.FilePath) &&
              echoOf head == some "vc-status: no file on this line" },
    { name :=
        "visiting on a line whose file is gone from the working tree says it is deleted and opens no buffer; on a staged deletion still on disk it opens the file"
      run :=
        pure <|
          match
            statusDriverOf
              { committed := #[("gone.txt", "g\n"), ("kept.txt", "k\n")]
                index := #[("gone.txt", .file "g\n")]
                worktree := #[("kept.txt", "k\n")] } with
          | none => false
          | some driver =>
            let shown := settledAfter (settledAfter driver "C-o a") "C-v s"
            let gone := settledAfter shown "C-v 1 C-v v"
            let kept := settledAfter shown "C-v 2 C-v v"
            let buffers (driver : TestDriver) := (driver.loop.state.buffers.filterMap id).size
            namedText shown statusBufferName ==
                some
                  "r@main: on main\nunstaged: gone.txt (deleted)\nstaged: kept.txt (deleted)\nuntracked: kept.txt\n" &&
              echoOf gone == some "vc-status-visit: gone.txt is deleted" &&
              buffers gone == buffers shown &&
              (showingFocused gone).map (·.buffer.name) == some statusBufferName &&
              ((showingFocused kept).bind (·.buffer.file)).map (·.path) ==
                some ("/r/kept.txt" : System.FilePath) },
    { name :=
        "refreshing reads the status again into the buffer without opening another window; outside a status buffer it says the buffer is not one"
      run :=
        pure <|
          match statusDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let shown := settledAfter opened "C-v s"
            let refreshed := settledAfter shown "C-v r"
            let elsewhere := settledAfter opened "C-v r"
            gitStarted refreshed == #[statusRead, statusRead] &&
              refreshed.loop.state.windows.size == shown.loop.state.windows.size &&
              namedText refreshed statusBufferName == some criterionText &&
              echoOf elsewhere == some "vc-status-refresh: a.lean is not a status buffer" },
    { name := "a status read git refuses says so in the echo area and makes no buffer"
      run :=
        pure <|
          match statusDriver with
          | none => false
          | some driver =>
            let refusing :=
              withScript driver
                { command := statusRead
                  reply :=
                    .ok {
                        exit := .code 128, stdout := .empty
                        stderr := "fatal: not a git repository\n".toUTF8 } }
            let asked := settledAfter (settledAfter refusing "C-o a") "C-v s"
            echoOf asked == some "vc-status: exited with status 128: fatal: not a git repository" &&
              asked.loop.state.findBuffer statusBufferName == none },
    { name :=
        "a stage git refuses says so in the echo area, starts no second status read, and leaves the buffer's text as it was"
      run :=
        pure <|
          match statusDriver with
          | none => false
          | some driver =>
            let add := gitRun #["add", "--all", "--", "unstaged.txt"]
            let shown := settledAfter (settledAfter driver "C-o a") "C-v s"
            let refusing :=
              withScript shown
                { command := add
                  reply :=
                    .ok {
                        exit := .code 128, stdout := .empty
                        stderr :=
                          "fatal: Unable to create '/r/.git/index.lock': File exists.\n".toUTF8 } }
            let toggled := settledAfter refusing "C-v 4 C-v t"
            echoOf toggled ==
                some
                  "vc-status: exited with status 128: fatal: Unable to create '/r/.git/index.lock': File exists." &&
              gitStarted toggled == #[statusRead, add] &&
              toggled.pending.isEmpty &&
              namedText toggled statusBufferName == some criterionText },
    { name :=
        "a refresh git refuses once the buffer is shown says so in the echo area, and the buffer keeps its text"
      run :=
        pure <|
          match statusDriver with
          | none => false
          | some driver =>
            let shown := settledAfter (settledAfter driver "C-o a") "C-v s"
            let refusing :=
              withScript shown
                { command := statusRead
                  reply :=
                    .ok {
                        exit := .code 128, stdout := .empty
                        stderr := "fatal: not a git repository\n".toUTF8 } }
            let refreshed := settledAfter refusing "C-v r"
            echoOf refreshed ==
                some "vc-status: exited with status 128: fatal: not a git repository" &&
              gitStarted refreshed == #[statusRead, statusRead] &&
              namedText refreshed statusBufferName == some criterionText &&
              refreshed.loop.state.findBuffer statusBufferName ==
                shown.loop.state.findBuffer statusBufferName },
    { name :=
        "the mode vc-status fills refresh, activate and toggle with the status buffer's commands, and has s, u, c and w as its leader suffixes, with nothing wrong"
      run :=
        pure <|
          VersionControl.mode.name == "vc-status" &&
            VersionControl.mode.roles ==
              [(Role.refresh, VersionControl.refreshName),
                (Role.activate, VersionControl.visitName),
                (Role.toggle, VersionControl.toggleName)] &&
            VersionControl.mode.locals ==
              [("s", VersionControl.stageName), ("u", VersionControl.unstageName),
                ("c", VersionControl.commitName), ("w", VersionControl.worktreesName)] &&
            VersionControl.mode.problems == [] }]

end ModelTest
