import Editor.VersionControl
import Editor.VersionControl.HistoryRead
import ModelTest.Check

/-!
# Model tests: `Editor/VersionControl/HistoryRead.lean`

The model tests of `Editor/VersionControl/HistoryRead.lean`:
`versionControlHistoryParserChecks`. The root module `ModelTest` runs them;
its module doc says what each shows.

## The fixtures

What git 2.56.1 printed, byte for byte, with each NUL written `\x00` and
each tab `\t`, with `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, a
fresh `HOME`, committer `a <a@example.com>` at `@1767225600 +0000`, and the
author `a <a@example.com>` at that time unless a fixture's comment names
another (`GIT_AUTHOR_NAME`, `GIT_AUTHOR_DATE`). `g` is `git -c
commit.gpgsign=false`.

The log and blame fixtures share one repository, made by `git -c
init.defaultBranch=main init r`: `printf '1\n2\n3\n' > a.txt`, committed
`base`; on a branch `side`, `s.txt` written and committed `side`; on
`main`, `a.txt`'s second line made `two` and committed `change two` by the
author `Bé Two` at `@1767312000 +0000`; `g merge --no-ff side -m 'merge
side'` at `@1767398400 +0000`; then the line `four` added and committed
`add four` at `@1767484800 +0000`.
-/

namespace ModelTest

open Editor

/-- The ids of the log and blame fixtures' commits. -/
def baseId : String :=
  "4e9b80f9c46e95e323c5718504996302c257fe28"

/-- `change two`'s id. -/
def twoId : String :=
  "45be447bdfc6e6fd903fb2d9fd59d6abe5d8a3fd"

/-- `side`'s id. -/
def sideId : String :=
  "a960a05e6c26106e3c78aac9b6b36d01d99faaca"

/-- `merge side`'s id. -/
def mergeId : String :=
  "c00f8fbb146ac3c3c3a3290cd520b326e58957ca"

/-- `add four`'s id. -/
def fourId : String :=
  "fb0a947ecf1fc53d42ede22a5b24e55df15050ff"

/-- What `git rev-list --first-parent --max-count=4 --no-commit-header
--encoding=UTF-8 --format=%H%x00%P%x00%an%x00%at%x00%s HEAD --` printed:
the merge has two parents, `base` none. -/
def revListFixture : String :=
  s!"{fourId}\x00{mergeId}\x00a\x001767484800\x00add four\n" ++
    s!"{mergeId}\x00{twoId} {sideId}\x00a\x001767398400\x00merge side\n" ++
    s!"{twoId}\x00{baseId}\x00Bé Two\x001767312000\x00change two\n" ++
    s!"{baseId}\x00\x00a\x001767225600\x00base\n"

/-- The header lines git prints of a commit the first time blame names it:
its author `author` at `time`, the fixed committer, and its subject. -/
def blameHeaders (author : String) (time : Nat) (subject : String) : String :=
  s!"author {author}\nauthor-mail <a@example.com>\nauthor-time {time}\nauthor-tz +0000\n" ++
    "committer a\ncommitter-mail <a@example.com>\ncommitter-time 1767225600\n" ++
    s!"committer-tz +0000\nsummary {subject}\n"

/-- Blame's group of `a.txt`'s line 1, `base`'s, its first naming. -/
def blameFirst : String :=
  s!"{baseId} 1 1 1\n" ++ blameHeaders "a" 1767225600 "base" ++ "boundary\nfilename a.txt\n\t1\n"

/-- Blame's group of line 2, `change two`'s, by `Bé Two`. -/
def blameSecond : String :=
  s!"{twoId} 2 2 1\n" ++ blameHeaders "Bé Two" 1767312000 "change two" ++
    s!"previous {baseId} a.txt\nfilename a.txt\n\ttwo\n"

/-- Blame's group of line 3, `base`'s again, named a second time with no
headers. -/
def blameThird : String :=
  s!"{baseId} 3 3 1\n\t3\n"

/-- Blame's group of line 4, `add four`'s. -/
def blameFourth : String :=
  s!"{fourId} 4 4 1\n" ++ blameHeaders "a" 1767484800 "add four" ++
    s!"previous {mergeId} a.txt\nfilename a.txt\n\tfour\n"

/-- What `git blame --porcelain --ignore-revs-file= HEAD -- a.txt` printed:
`base` named twice, the second time with no headers, and an author who is
not the committer. -/
def blameFixture : String :=
  blameFirst ++ blameSecond ++ blameThird ++ blameFourth

/-- What `git range-diff --no-color --no-notes --creation-factor=60 main old
new` printed in a repository made by `git -c init.defaultBranch=main init
rd`: `printf '1\n2\n3\n' > a.txt` committed `base`; on `old`, `p.txt`
holding `p` committed `add p`, `x.txt` holding `x` committed `add x`, and
`q.txt` holding the lines `1` to `10` committed `add q`; on `new`, from
`main`, `p.txt` committed `add p` with the committer at `@1767312000
+0000`, `q.txt` with its sixth line `six` committed `add q`, and `y.txt`
holding `y` committed `add y`. -/
def rangeDiffFixture : String :=
  "1:  5877f59 = 1:  f96f53a add p\n" ++ "2:  5464c85 < -:  ------- add x\n" ++
    "3:  9456085 ! 2:  3278910 add q\n" ++
    "    @@ q.txt (new)\n" ++
    "     +3\n" ++
    "     +4\n" ++
    "     +5\n" ++
    "    -+6\n" ++
    "    ++six\n" ++
    "     +7\n" ++
    "     +8\n" ++
    "     +9\n" ++
    "-:  ------- > 3:  882f272 add y\n"

/-- The checks of the readers of git's history
(`Editor/VersionControl/HistoryRead.lean`), on the fixtures. -/
def versionControlHistoryParserChecks : List Check :=
  let authored (author : String) (time : Nat) (subject : String) : VersionControl.Authored :=
    { author, time, subject }
  let blamed : VersionControl.Blame :=
    { commits :=
        #[(baseId, authored "a" 1767225600 "base"),
          (twoId, authored "Bé Two" 1767312000 "change two"),
          (fourId, authored "a" 1767484800 "add four")]
      lines :=
        #[{ id := baseId, text := "1" }, { id := twoId, text := "two" },
          { id := baseId, text := "3" }, { id := fourId, text := "four" }] }
  let refused {α : Type} (reply : Except String α) : Bool := reply matches .error _
  [{  name :=
        "a log reads each commit newest first with its parents, a merge's both and a root's none, its author by name, its time and its subject"
      run :=
        pure <|
          (VersionControl.HistoryRead.parseLog revListFixture.toUTF8).toOption ==
            some
              #[{ id := fourId, parents := #[mergeId],
                  authored := authored "a" 1767484800 "add four" },
                { id := mergeId, parents := #[twoId, sideId]
                  authored := authored "a" 1767398400 "merge side" },
                { id := twoId, parents := #[baseId]
                  authored := authored "Bé Two" 1767312000 "change two" },
                { id := baseId, authored := authored "a" 1767225600 "base" }] },
    { name := "an empty log reads as no commits"
      run := pure <| (VersionControl.HistoryRead.parseLog .empty).toOption == some #[] },
    { name := "a log record with too few fields, a time that is not a number, or no id is refused"
      run :=
        pure <|
          refused
              (VersionControl.HistoryRead.parseLog s!"{baseId}\x00\x00a\x001767225600\n".toUTF8) &&
            refused
              (VersionControl.HistoryRead.parseLog
                s!"{baseId}\x00\x00a\x00soon\x00base\n".toUTF8) &&
            refused
              (VersionControl.HistoryRead.parseLog "\x00\x00a\x001767225600\x00base\n".toUTF8) },
    { name :=
        "a blame reads each line with the commit that last changed it, each commit once in the order of its first line with its author, author time and subject, a commit named twice read once, and an author who is not the committer read as the author"
      run :=
        pure <|
          (VersionControl.HistoryRead.parseBlame blameFixture.toUTF8).toOption == some blamed },
    { name := "a blame whose lines come out of order places each line by its final number"
      run :=
        pure <|
          (VersionControl.HistoryRead.parseBlame
                (blameFirst ++ s!"{baseId} 3 3 1\n\t3\n" ++
                    (s!"{twoId} 2 2 1\n" ++ blameHeaders "Bé Two" 1767312000 "change two" ++
                      "\ttwo\n") ++
                    blameFourth).toUTF8).toOption ==
            some blamed },
    { name := "an empty blame reads as no lines"
      run := pure <| (VersionControl.HistoryRead.parseBlame .empty).toOption == some {} },
    { name :=
        "a blame naming a commit before its headers, missing a line, or placing two at one line is refused"
      run :=
        pure <|
          refused (VersionControl.HistoryRead.parseBlame s!"{twoId} 1 1 1\n\ttwo\n".toUTF8) &&
            refused
              (VersionControl.HistoryRead.parseBlame
                (blameFirst ++ blameSecond ++ blameFourth).toUTF8) &&
            refused
              (VersionControl.HistoryRead.parseBlame
                (blameFirst ++ blameSecond ++ s!"{baseId} 2 2 1\n\t3\n" ++ blameFourth).toUTF8) },
    { name :=
        "a range-diff reads each pair header in the order printed, =, <, ! and >, each side's index or none, and keeps the whole text, the diff of diffs among it"
      run :=
        pure <|
          (VersionControl.HistoryRead.parseRangeDiff rangeDiffFixture.toUTF8).toOption ==
            some
              { pairs :=
                  #[{ old := some 1, new := some 1, relation := .same },
                    { old := some 2, new := none, relation := .removed },
                    { old := some 3, new := some 2, relation := .changed },
                    { old := none, new := some 3, relation := .added }]
                text := rangeDiffFixture } },
    { name := "a range-diff whose numbers are padded to the widest reads the same"
      run :=
        pure <|
          (VersionControl.HistoryRead.parseRangeDiff
                  " 9:  5877f59 = 10:  f96f53a add p\n10:  5464c85 < -:  ------- add x\n".toUTF8).toOption.map
              (·.pairs) ==
            some
              #[{ old := some 9, new := some 10, relation := .same },
                { old := some 10, new := none, relation := .removed }] },
    { name := "a range-diff line that is neither a pair header nor indented diff text is refused"
      run :=
        pure <|
          refused
              (VersionControl.HistoryRead.parseRangeDiff "1:  5877f59 ? 1:  f96f53a p\n".toUTF8) &&
            refused (VersionControl.HistoryRead.parseRangeDiff "what\n".toUTF8) }]

end ModelTest
