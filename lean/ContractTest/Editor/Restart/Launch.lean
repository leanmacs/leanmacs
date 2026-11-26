import ContractTest.Check
import Editor.Restart.Handover
import Editor.Restart.Launch

/-!
# Contract tests: `Editor/Restart/`

The tests of what crosses between Lean's restart and the Rust launcher
(`crates/editor-launch`) as files both sides read: `launchRecordChecks`,
over the fixture directory `tests/launch`, which `contract-test` is handed.

- **The hand-over record.** Lean writes it (`Editor.Restart.Handover.encode`)
  and the launcher reads it (`handover::decode`, whose test reads the same
  file, `tests/launch/handover-v1`, and `fixture()` holds the same value).
- **The launch arguments.** The launcher execs a candidate with its launch
  flags then the editor's own arguments (`launch::restoring`, whose test
  `the_hand_over_exec_arguments_are_the_checked_in_fixture` reads
  `tests/launch/arguments-v1`), and Lean takes the flags back
  (`Editor.Restart.Launch.strip`).

The decisions on each side are their own tests': Lean's restart in
`ModelTest.restartChecks` and `ModelTest.restartHandoverChecks`, the
launcher's in `editor_launch`'s. The root module `ContractTest` runs them;
its module doc says what each shows.
-/

namespace ContractTest

open Editor
open Editor.Restart

/-- The value `tests/launch/handover-v1` holds: a restart's record with a
session, two candidates and arguments holding a tab, a newline and a
backslash, as `handover.rs`'s `fixture()` holds it. -/
def handoverFixture : Handover :=
  { session := "/Users/a/Library/Application Support/Leanmacs/session/session-3.json"
    shipped := "/Applications/Leanmacs.app/Contents/MacOS/editor"
    candidates :=
      #["/Users/a/Library/Application Support/Leanmacs/executables/7/editor",
        "/Applications/Leanmacs.app/Contents/MacOS/editor"]
    arguments := ["--state", "/tmp/état\ttab", "two\nlines and a \\ back"] }

/-- The launch `tests/launch/arguments-v1` gives Lean's run, and the
editor's own arguments after it: a hand-over of the record
`/s/session/handover` whose first candidate failed, as the launcher's
test makes it. -/
def argumentsFixture : Launch × List String :=
  let launch : Launch :=
    { launchedBy := some "/Apps/Leanmacs.app/Contents/MacOS/leanmacs"
      shipped := some "/Apps/Leanmacs.app/Contents/MacOS/editor"
      restore := some "/s/session/session-4.json", handedOver := some "/s/session/handover"
      failed := #["/new/editor"] }
  (launch, ["--state", "/s"])

/-- The lines of `text`, one argument a line, the empty line after the last
line feed dropped. -/
def argumentLines (text : String) : List String :=
  let lines := text.splitOn "\n"
  if lines.getLast? == some "" then lines.dropLast else lines

/-- The checks of the launch fixtures in `fixtures` (`tests/launch`). -/
def launchRecordChecks (fixtures : System.FilePath) : List Check :=
  [{  name :=
        "Lean's encoding of the hand-over record's value is tests/launch/handover-v1, byte for byte, the file the launcher's decoder reads"
      run := do
        let bytes ← IO.FS.readBinFile (fixtures / "handover-v1")
        return handoverFixture.encode.toUTF8 == bytes },
    { name :=
        "Lean takes the launch flags of tests/launch/arguments-v1, the arguments the launcher execs a hand-over's candidate with, back into the launch it handed over, and leaves the editor's own arguments"
      run := do
        let text ← IO.FS.readFile (fixtures / "arguments-v1")
        return Launch.strip (argumentLines text) == argumentsFixture }]

end ContractTest
