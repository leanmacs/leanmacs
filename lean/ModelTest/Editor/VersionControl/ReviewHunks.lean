import Editor.Diff.Model
import Editor.State
import Editor.Text
import Editor.VersionControl
import Editor.VersionControl.Contract
import Editor.VersionControl.Hunk
import Editor.VersionControl.Model
import Editor.VersionControl.ReviewHunks
import ModelTest.Check

/-!
# Model tests: `Editor/VersionControl/ReviewHunks.lean`

The model tests of `Editor/VersionControl/ReviewHunks.lean`:
`reviewHunkChecks`, `reviewOrderChecks` and `reviewRecordChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.VersionControl

/-- The lines `1` to `20`, each ended by a line feed. -/
def twentyLines : String :=
  String.join ((List.range 20).map fun row => s!"{row + 1}\n")

/-- `text` with each row of `rows` set to its line (`lineSet`). -/
def rowsSet (text : String) (rows : List (Nat × String)) : String :=
  rows.foldl (fun text (row, line) => VersionControlContract.lineSet text row line) text

/-- The review spans of `old` against `new`, grouped from the model's line
diff over the texts as strings. -/
def reviewSpans (old new : String) : Array ReviewSpan :=
  Id.run (ReviewSpan.group (Lines.ofText old) (Lines.ofText new) (DiffModel.hunks old new 1000))

/-- What `span` of `old` against `new` reads: its old side with its context,
its new side with its context, each run's removed lines, each run's added
lines, and its numbers. -/
def spanRead (old new : String) (span : ReviewSpan) :
    String × String × Array String × Array String × String :=
  let (before, after) := (Lines.ofText old, Lines.ofText new)
  (Id.run (before.slice span.oldStart span.oldStop),
    Id.run (after.slice span.newStart span.newStop),
    span.removed.map (fun (start, stop) => Id.run (before.slice start stop)),
    span.added.map (fun (start, stop) => Id.run (after.slice start stop)), span.numbers)

/-- The spans of `old` against `new`, each as `spanRead` reads it. -/
def spansRead (old new : String) : Array (String × String × Array String × Array String × String) :=
  (reviewSpans old new).map (spanRead old new)

/-- The checks of how a change becomes review hunks
(`Editor/VersionControl/ReviewHunks.lean`, "The rules"), on strings through
`Lines.ofText` and the model's line diff. -/
def reviewHunkChecks : List Check :=
  [{  name :=
        "two changes 13 rows apart in twenty lines are two spans, each with 3 rows of context each side, clamped at the start"
      run :=
        pure <|
          spansRead twentyLines (rowsSet twentyLines [(1, "two\n"), (15, "sixteen\n")]) ==
            #[("1\n2\n3\n4\n5\n", "1\ntwo\n3\n4\n5\n", #["2\n"], #["two\n"], "@@ -1,5 +1,5 @@"),
              ("13\n14\n15\n16\n17\n18\n19\n", "13\n14\n15\nsixteen\n17\n18\n19\n", #["16\n"],
                #["sixteen\n"], "@@ -13,7 +13,7 @@")] },
    { name := "two changes 6 equal rows apart are one span, as git merges them, and 7 apart are two"
      run :=
        pure <|
          let six := rowsSet twentyLines [(1, "two\n"), (8, "nine\n")]
          let seven := rowsSet twentyLines [(1, "two\n"), (9, "ten\n")]
          (reviewSpans twentyLines six).map (·.numbers) == #["@@ -1,12 +1,12 @@"] &&
            (reviewSpans twentyLines six).map (·.removed.size) == #[2] &&
            (reviewSpans twentyLines seven).map (·.numbers) ==
              #["@@ -1,5 +1,5 @@", "@@ -7,7 +7,7 @@"] },
    { name :=
        "context is clamped at the text's start and end, and a last line with no line feed is a row"
      run :=
        pure <|
          (reviewSpans twentyLines (rowsSet twentyLines [(0, "one\n"), (19, "twenty\n")])).map
                (·.numbers) ==
              #["@@ -1,4 +1,4 @@", "@@ -17,4 +17,4 @@"] &&
            spansRead "a\nb\nc" "a\nb\nC" ==
              #[("a\nb\nc", "a\nb\nC", #["c"], #["C"], "@@ -1,3 +1,3 @@")] },
    { name :=
        "an added file is one span with no old excerpt, numbered -0,0; a deleted one is one span that removes the whole old text, numbered +0,0, its new side empty"
      run :=
        pure <|
          let added := reviewSpans "" "x\ny\n"
          let deleted := reviewSpans "x\ny\n" ""
          spansRead "" "x\ny\n" == #[("", "x\ny\n", #[], #["x\ny\n"], "@@ -0,0 +1,2 @@")] &&
            added.map (·.oldExcerpt?) == #[none] &&
            spansRead "x\ny\n" "" == #[("x\ny\n", "", #["x\ny\n"], #[], "@@ -1,2 +0,0 @@")] &&
            deleted.map (fun span => (span.newStart, span.newStop, span.oldExcerpt?)) ==
              #[(0, 0, some (0, 4))] },
    { name :=
        "the header is the path and git's numbers: a side of one line is its line alone, and an empty side is the line before it with 0"
      run :=
        pure <|
          (reviewSpans "a\n" "b\n").map (·.header "src/a.rs") == #["src/a.rs @@ -1 +1 @@"] &&
            (reviewSpans "a\nb\nc\nd\ne\n" "a\nb\nc\nd\ne\nf\n").map (·.numbers) ==
              #["@@ -3,3 +3,4 @@"] &&
            (reviewSpans twentyLines (rowsSet twentyLines [(1, "two\n")])).map (·.changed) ==
              #[2] },
    { name :=
        "the old excerpt is the first removed line's start to the last removed line's stop, the context between them included; equal texts give no span"
      run :=
        pure <|
          (reviewSpans twentyLines (rowsSet twentyLines [(1, "two\n"), (8, "nine\n")])).map
                (·.oldExcerpt?) ==
              #[some (2, 18)] &&
            (reviewSpans twentyLines twentyLines).isEmpty }]

/-- The files of the order checks' change: `lean/Pkg/A.lean`, which imports
`Pkg.B`, two changed lines; `lean/Pkg/B.lean`, four; `lean/Pkg/C.lean`,
one; and the added test `lean/PkgTest/ATest.lean`, two. The policy's order
(the test, then `B`, `A` and `C`) is neither the paths' order, their
reverse, nor the changed lines' order. -/
def orderRepository : Model.Repository :=
  VersionControlContract.forked
    #[("lean/Pkg/A.lean", "import Pkg.B\n\ndef a := 1\n"), ("lean/Pkg/B.lean", "def b := 1\n"),
      ("lean/Pkg/C.lean", "def c := 1\n")]
    #[("lean/Pkg/A.lean", "import Pkg.B\n\ndef a := 2\n"),
      ("lean/Pkg/B.lean", "def b := 2\ndef b2 := 2\ndef b3 := 3\n"),
      ("lean/Pkg/C.lean", "def c := 1\ndef c2 := 2\n"),
      ("lean/PkgTest/ATest.lean", "import Pkg.A\n#eval Pkg.a\n")]
    #[] #[("base", "B")]

/-- How many lines `change` changes, by the spans its texts group into. -/
def changedOf (change : FileChange) : Nat :=
  (reviewSpans (change.old.getD "") (change.new.getD "")).foldl (· + ·.changed) 0

/-- `files` ordered by the policy, each with the lines it changes. -/
def orderedPaths (files : Array FileChange) : Array String :=
  (orderFiles (files.map fun change => (change, changedOf change))).map (·.1.path)

/-- A change of `path` from nothing to `text`. -/
def addedChange (path text : String) : FileChange :=
  { path, old := none, new := some text }

/-- The checks of the review's order (`Editor/VersionControl/ReviewHunks.lean`,
"The order"), over the version-control interface's model. -/
def reviewOrderChecks : List Check :=
  [{  name :=
        "criterion 1 over the version-control model: the change of HEAD against base is ordered the test first, then B before A, which imports it, then C: not the paths' order, nor its reverse"
      run :=
        pure <|
          match Model.Repository.changesOf orderRepository "HEAD" "base" with
          | .error _ => false
          | .ok changes =>
            let paths := changes.files.map (·.path)
            orderedPaths changes.files ==
                #["lean/PkgTest/ATest.lean", "lean/Pkg/B.lean", "lean/Pkg/A.lean",
                  "lean/Pkg/C.lean"] &&
              paths ==
                #["lean/Pkg/A.lean", "lean/Pkg/B.lean", "lean/Pkg/C.lean",
                  "lean/PkgTest/ATest.lean"] },
    { name :=
        "a test is a file under test, tests or spec, or whose stem ends in Test, Tests, _test, _tests, .test or .spec, or starts with test_; a word that holds test inside it is not"
      run :=
        pure <|
          ["src/test/x.rs", "tests/x.rs", "spec/x.rb", "lean/PkgTest/ATest.lean", "a/FooTests.cs",
                  "foo_test.go", "foo_tests.rs", "web/a.test.ts", "web/a.spec.ts",
                  "test_foo.py"].all
              isTest &&
            !["src/attestation.rs", "lean/Editor/Contest.lean", "src/latest.rs", "testing/x.rs"].any
                isTest },
    { name :=
        "a module's name is the dotted path from its first capitalised component for Lean, and otherwise the stem, or the directory's for mod, lib, main and index"
      run :=
        pure <|
          moduleName "lean/Editor/VersionControl/Hunk.lean" == "Editor.VersionControl.Hunk" &&
            moduleName "Main.lean" == "Main" &&
            moduleName "src/foo.rs" == "foo" &&
            moduleName "src/bar/mod.rs" == "bar" &&
            moduleName "web/index.ts" == "web" &&
            moduleName "lib.rs" == "lib" },
    { name :=
        "a file depends on another when its text holds the other's module name as a whole word"
      run :=
        pure <|
          dependsOn (addedChange "a.rs" "use foo;\n") (addedChange "src/foo.rs" "") &&
            !dependsOn (addedChange "a.rs" "use foobar;\n") (addedChange "src/foo.rs" "") &&
            !dependsOn (addedChange "a.rs" "use myfoo;\n") (addedChange "src/foo.rs" "") &&
            !dependsOn (addedChange "foo.rs" "foo\n") (addedChange "foo.rs" "") },
    { name := "among files that are ready, more changed lines come first, then the path"
      run :=
        pure <|
          (orderFiles
                  #[(addedChange "z.rs" "", 3), (addedChange "a.rs" "", 3),
                    (addedChange "m.rs" "", 5)]).map
              (·.1.path) ==
            #["m.rs", "a.rs", "z.rs"] },
    { name := "a cycle of two files is ordered by the tie-break"
      run :=
        pure <|
          (orderFiles #[(addedChange "x.rs" "y\n", 1), (addedChange "y.rs" "x\n", 2)]).map
                (·.1.path) ==
              #["y.rs", "x.rs"] &&
            (orderFiles #[(addedChange "y.rs" "x\n", 2), (addedChange "x.rs" "y\n", 2)]).map
                (·.1.path) ==
              #["x.rs", "y.rs"] },
    { name :=
        "a deleted file's old text is its text: it comes after a file it names, though it changes more lines"
      run :=
        pure <|
          (orderFiles
                  #[({ path := "d.rs", old := some "uses e\n", new := none }, 9),
                    (addedChange "e.rs" "", 1)]).map
              (·.1.path) ==
            #["e.rs", "d.rs"] }]

/-- An entry of a source `⟨0⟩`, tracked and shown by `scenes` scenes. -/
def viewedEntry (scenes : Nat) : Buffer.ExcerptEntry :=
  { source := ⟨0⟩, viewed := some { scenes } }

/-- A record of three hunks: the first with an old and a new excerpt (0 and
1), kept; the second with a new one (2), reverted; the third with an old one
(3), open. -/
def threeHunks : ReviewRecord :=
  { root := "/r", against := "base", base := "B", olds := #[4, 5]
    hunks :=
      #[{ path := "a.lean", header := "a.lean @@ -1 +1 @@", old? := some 0, new? := some 1
          oldBuffer? := some 4, oldStart := 0, oldStop := 2, decision := .kept },
        { path := "b.lean", header := "b.lean @@ -0,0 +1 @@", new? := some 2
          decision := .reverted },
        { path := "c.lean", header := "c.lean @@ -1 +0,0 @@", old? := some 3, oldBuffer? := some 5
          oldStart := 0, oldStop := 2 }] }

/-- The checks of what a review's record says
(`Editor/VersionControl/ReviewHunks.lean`, "The record"). -/
def reviewRecordChecks : List Check :=
  [{  name := "a record decodes to what it encodes"
      run :=
        pure <|
          ReviewRecord.decode? threeHunks.encode == some threeHunks &&
            ReviewRecord.decode? (.str "x") == none },
    { name :=
        "the counts are the kept hunks, the reverted ones, and those an excerpt of which no scene has shown, said as the status line says them"
      run :=
        pure <|
          let none4 := #[viewedEntry 0, viewedEntry 0, viewedEntry 0, viewedEntry 0]
          let all := #[viewedEntry 1, viewedEntry 2, viewedEntry 1, viewedEntry 1]
          Review.counts threeHunks none4 == (1, 1, 3) &&
            Review.counts threeHunks all == (1, 1, 0) &&
            Review.statusText threeHunks none4 == "1 kept · 1 reverted · 3 not examined" &&
            -- An entry that is not tracked was never examined.
            Review.counts threeHunks
                #[{ source := ⟨0⟩ }, viewedEntry 1, viewedEntry 1, viewedEntry 1] ==
              (1, 1, 1) },
    { name := "a hunk with two excerpts is not examined until both are"
      run :=
        pure <|
          match threeHunks.hunks[0]? with
          | none => false
          | some first =>
            !first.examined #[viewedEntry 1, viewedEntry 0] &&
              !first.examined #[viewedEntry 0, viewedEntry 1] &&
              first.examined #[viewedEntry 1, viewedEntry 1] },
    { name :=
        "the hunk at an offset is the one whose excerpt holds it, both ends included, the first: a separator row is the hunk above's, and past the last is none"
      run :=
        pure <|
          let placed : Array Excerpt.Placed :=
            #[⟨0, 4, 0, 4⟩, ⟨5, 9, 0, 4⟩, ⟨10, 14, 0, 4⟩, ⟨15, 19, 0, 4⟩]
          Review.hunkAt placed threeHunks 0 == some 0 &&
            Review.hunkAt placed threeHunks 6 == some 0 &&
            -- The separator between the first hunk's new excerpt and the second's.
            Review.hunkAt placed threeHunks 9 == some 0 &&
            Review.hunkAt placed threeHunks 10 == some 1 &&
            Review.hunkAt placed threeHunks 19 == some 2 &&
            Review.hunkAt placed threeHunks 20 == none },
    { name := "a header names the decision once one is made"
      run :=
        pure <|
          threeHunks.hunks.map (·.headerText) ==
            #["a.lean @@ -1 +1 @@  kept", "b.lean @@ -0,0 +1 @@  reverted",
              "c.lean @@ -1 +0,0 @@"] }]

end ModelTest
