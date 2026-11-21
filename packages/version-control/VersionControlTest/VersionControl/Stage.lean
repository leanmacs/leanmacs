import Editor.Command.Model
import Editor.Event
import Editor.File
import Editor.InputScheme.Test
import Editor.Job.Model
import Editor.Loop.Driver
import Editor.Process
import Editor.Process.Model
import Editor.State
import Editor.Test.Driver
import Editor.Test.Files
import Editor.Test.Keys
import Editor.Test.Opener
import Editor.Test.Shell
import Editor.Test.Workspace
import Editor.Text.Model
import VcApi
import VcApiTest.Contract
import VcApiTest.Fake
import VersionControl.Git
import VersionControl.Stage
import VersionControlTest.Check
import VersionControlTest.Support.Git
import VersionControlTest.Support.VersionControl

/-!
# Model tests: `VersionControl/Stage.lean`

The model tests of `VersionControl/Stage.lean`: `stageHunkChecks`. The test
driver's root, `VersionControlTest/Model.lean`, runs them; its module doc
says what each shows.
-/

namespace VersionControlTest

open Editor
open Editor.Test

/-- The repository of the hunk checks: `src/a.lean` is
`VersionControlContract.tenLines` in `HEAD` and the index, and
`VersionControlContract.twoChanged`, two hunks, in the working tree. -/
def stagingRepository : VersionControl.Model.Repository :=
  VersionControlContract.writing
    (VersionControlContract.clean #[("src/a.lean", VersionControlContract.tenLines)]) "src/a.lean"
    VersionControlContract.twoChanged

/-- How many snapshots `driver`'s text model holds that are not released. -/
def liveSnapshots (driver : TestDriver) : Nat :=
  (driver.model.texts.snapshots.filter (·.isSome)).size

/-- The checks of staging and unstaging a hunk
(`VersionControl/Stage.lean`), on the loop's driver over the editor's
models, the job model, the model of files and the model of a repository in
`/r`, whose diffs are the model's. -/
def stageHunkChecks : List Check :=
  let patch := VersionControl.Git.patch
  let make := VersionControl.LineHunk.make
  let second := make 5 5 "6\n7\n8\n" "9\n" "nine\n" "10\n"
  let fetchRun := gitRun #["rev-parse", "--verify", "--quiet", ":src/a.lean"]
  [{  name :=
        "criterion 1 on the models: vc-stage-hunk on a line of the second of two changed hunks feeds git apply --cached exactly that hunk's patch, says it staged a hunk, and leaves no snapshot held"
      run :=
        pure <|
          match stagingDriverOf stagingRepository with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let staged := settledAfter opened "C-r 8 C-v g"
            staged.jobs.processes.fed ==
                #[(gitApplyRun false, (patch "src/a.lean" second false).toUTF8)] &&
              echoOf staged == some "staged a hunk of src/a.lean" &&
              staged.pending.isEmpty &&
              liveSnapshots staged == liveSnapshots opened },
    { name :=
        "a buffer with unsaved changes is saved first: the fetch starts once the file is written, and the hunk staged is of the file as written"
      run :=
        pure <|
          match stagingDriverOf stagingRepository with
          | none => false
          | some driver =>
            let edited := settledAfter (settledAfter driver "C-o a") "C-v z"
            let written := "0\n" ++ VersionControlContract.twoChanged
            let (asked, _) := fedTo edited (presses "C-r 9 C-v g")
            let saved := finishNamed asked Opener.saveJob
            let staged := settledOn saved []
            let hunk :=
              (VersionControlContract.lineHunks .stage VersionControlContract.tenLines written)[2]?
            asked.pending.map (·.name) == #[Opener.saveJob] &&
              saved.pending.map (·.name) == #[VersionControl.hunkFetchJob] &&
              bytesOf staged "/r/src/a.lean" == some written.toUTF8 &&
              hunk.map
                  (fun hunk => #[(gitApplyRun false, (patch "src/a.lean" hunk false).toUTF8)]) ==
                some staged.jobs.processes.fed &&
              echoOf staged == some "staged a hunk of src/a.lean" &&
              liveSnapshots staged == liveSnapshots edited },
    { name :=
        "with no files implementation registered, vc-stage-hunk on a buffer with unsaved changes says vc-stage-hunk: no files implementation, starts no job and feeds git nothing"
      run :=
        pure <|
          match stagingDriverOf stagingRepository with
          | none => false
          | some driver =>
            let edited := settledAfter (settledAfter driver "C-o a") "C-v z"
            let bare := { edited with keys := withoutExtension FilesApi.Files edited.keys }
            let asked := settledAfter bare "C-r 9 C-v g"
            echoOf asked == some "vc-stage-hunk: no files implementation" &&
              asked.next == bare.next &&
              asked.jobs.processes.fed.isEmpty },
    { name := "a save that is refused starts no fetch, and stages nothing"
      run :=
        pure <|
          match stagingDriverOf stagingRepository with
          | none => false
          | some driver =>
            let edited := settledAfter (settledAfter driver "C-o a") "C-v z"
            let changed := rewritten edited "/r/src/a.lean" "other\n".toUTF8
            let refused := settledAfter changed "C-r 9 C-v g"
            echoOf refused ==
                some
                  (Opener.notSaved "/r/src/a.lean" (.changed (stampOf changed "/r/src/a.lean"))) &&
              !(gitStarted refused).contains fetchRun &&
              refused.jobs.processes.fed.isEmpty },
    { name :=
        "a buffer edited while its index is fetched says it changed, stages nothing and holds no snapshot"
      run :=
        pure <|
          match stagingDriverOf stagingRepository with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let (asked, _) := fedTo opened (presses "C-r 1 C-v g")
            let (edited, _) := fedTo asked (presses "C-v z")
            let fetched := settledOn (finishNamed edited VersionControl.hunkFetchJob) []
            asked.pending.map (·.name) == #[VersionControl.hunkFetchJob] &&
              echoOf fetched ==
                some "vc-stage-hunk: src/a.lean changed while staging; nothing staged" &&
              fetched.jobs.processes.fed.isEmpty &&
              liveSnapshots fetched == liveSnapshots opened },
    { name := "a line with no change says so, stages nothing and holds no snapshot"
      run :=
        pure <|
          match stagingDriverOf stagingRepository with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let asked := settledAfter opened "C-r 4 C-v g"
            echoOf asked == some "vc-stage-hunk: no change on this line" &&
              asked.jobs.processes.fed.isEmpty &&
              liveSnapshots asked == liveSnapshots opened },
    { name :=
        "a buffer with no unsaved changes whose file changed on disk says to reload it, starts no fetch, and feeds git nothing; one whose file is gone says so; vc-unstage-hunk, which takes nothing from the buffer's text, goes on"
      run :=
        pure <|
          match stagingDriverOf stagingRepository with
          | none => false
          | some driver =>
            let changed := settledAfter (settledAfter driver "C-o a") "C-v d"
            let asked := settledAfter changed "C-r 8 C-v g"
            let gone :=
              settledAfter (settledAfter (settledAfter driver "C-o a") "C-v D") "C-r 8 C-v g"
            echoOf asked ==
                some "vc-stage-hunk: src/a.lean changed on disk; reload it (:e) and try again" &&
              !(gitStarted asked).contains fetchRun &&
              asked.jobs.processes.fed.isEmpty &&
              liveSnapshots asked == liveSnapshots changed &&
              echoOf gone == some "vc-stage-hunk: src/a.lean is gone from disk; nothing staged" &&
              gone.jobs.processes.fed.isEmpty &&
              echoOf (settledAfter changed "C-r 8 C-v G") ==
                some "vc-unstage-hunk: nothing staged on this line" },
    { name :=
        "a file found changed on disk while its index is fetched says to reload it, feeds git nothing and holds no snapshot"
      run :=
        pure <|
          match stagingDriverOf stagingRepository with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let (asked, _) := fedTo opened (presses "C-r 8 C-v g")
            let (changed, _) := fedTo asked (presses "C-v d")
            let fetched := settledOn (finishNamed changed VersionControl.hunkFetchJob) []
            asked.pending.map (·.name) == #[VersionControl.hunkFetchJob] &&
              echoOf fetched ==
                some "vc-stage-hunk: src/a.lean changed on disk; reload it (:e) and try again" &&
              fetched.jobs.processes.fed.isEmpty &&
              liveSnapshots fetched == liveSnapshots opened },
    { name :=
        "a file the index does not hold says to stage the whole file; a file in no repository and a buffer with no file say so, and start no job"
      run :=
        pure <|
          match stagingDriverOf stagingRepository with
          | none => false
          | some driver =>
            let untracked := settledAfter (settledAfter driver "C-o b") "C-v g"
            let (outside, _) := fedTo (settledAfter driver "C-o x") (presses "C-v g")
            let (bare, _) := fedTo driver (presses "C-v g")
            echoOf untracked ==
                some
                  "vc-stage-hunk: src/b.lean has no version in the index to stage (untracked or in conflict); stage the whole file" &&
              untracked.jobs.processes.fed.isEmpty &&
              echoOf outside == some "vc-stage-hunk: a.txt is not in a repository" &&
              outside.pending.isEmpty &&
              echoOf bare == some s!"vc-stage-hunk: {EditorState.scratchName} has no file" &&
              bare.pending.isEmpty },
    { name :=
        "vc-unstage-hunk carries the cursor's line through the hunks of the index against the buffer and feeds git apply --cached --reverse the staged hunk's patch; on a line with nothing staged it says so; it saves nothing"
      run :=
        pure <|
          match
            stagingDriverOf
              { committed := #[("src/a.lean", VersionControlContract.tenLines)]
                index := #[("src/a.lean", .file VersionControlContract.twoChanged)]
                worktree := #[("src/a.lean", "0\n" ++ VersionControlContract.twoChanged)] } with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let unstaged := settledAfter opened "C-r 9 C-v G"
            let nothing := settledAfter opened "C-r 0 C-v G"
            let edited := settledAfter (settledAfter opened "C-v z") "C-r t C-v G"
            let hunk :=
              (VersionControlContract.lineHunks .unstage VersionControlContract.tenLines
                  VersionControlContract.twoChanged)[1]?
            let fed :=
              hunk.map fun hunk => #[(gitApplyRun true, (patch "src/a.lean" hunk true).toUTF8)]
            fed == some unstaged.jobs.processes.fed &&
              echoOf unstaged == some "unstaged a hunk of src/a.lean" &&
              echoOf nothing == some "vc-unstage-hunk: nothing staged on this line" &&
              nothing.jobs.processes.fed.isEmpty &&
              fed == some edited.jobs.processes.fed &&
              !(edited.pending.any (·.name == Opener.saveJob)) &&
              liveSnapshots unstaged == liveSnapshots opened },
    { name :=
        "an apply git refuses says git's refusal, does not read the status again, and holds no snapshot"
      run :=
        pure <|
          match stagingDriverOf stagingRepository with
          | none => false
          | some driver =>
            let shown := settledAfter (settledAfter driver "C-o a") "C-v s"
            let refusing :=
              withScript shown
                { command := gitApplyRun false
                  reply :=
                    .ok {
                        exit := .code 1, stdout := .empty
                        stderr :=
                          "error: patch failed: src/a.lean:6\nerror: src/a.lean: patch does not apply\n".toUTF8 } }
            let reopened := settledAfter refusing "C-o a"
            let refused := settledAfter reopened "C-r 8 C-v g"
            let statusRead := gitRun VersionControl.Git.statusArguments
            echoOf refused ==
                some "vc-stage-hunk: exited with status 1: error: patch failed: src/a.lean:6" &&
              refused.jobs.processes.fed.map (·.1) == #[gitApplyRun false] &&
              ((gitStarted refused).filter (· == statusRead)).size == 1 &&
              refused.pending.isEmpty &&
              liveSnapshots refused == liveSnapshots reopened },
    { name :=
        "vc-stage-hunk pressed again while the buffer's save runs says it is being saved, and one save, one fetch and one apply run"
      run :=
        pure <|
          match stagingDriverOf stagingRepository with
          | none => false
          | some driver =>
            let edited := settledAfter (settledAfter driver "C-o a") "C-v z"
            let (asked, _) := fedTo edited (presses "C-r 9 C-v g")
            let (again, _) := fedTo asked (presses "C-v g")
            let staged := settledOn again []
            asked.pending.map (·.name) == #[Opener.saveJob] &&
              echoOf again == some "vc-stage-hunk: src/a.lean is being saved; try again" &&
              again.pending.map (·.name) == #[Opener.saveJob] &&
              ((gitStarted staged).filter (· == fetchRun)).size == 1 &&
              staged.jobs.processes.fed.size == 1 &&
              echoOf staged == some "staged a hunk of src/a.lean" },
    { name :=
        "vc-unstage-hunk on a file the index holds and HEAD does not says to unstage the whole file, and feeds git nothing"
      run :=
        pure <|
          match
            stagingDriverOf
              { committed := #[("src/c.lean", "c\n")]
                index :=
                  #[("src/c.lean", .file "c\n"),
                    ("src/a.lean", .file VersionControlContract.tenLines)]
                worktree :=
                  #[("src/c.lean", "c\n"), ("src/a.lean", VersionControlContract.tenLines)] }
              #[("HEAD", "src/a.lean")] with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let asked := settledAfter opened "C-r 1 C-v G"
            echoOf asked ==
                some "vc-unstage-hunk: src/a.lean is not in HEAD; unstage the whole file" &&
              asked.jobs.processes.fed.isEmpty &&
              liveSnapshots asked == liveSnapshots opened },
    { name := "a hunk staged with the workspace's status buffer kept reads the status again into it"
      run :=
        pure <|
          match stagingDriverOf stagingRepository with
          | none => false
          | some driver =>
            let shown := settledAfter (settledAfter driver "C-o a") "C-v s"
            let staged := settledAfter (settledAfter shown "C-o a") "C-r 8 C-v g"
            let statusRead := gitRun VersionControl.Git.statusArguments
            (gitStarted staged).back? == some statusRead &&
              ((gitStarted staged).filter (· == statusRead)).size == 2 }]

end VersionControlTest
