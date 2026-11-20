import Editor.Grep
import Editor.ProjectSearch
import ModelTest.Check

/-!
# Model tests: `Editor/ProjectSearch.lean`

The model tests of `Editor/ProjectSearch.lean`: `projectSearchChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- A record with files of the sequence numbers and states given, in walk
order. -/
def recordOf (files : List (Nat × ProjectSearch.FileState)) : ProjectSearch.Record :=
  { root := "/w", label := "w", pattern := "x"
    files :=
      files.toArray.map fun (sequence, state) => { sequence, path := s!"/w/{sequence}", state } }

/-- The checks of project search's pure core: the rows an excerpt shows,
merged and clipped; where a file's excerpts go when they arrive out of order;
the record's round trip; and each sentence. -/
def projectSearchChecks : List Check :=
  [{  name :=
        "a match's excerpt is its row and two rows each side; matches whose rows are exactly twice the context apart merge, and one row further do not"
      run :=
        return ProjectSearch.excerptRows #[10] 2 100 == #[(8, 12)] &&
            ProjectSearch.excerptRows #[10, 14] 2 100 == #[(8, 16)] &&
            ProjectSearch.excerptRows #[10, 15] 2 100 == #[(8, 12), (13, 17)] &&
            ProjectSearch.excerptRows #[10, 10, 11] 2 100 == #[(8, 13)] },
    { name := "an excerpt is clipped at the text's first and last rows"
      run :=
        return ProjectSearch.excerptRows #[0, 1] 2 100 == #[(0, 3)] &&
            ProjectSearch.excerptRows #[99] 2 100 == #[(97, 99)] &&
            ProjectSearch.excerptRows #[0] 2 1 == #[(0, 0)] && ProjectSearch.excerptRows #[] 2 9 == #[] },
    { name :=
        "a file's excerpts go after those of every placed file earlier in the walk, whatever order the files were placed in"
      run := do
        let record :=
          recordOf [(0, .placed 1 2), (1, .pending), (2, .placed 3 1), (3, .dropped), (4, .placed 5 3)]
        return record.slot 0 == 0 && record.slot 1 == 2 && record.slot 2 == 2 && record.slot 3 == 3 &&
            record.slot 4 == 3 && record.slot 5 == 6 },
    { name := "a record is kept as a value and read back as it was"
      run := do
        let record :=
          { recordOf [(0, .placed 1 2), (1, .pending), (2, .dropped)] with
            ended := some "project-search: 3 matches in 1 file", snapshots := #[4, 9] }
        return ProjectSearch.Record.decode? record.encode == some record &&
            ProjectSearch.Record.decode? (.str "x") == none },
    { name := "the results buffer's name, a file's header and each sentence"
      run :=
        return ProjectSearch.bufferName "foo" "editor" == "*search: foo in editor*" &&
            ProjectSearch.header "src/a.rs" 1 == "src/a.rs · 1 match" &&
            ProjectSearch.header "src/a.rs" 3 == "src/a.rs · 3 matches" &&
            ProjectSearch.relative "/w" "/w/src/a.rs" == "src/a.rs" &&
            ProjectSearch.relative "/w" "/v/a.rs" == "/v/a.rs" &&
            ProjectSearch.summary 1 1 == "project-search: 1 match in 1 file" &&
            ProjectSearch.summary 7 3 == "project-search: 7 matches in 3 files" &&
            ProjectSearch.truncated 2000 41 ==
              "project-search: stopped after 2000 matches in 41 files; narrow the pattern" &&
            ProjectSearch.noMatch "foo" "editor" == "project-search: no match for foo in editor" &&
            ProjectSearch.refused (.invalid "E54: Unmatched \\(") ==
              "project-search: E54: Unmatched \\(" &&
            ProjectSearch.limits == { files := 200, found := 2000 } && ProjectSearch.contextRows == 2 }]

end ModelTest
