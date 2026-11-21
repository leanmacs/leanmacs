import Editor.Diff.Script
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
import VcApi
import VcApiTest.Contract
import VcApiTest.Fake
import VersionControl.Git
import VersionControl.Hunk
import VersionControlTest.Check
import VersionControlTest.Git.Model
import VersionControlTest.Support.Git

/-!
# Model tests: `VersionControl/Hunk.lean`

The model tests of `VersionControl/Hunk.lean`: `hunkChecks`. They include
the patch the git implementation feeds `git apply` (`Git.patch`,
`VersionControl/Git.lean`). The test driver's root,
`VersionControlTest/Model.lean`, runs them; its module doc says what each
shows.
-/

namespace VersionControlTest

open Editor

/-- The git implementation's staging of `hunk` of `path` in `/r` on `model`,
or its unstaging when `reverse`. -/
def gitHunk (reverse : Bool) (path : String) (hunk : VersionControl.LineHunk) (model : JobModel) :
    Job.Outcome (Except VersionControl.Error Unit) × JobModel :=
  let handler := VersionControl.Git.handler "git" "/r"
  if reverse then
    (handler (.unstageHunk path hunk) : JobM (Except VersionControl.Error Unit)).runModel model
  else (handler (.stageHunk path hunk) : JobM (Except VersionControl.Error Unit)).runModel model

/-- The git implementation's commit of `message` in `/r` on `model`. -/
def gitCommit (message : String) (model : JobModel) :
    Job.Outcome (Except VersionControl.Error Unit) × JobModel :=
  (VersionControl.Git.handler "git" "/r" (.commit message) :
        JobM (Except VersionControl.Error Unit)).runModel
    model

/-- The job model whose only script is `command`, answering `reply` after
`takes` milliseconds. -/
def answering (command : Process.Command) (reply : Except ProcessError Process.Ran)
    (takes : Nat := 0) : JobModel :=
  { processes := { scripts := #[{ command, reply, takes }] } }

/-- The checks of the pure core of staging a hunk
(`VersionControl/Hunk.lean`) and of the patch the git implementation
feeds `git apply` (`Git.patch`, `VersionControl/Git.lean`). -/
def hunkChecks : List Check :=
  let patch := VersionControl.Git.patch
  let make := VersionControl.LineHunk.make
  let header (a b : String) (range : String) : String :=
    s!"diff --git {a} {b}\n--- {a}\n+++ {b}\n@@ {range} @@\n"
  let plain := header "\"a/a.txt\"" "\"b/a.txt\""
  [{  name :=
        "a hunk of a file against the index takes 3 lines of context from the index's side, clamped at its ends, with each side's row of its first context line"
      run :=
        pure <|
          VersionControlContract.lineHunks .stage VersionControlContract.tenLines
              VersionControlContract.twoChanged ==
            #[make 0 0 "1\n" "2\n" "two\n" "3\n4\n5\n",
              make 5 5 "6\n7\n8\n" "9\n" "nine\n" "10\n"] },
    { name :=
        "the rows of a hunk are of each side: lines added before it move its new row, and not its old"
      run :=
        pure <|
          VersionControlContract.lineHunks .stage "a\nb\nc\nd\ne\nf\ng\nh\n"
              "x\ny\na\nb\nc\nd\nE\nf\ng\nh\n" ==
            #[make 0 0 "" "" "x\ny\n" "a\nb\nc\n", make 1 3 "b\nc\nd\n" "e\n" "E\n" "f\ng\nh\n"] },
    { name :=
        "a hunk of the index against HEAD takes its context from the new side, the index, and staging one from the old"
      run :=
        pure <|
          VersionControlContract.lineHunks .unstage "a\nb\nc\nd\ne\n" "a\nB\nc\nD\ne\n" ==
              #[make 0 0 "a\n" "b\n" "B\n" "c\nD\ne\n", make 0 0 "a\nB\nc\n" "d\n" "D\n" "e\n"] &&
            VersionControlContract.lineHunks .stage "a\nb\nc\nd\ne\n" "a\nB\nc\nD\ne\n" ==
              #[make 0 0 "a\n" "b\n" "B\n" "c\nd\ne\n", make 0 0 "a\nb\nc\n" "d\n" "D\n" "e\n"] },
    { name :=
        "make splits each text at its line feeds, keeping them, a last line without one kept, the empty text none"
      run :=
        pure <|
          make 2 3 "a\nb\n" "" "c\r\nd" "e" ==
            { oldLine := 2, newLine := 3, before := #["a\n", "b\n"], removed := #[]
              added := #["c\r\n", "d"], after := #["e"] } },
    { name :=
        "the hunk on a line: one whose new lines overlap it, else a removal at its start, else a removal at the end on the last line; none elsewhere"
      run :=
        pure <|
          let hunks : Diff.Hunks :=
            #[{ oldStart := 2, oldStop := 4, newStart := 2, newStop := 4 },
              { oldStart := 6, oldStop := 8, newStart := 6, newStop := 6 },
              { oldStart := 10, oldStop := 12, newStart := 8, newStop := 8 }]
          let ended : Diff.Hunks := #[{ oldStart := 6, oldStop := 8, newStart := 7, newStop := 7 }]
          let pick := VersionControl.Hunks.pick
          pick hunks 2 4 8 == hunks[0]? && pick hunks 6 8 8 == hunks[1]? &&
            pick hunks 8 8 8 == hunks[2]? &&
            pick hunks 0 2 8 == none &&
            pick hunks 4 6 8 == none &&
            pick ended 6 7 7 == ended[0]? &&
            pick ended 4 6 7 == none },
    { name :=
        "a line carried to the old text: shifted by the hunks before it outside them, and a hunk's old lines inside one"
      run :=
        pure <|
          let hunks : Diff.Hunks :=
            #[{ oldStart := 2, oldStop := 4, newStart := 2, newStop := 6 },
              { oldStart := 6, oldStop := 6, newStart := 8, newStop := 10 }]
          let toOld := VersionControl.Hunks.toOld hunks
          toOld 0 2 == (0, 2) && toOld 2 4 == (2, 4) && toOld 4 6 == (2, 4) &&
            toOld 6 8 == (4, 6) &&
            toOld 8 10 == (6, 6) &&
            toOld 10 12 == (6, 8) },
    { name :=
        "the patch of a hunk: a header naming the quoted path, its range, then context, removed and added lines"
      run :=
        pure <|
          patch "a.txt" (make 5 5 "6\n7\n8\n" "9\n" "nine\n" "10\n") false ==
            plain "-6,5 +6,5" ++ " 6\n 7\n 8\n-9\n+nine\n 10\n" },
    { name :=
        "the patch of a last line without a line feed marks it, removed or added, and of one adding the line feed marks the old"
      run :=
        pure <|
          patch "a.txt" (make 0 0 "a\nb\n" "c" "C" "") false ==
              plain "-1,3 +1,3" ++
                " a\n b\n-c\n\\ No newline at end of file\n+C\n\\ No newline at end of file\n" &&
            patch "a.txt" (make 0 0 "a\nb\n" "c" "c\n" "") false ==
              plain "-1,3 +1,3" ++ " a\n b\n-c\n\\ No newline at end of file\n+c\n" &&
            patch "a.txt" (make 0 0 "a\n" "b\n" "B\n" "c") false ==
              plain "-1,3 +1,3" ++ " a\n-b\n+B\n c\n\\ No newline at end of file\n" },
    { name := "the patch of CRLF lines keeps each carriage return"
      run :=
        pure <|
          patch "a.txt" (make 0 0 "a\r\n" "b\r\n" "B\r\n" "c\r\n") false ==
            plain "-1,3 +1,3" ++ " a\r\n-b\r\n+B\r\n c\r\n" },
    { name := "the patch into an empty index file starts its old side at 0, as git prints -0,0"
      run :=
        pure
          (patch "a.txt" (make 0 0 "" "" "a\nb\n" "") false == plain "-0,0 +1,2" ++ "+a\n+b\n") },
    { name :=
        "the patch's paths are C-quoted: a space as itself, a quote and a backslash escaped, a tab and each byte past ASCII in octal"
      run :=
        pure <|
          let first (path : String) :=
            ((patch path (make 0 0 "" "" "a\n" "") false).splitOn "\n").head!
          first "with space.txt" == "diff --git \"a/with space.txt\" \"b/with space.txt\"" &&
            first "héllo.txt" == "diff --git \"a/h\\303\\251llo.txt\" \"b/h\\303\\251llo.txt\"" &&
            first "q\"b\\c\td" == "diff --git \"a/q\\\"b\\\\c\\011d\" \"b/q\\\"b\\\\c\\011d\"" },
    { name :=
        "the patch to unstage starts its new side at the index's row, and the patch to stage at the old row"
      run :=
        pure <|
          patch "a.txt" (make 5 7 "x\n" "" "y\n" "z\n") true ==
              plain "-6,2 +8,3" ++ " x\n+y\n z\n" &&
            patch "a.txt" (make 5 7 "x\n" "" "y\n" "z\n") false ==
              plain "-6,2 +6,3" ++ " x\n+y\n z\n" },
    { name :=
        "staging a hunk runs git -c apply.whitespace=nowarn -c apply.ignoreWhitespace=false apply --cached - in the root, fed exactly the hunk's patch"
      run :=
        pure <|
          let hunk := make 0 0 "a\n" "b\n" "B\n" ""
          let (reply, after) :=
            gitHunk false "a.txt" hunk
              (answering (gitApplyRun false) (VersionControl.Model.Repository.ran .empty))
          reply == .finished (.ok ()) &&
            after.processes.fed == #[(gitApplyRun false, (patch "a.txt" hunk false).toUTF8)] },
    { name := "unstaging a hunk runs the same apply with --reverse, fed its reversed patch"
      run :=
        pure <|
          let hunk := make 0 2 "a\n" "b\n" "B\n" ""
          let (reply, after) :=
            gitHunk true "a.txt" hunk
              (answering (gitApplyRun true) (VersionControl.Model.Repository.ran .empty))
          reply == .finished (.ok ()) &&
            after.processes.fed == #[(gitApplyRun true, (patch "a.txt" hunk true).toUTF8)] },
    { name :=
        "a hunk git refuses failed, with what git said on its standard error, and an apply past the git time limit timed out"
      run :=
        pure <|
          let refusing :=
            answering (gitApplyRun false)
              (.ok
                { exit := .code 1, stdout := .empty
                  stderr := "error: patch failed: a.txt:1\n".toUTF8 })
          (gitHunk false "a.txt" (make 0 0 "" "x\n" "" "") refusing).1 ==
              .finished (.error (.failed (.code 1) "error: patch failed: a.txt:1")) &&
            (gitHunk false "a.txt" (make 0 0 "" "x\n" "" "")
                  (answering (gitApplyRun false) (VersionControl.Model.Repository.ran .empty)
                    (VersionControl.Git.gitTime + 1))).1 ==
              .finished (.error (.couldNotRun (.timedOut VersionControl.Git.gitTime))) },
    { name :=
        "a commit runs git commit --file=- --cleanup=whitespace in the root, without GIT_LITERAL_PATHSPECS, fed exactly the message, and may take past the git time limit"
      run :=
        pure <|
          let (reply, after) :=
            gitCommit "a message\n\n# kept\n"
              (answering gitCommitRun (VersionControl.Model.Repository.ran .empty)
                (VersionControl.Git.gitTime + 1))
          reply == .finished (.ok ()) &&
            after.processes.fed == #[(gitCommitRun, "a message\n\n# kept\n".toUTF8)] &&
            VersionControl.Git.commitTime > VersionControl.Git.gitTime },
    { name :=
        "a refused commit failed with git's standard error and then its standard output, each trimmed"
      run :=
        pure <|
          let refusing :=
            answering gitCommitRun
              (.ok
                { exit := .code 1, stdout := "On branch main\nnothing to commit\n".toUTF8
                  stderr := "the hook said no\n".toUTF8 })
          (gitCommit "m" refusing).1 ==
              .finished
                (.error
                  (.failed (.code 1) "the hook said no\nOn branch main\nnothing to commit")) &&
            (gitCommit "m"
                  (answering gitCommitRun
                    (.ok
                      { exit := .code 1, stdout := "nothing to commit\n".toUTF8,
                        stderr := .empty }))).1 ==
              .finished (.error (.failed (.code 1) "nothing to commit")) },
    { name :=
        "the job model of a repository with a hook answers its commit with status 1 and the hook's output on its standard error, and one without with 0"
      run :=
        pure <|
          let hooked : VersionControl.Model.Repository :=
            { VersionControlContract.clean #[("a.txt", "a\n")] with hook := some "no\nnever\n" }
          (gitCommit "m" (hooked.jobModel "git" "/r" #[.commit "m"])).1 ==
              .finished (.error (.failed (.code 1) "no\nnever")) &&
            (gitCommit "m"
                  ((VersionControlContract.clean #[]).jobModel "git" "/r" #[.commit "m"])).1 ==
              .finished (.ok ()) }]

end VersionControlTest
