import Editor.Test.Fixture.Setup
import ModelTest.Check

/-!
# Model tests: `Editor/Test/Fixture/Setup.lean`

The model tests of the fixture harness's setups: their defaults, the
placeholders, substitution and scrubbing, the file model a setup makes,
the after-checks over it, the refusals and the comparison of lines:
`fixtureSetupChecks`. The root module `ModelTest` runs them; its module doc
says what they show.
-/

namespace ModelTest

open Editor
open Editor.Test.Fixture

/-- A fixture of `script`, with an expected file unless `expected` is
`false`. -/
def partsOf (script : String) (expected : Bool := true) : Parts :=
  { script, config := "t/config", expected := if expected then some "t/expected" else none }

/-- The checks of the setups, each pure. -/
def fixtureSetupChecks : List Check :=
  [{  name :=
        "the default setup declares nothing: its working directory /work/lean holds one empty file, nothing is seeded, scrubbed or checked after, and no process is scripted"
      run := do
        let setup := Setup.default
        let model := setup.model #[]
        return setup.workingDirectory == "/work/lean" && setup.seeds.isEmpty && setup.after.isEmpty &&
            !setup.dropJobLines && setup.directory.isNone && setup.file.isNone &&
            setup.processes == {} && model.directories.contains "/work/lean" &&
            (model.contents.map (·.1.toString)) == #["/work/lean/lakefile.lean"] &&
            Setup.of "tests/headless/no-such/script" == setup &&
            !Setup.declared "tests/headless/no-such/script" },
    { name :=
        "a script's placeholders are its @NAME@ parts of capitals and _, in order, each once, and an @ of an address or a lone @ is none"
      run :=
        return placeholders "commit e @DIR@/tree/\nrun @FILE@ @DIR@\nkey @ At -\nmail a@b.c @X_Y@" ==
            #["@DIR@", "@FILE@", "@X_Y@"] && placeholders "nothing here" == #[] },
    { name :=
        "a setup replaces @DIR@ with its directory and @FILE@ with its file, and scrubs its directory back to @DIR@ and drops job lines only when it says so"
      run := do
        let setup := Setup.oneFile "t/lines.txt" "lines.txt"
        let tree := { Setup.tree "t/tree" "/tmp/x.stepped0" with dropJobLines := true }
        return setup.substitute "run @FILE@ in @DIR@" == "run /fixture/lines.txt in /fixture" &&
            setup.scrub #["text 1: /fixture/lines.txt", "job 1 load: ok"] ==
              #["text 1: @DIR@/lines.txt", "job 1 load: ok"] &&
            tree.substitute "commit e @DIR@/tree/a" == "commit e /tmp/x.stepped0/tree/a" &&
            tree.scrub #["at /tmp/x.stepped0/tree", "job 2 grep: ok", "jobs"] ==
              #["at @DIR@/tree", "jobs"] &&
            Setup.default.substitute "run @FILE@" == "run @FILE@" },
    { name :=
        "a setup's model holds its working directory, each seeded file, every directory above them and each directory it names"
      run := do
        let model :=
          (Setup.tree "t/tree" "/tmp/x").model #[("/tmp/x/tree/n/a.txt", "a".toUTF8)] #["/tmp/x/tree", "/tmp/x/tree/n"]
        let has (path : String) := model.directories.contains path
        return has "/work/lean" && has "/tmp/x/tree/n" && has "/tmp/x/tree" && has "/tmp/x" && has "/tmp" &&
            has "/" && (model.file? "/tmp/x/tree/n/a.txt").map (·.bytes) == some "a".toUTF8 &&
            ancestors "/a/b/c" == #["/a/b", "/a", "/"] },
    { name :=
        "a file after-check holds when the model's file is the checked-in one, and fails naming it when it differs, is not there, or the checked-in file cannot be read; a prefix check fails naming the line"
      run := do
        let model := ({} : FileModel).withFile "/fixture/note.txt" "kept".toUTF8
        let checked (path : String) : Option ByteArray :=
          if path == "t/note-expected" then some "kept".toUTF8
          else if path == "t/other" then some "other".toUTF8 else none
        let fileEquals (target source : String) :=
          (After.fileEquals target source).failure? model #[] checked
        let starts := After.noLineStartsWith "commands:"
        return fileEquals "/fixture/note.txt" "t/note-expected" == none &&
            fileEquals "/fixture/note.txt" "t/other" == some "the model's /fixture/note.txt is not t/other" &&
            fileEquals "/fixture/gone.txt" "t/note-expected" == some "the model holds no /fixture/gone.txt" &&
            fileEquals "/fixture/note.txt" "t/unread" == some "t/unread cannot be read" &&
            starts.failure? model #["show", "texts: 1"] checked == none &&
            starts.failure? model #["commands: q"] checked ==
              some "an output line starts with \"commands:\": \"commands: q\"" },
    { name :=
        "the harness refuses a placeholder no setup replaces, a fixture with no expected file and no after-check, and an abort or a restarted outside the real-thread set, each naming the fixture"
      run := do
        let named (refused : Option String) (script : String) :=
          refused.any (·.startsWith script)
        let file := Setup.oneFile "t/n.txt" "n.txt" #[.noLineStartsWith "x"]
        return named (refusal? (partsOf "t/a/script") "run @FILE@\n" none false) "t/a/script" &&
            named (refusal? (partsOf "t/a/script") "run @FILE@ @DIR@\n" (some { file with directory := none }) false)
              "t/a/script" &&
            refusal? (partsOf "t/a/script") "run @FILE@\n" (some file) false == none &&
            named (refusal? (partsOf "t/b/script" false) "show\n" none false) "t/b/script" &&
            refusal? (partsOf "t/b/script" false) "show\n" (some file) false == none &&
            named (refusal? (partsOf "t/c/script") "show\n  abort\n" none false) "t/c/script" &&
            named (refusal? (partsOf "t/c/script") "restarted 30\n" none false) "t/c/script" &&
            refusal? (partsOf "t/c/script") "show\nabort\n" none true == none &&
            refusal? (partsOf "t/c/script") "# abort\nshow\n" none false == none },
    { name :=
        "lines are compared as the shell's diff sees them: trailing empty lines dropped, the first difference named with its number and both texts, and the lines each side alone has listed both ways"
      run :=
        return textLines "a\nb\n\n\n" == #["a", "b"] && textLines "" == #[] &&
            firstDifference? #["a", "b"] #["a", "b"] == none &&
            firstDifference? #["a", "b"] #["a", "c"] == some "line 2 differs: expected \"b\", got \"c\"" &&
            firstDifference? #["a", "b"] #["a"] == some "line 2 is missing: expected \"b\"" &&
            firstDifference? #["a"] #["a", "c"] == some "line 2 is extra: got \"c\"" &&
            bothWays #["a", "b"] #["a", "c", "d"] == #["< 2: b", "> 2: c", "> 3: d"] &&
            bothWays #["a"] #["a"] == #[] },
    { name :=
        "a runner entry's CLI output is compared both ways with its stepped run and with its expected file: nothing when the three agree, the lines each side alone has when the two runs differ, and the first difference from the expected file when the two runs agree on something else"
      run :=
        return compared #["a"] #["a"] #["a"] == #[] &&
            compared #["a"] #["b"] #["a"] ==
              #["the CLI over a real loop thread (<) and the stepped run (>) printed otherwise: < 1: a; > 1: b"] &&
            compared #["b"] #["b"] #["a"] ==
              #["the CLI's output is not its expected file: line 1 differs: expected \"a\", got \"b\""] &&
            compared #["b"] #["a"] #["a"] ==
              #["the CLI over a real loop thread (<) and the stepped run (>) printed otherwise: < 1: b; > 1: a",
                "the CLI's output is not its expected file: line 1 differs: expected \"a\", got \"b\""] }]

end ModelTest
