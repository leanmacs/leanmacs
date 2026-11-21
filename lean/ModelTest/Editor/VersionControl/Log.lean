import Editor.State
import Editor.Test.Driver
import Editor.VersionControl.Log
import Editor.VersionControl.Review
import ModelTest.Check
import ModelTest.Editor.VersionControl.Review
import ModelTest.Support.VersionControl
import VcApi
import VcApiTest.Contract

/-!
# Model tests: `Editor/VersionControl/Log.lean`

The model tests of `Editor/VersionControl/Log.lean`: `logViewChecks` and
`logBufferChecks`. The root module `ModelTest` runs them; its module doc
says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test
open Editor.VersionControl

/-- The repository of the log and blame buffer checks: the contract's
history repository (`VersionControlContract.historyRepository`), whose `F`
is written by `b`, with the branch `feature` at `F`. -/
def logRepository : Model.Repository :=
  { VersionControlContract.historyRepository with branches := #[("feature", "F")] }

/-- The row of the primary cursor of what `shown` shows. -/
def cursorRowOf (shown : Showing) : Option Nat := do
  let text ← shown.text
  let range ← (← shown.cursors)[0]?
  return ((text.toUTF8.extract 0 range.head).toList.filter (· == 10)).length

/-- The checks of the log's pure view (`Editor/VersionControl/Log.lean`,
"The view"). -/
def logViewChecks : List Check :=
  let entry (id : String) (author : String) (time : Nat) (subject : String) : LogEntry :=
    { id, authored := { author, time, subject } }
  let entries :=
    #[entry "0123456789abcdef" "Bé Two" 1767312000 "change two", entry "fedcba98" "a" 0 "base"]
  [{  name :=
        "a log's text is its head row, then one row per commit, newest first, its first 8 characters, its day, its subject and its author; no commit says so, and a reply past the limit ends with a row that says so"
      run :=
        pure <|
          LogView.render "r@main" "feature" entries ==
              "r@main: log of feature\n" ++ "01234567 2026-01-02 change two (Bé Two)\n" ++
                "fedcba98 1970-01-01 base (a)\n" &&
            LogView.render "r@main" "x" #[] == "r@main: log of x\nno commits\n" &&
            LogView.render "r@main" "feature" entries 1 ==
              "r@main: log of feature\n" ++ "01234567 2026-01-02 change two (Bé Two)\n" ++
                "more commits past 1\n" &&
            (LogView.shown entries 1).map (·.id) == #["0123456789abcdef"] },
    { name :=
        "the commit on a row is the shown one before it: none on the head row or past the last"
      run :=
        pure <|
          LogView.entryAt #["a", "b"] 0 == none && LogView.entryAt #["a", "b"] 1 == some "a" &&
            LogView.entryAt #["a", "b"] 2 == some "b" &&
            LogView.entryAt #["a", "b"] 3 == none },
    { name := "a log's record decodes to what it encodes"
      run :=
        pure <|
          let record : LogRecord := { root := "/r", revision := "main", ids := #["a", "b"] }
          LogRecord.decode? record.encode == some record && LogRecord.decode? (.str "x") == none }]

/-- `logRepository`'s driver with `/r/src/a.lean` open in view 0. -/
def logOpened (repository : Model.Repository := logRepository) : Option TestDriver :=
  reviewOpened repository

/-- The checks of the log buffer (`Editor/VersionControl/Log.lean`), on the
loop's driver over the editor's models and the version-control interface's
model (`Model.readHandler`). -/
def logBufferChecks : List Check :=
  [{  name :=
        "criterion 1 on the models: vc-log feature opens *vc-log: r@main feature*, read-only, in vc-log, focused, listing feature's commits newest first, each with its author: F by b, then B by a"
      run :=
        pure <|
          match logOpened with
          | none => false
          | some opened =>
            let logged := reviewAfter opened "C-l f"
            match focusedShowing logged with
            | none => false
            | some shown =>
              shown.buffer.name == "*vc-log: r@main feature*" && shown.buffer.readOnly &&
                shown.buffer.major == some logModeName &&
                shown.text ==
                  some "r@main: log of feature\nF 2026-01-02 F (b)\nB 2026-01-01 B (a)\n" },
    { name :=
        "vc-log with no text logs HEAD along first parents, the merge once; vc-log-refresh reads it again into the same buffer and keeps the cursor's row"
      run :=
        pure <|
          match logOpened with
          | none => false
          | some opened =>
            let logged := reviewAfter opened "C-l l"
            let moved := reviewAfter logged "C-r 3"
            let refreshed := reviewAfter moved "C-l r"
            let text :=
              "r@main: log of HEAD\nhead 2026-01-01 head (a)\nM 2026-01-01 M (a)\n" ++
                "F 2026-01-02 F (b)\nB 2026-01-01 B (a)\n"
            (focusedShowing logged).bind (·.text) == some text &&
              (focusedShowing refreshed).bind (·.text) == some text &&
              (focusedShowing refreshed).map (·.id) == (focusedShowing logged).map (·.id) &&
              (focusedShowing refreshed).bind cursorRowOf == some 3 },
    { name :=
        "criterion 2 on the models: vc-log-visit on a commit's row opens that commit's change as a review buffer, its hunks against its first parent alone, its new side read-only buffers of the commit, no round written and revert refused; a merge's row shows its change against its first parent, and the root commit's row its files added"
      run :=
        pure <|
          match logOpened with
          | none => false
          | some opened =>
            let logged := reviewAfter opened "C-l l"
            let visited := reviewAfter logged "C-r 3 C-l v"
            let reverted := reviewAfter visited "C-t 1 C-t v"
            let merge := reviewAfter logged "C-r 2 C-l v"
            let root := reviewAfter logged "C-r 4 C-l v"
            (focusedShowing visited).map (·.buffer.name) == some "*vc-review: r@main F*" &&
              shownHeaders visited == #["a.txt @@ -1,3 +1,3 @@"] &&
              entrySources visited == #[("a.txt@B", true), ("a.txt@F", true)] &&
              (keptReviews visited).rounds.isEmpty &&
              echoOf reverted ==
                some "vc-review-revert: this review is of commit F; nothing to revert" &&
              shownHeaders merge == #["s.txt @@ -0,0 +1 @@"] &&
              shownHeaders root == #["a.txt @@ -0,0 +1,3 @@"] &&
              entrySources root == #[("a.txt@B", true)] },
    { name :=
        "vc-log-visit on the head row says there is no commit there, and outside a log buffer says it is not one"
      run :=
        pure <|
          match logOpened with
          | none => false
          | some opened =>
            let logged := reviewAfter opened "C-l l"
            echoOf (reviewAfter logged "C-r 0 C-l v") == some "vc-log: no commit on this line" &&
              echoOf (reviewAfter opened "C-l v") ==
                some "vc-log-visit: a.lean is not a log buffer" &&
              echoOf (reviewAfter opened "C-l r") ==
                some "vc-log-refresh: a.lean is not a log buffer" },
    { name :=
        "vc-log of a dashed name is refused before any job, of an unborn HEAD says it is not a commit, and with no workspace says so"
      run :=
        pure <|
          match logOpened,
            logOpened { index := #[("a.txt", .file "a\n")], worktree := #[("a.txt", "a\n")] },
            reviewDriverOf logRepository with
          | some opened, some unborn, some bare =>
            let dashed := reviewAfter opened "C-l d"
            echoOf dashed == some "vc-log: -x starts with -" && dashed.pending.isEmpty &&
              echoOf (reviewAfter unborn "C-l l") ==
                some "vc-log: exited with status 1: HEAD is not a commit" &&
              (echoOf (reviewAfter bare "C-l l")).any (·.endsWith "has no workspace")
          | _, _, _ => false }]

end ModelTest
