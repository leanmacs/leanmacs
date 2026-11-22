import Editor.State
import Editor.Test.Driver
import VcApi
import VersionControl.Blame
import VersionControl.Review
import VersionControlTest.Check
import VersionControlTest.Support.VersionControl
import VersionControlTest.VersionControl.Log
import VersionControlTest.VersionControl.Review

/-!
# Model tests: `VersionControl/Blame.lean`

The model tests of `VersionControl/Blame.lean`: `blameViewChecks` and
`blameBufferChecks`. The test driver's root,
`VersionControlTest/Model.lean`, runs them; its module doc says what each
shows.
-/

namespace VersionControlTest

open Editor
open Editor.Test
open Editor.VersionControl

/-- The checks of the blame's pure view (`VersionControl/Blame.lean`,
"The view"). -/
def blameViewChecks : List Check :=
  let blamed : Blame :=
    { commits :=
        #[("0123456789abcdef", { author := "a", time := 1767225600, subject := "base" }),
          ("F", { author := "A very long author name", time := 1767312000, subject := "F" })]
      lines :=
        #[{ id := "0123456789abcdef", text := "1" }, { id := "F", text := "x" },
          { id := "0123456789abcdef", text := "3" }] }
  [{  name :=
        "a blame's text is one row per line, row r line r: the commit's first 8 characters, its author cut at 16 and padded to the widest, its day, a bar and the line"
      run :=
        pure <|
          BlameView.render blamed ==
              "01234567 a                2026-01-01 | 1\n" ++
                "F A very long auth 2026-01-02 | x\n" ++
                "01234567 a                2026-01-01 | 3\n" &&
            BlameView.render {} == "" },
    { name :=
        "the commit on a row is its line's, none past the last; a record decodes to what it encodes"
      run :=
        pure <|
          let record : BlameRecord :=
            { root := "/r", revision := "HEAD", path := "a.txt", ids := #["B", "F"] }
          BlameView.idAt record.ids 0 == some "B" && BlameView.idAt record.ids 1 == some "F" &&
            BlameView.idAt record.ids 2 == none &&
            BlameRecord.decode? record.encode == some record &&
            BlameRecord.decode? (.str "x") == none }]

/-- The checks of the blame view (`VersionControl/Blame.lean`), on the
loop's driver over the editor's models and the version-control interface's
model (`Model.readHandler`). -/
def blameBufferChecks : List Check :=
  [{  name :=
        "criterion 3 on the models: vc-blame in a.txt opens *vc-blame: a.txt@HEAD*, read-only, in vc-blame, focused, one row per line naming the commit that last changed it and its author: the changed line's row F and b, the others B or head and a"
      run :=
        pure <|
          match logOpened with
          | none => false
          | some opened =>
            let blamed := reviewAfter (reviewAfter opened "C-l a") "C-l e"
            match focusedShowing blamed with
            | none => false
            | some shown =>
              shown.buffer.name == "*vc-blame: a.txt@HEAD*" && shown.buffer.readOnly &&
                shown.buffer.major == some blameModeName &&
                shown.text ==
                  some
                    ("B a 2026-01-01 | 1\n" ++ "F b 2026-01-02 | the second line, changed\n" ++
                      "B a 2026-01-01 | 3\n" ++
                      "head a 2026-01-01 | 4\n") },
    { name :=
        "vc-blame-visit on a row opens the review of that row's commit, its hunks against its first parent"
      run :=
        pure <|
          match logOpened with
          | none => false
          | some opened =>
            let visited :=
              reviewAfter (reviewAfter (reviewAfter opened "C-l a") "C-l e") "C-r 1 C-l o"
            -- Opening `/r/a.txt` finds the workspace at `/r` with the label
            -- the test world's finder gives it there, which is not this
            -- check's.
            ((focusedShowing visited).map (·.buffer.name)).any
                (fun name => name.startsWith "*vc-review: " && name.endsWith " F*") &&
              shownHeaders visited == #["a.txt @@ -1,3 +1,3 @@"] &&
              (keptReviews visited).rounds.isEmpty },
    { name :=
        "vc-blame of a file the revision lacks says so; of a dashed revision is refused before any job; with no workspace says so; and vc-blame-visit outside a blame buffer says it is not one"
      run :=
        pure <|
          match logOpened, reviewDriverOf logRepository with
          | some opened, some bare =>
            let dashed := reviewAfter (reviewAfter opened "C-l a") "C-l x"
            echoOf (reviewAfter (reviewAfter opened "C-l s") "C-l k") ==
                some "vc-blame: s.txt is not in B" &&
              echoOf dashed == some "vc-blame: -x starts with -" &&
              dashed.pending.isEmpty &&
              (echoOf (reviewAfter bare "C-l e")).any (·.endsWith "has no workspace") &&
              echoOf (reviewAfter opened "C-l o") ==
                some "vc-blame-visit: a.lean is not a blame buffer" &&
              echoOf
                  (reviewAfter (reviewAfter (reviewAfter opened "C-l a") "C-l e") "C-r 4 C-l o") ==
                some "vc-blame: no commit on this line"
          | _, _ => false }]

end VersionControlTest
