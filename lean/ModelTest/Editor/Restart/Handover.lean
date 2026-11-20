import Editor.Restart.Handover
import ModelTest.Check

/-!
# Model tests: `Editor/Restart/Handover.lean`

The model tests of `Editor/Restart/Handover.lean`: `restartHandoverChecks`.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor.Restart

namespace RestartHandoverTest

/-- The text of `tests/launch/handover-v1`, kept here as a literal, byte for
byte: the Rust decoder reads that file (`crates/editor-launch/src/handover.rs`)
and this encoder must write it. -/
def fixtureText : String :=
  "leanmacs-handover 1\n" ++
    "session /Users/a/Library/Application Support/Leanmacs/session/session-3.json\n" ++
    "shipped /Applications/Leanmacs.app/Contents/MacOS/editor\n" ++
    "candidate /Users/a/Library/Application Support/Leanmacs/executables/7/editor\n" ++
    "candidate /Applications/Leanmacs.app/Contents/MacOS/editor\n" ++
    "argument --state\n" ++
    "argument /tmp/état\ttab\n" ++
    "argument two\\nlines and a \\\\ back\n"

/-- The value the fixture holds. -/
def fixture : Handover :=
  { session := "/Users/a/Library/Application Support/Leanmacs/session/session-3.json"
    shipped := "/Applications/Leanmacs.app/Contents/MacOS/editor"
    candidates :=
      #["/Users/a/Library/Application Support/Leanmacs/executables/7/editor",
        "/Applications/Leanmacs.app/Contents/MacOS/editor"]
    arguments := ["--state", "/tmp/état\ttab", "two\nlines and a \\ back"] }

/-- `texts` as paths. -/
def paths (texts : List String) : Array System.FilePath :=
  texts.toArray.map System.FilePath.mk

/-- A plan for the fixture, with `launcher`. -/
def plan (launcher : Option System.FilePath) : Plan :=
  { record := "/s/session/handover", handover := fixture, launcher }

end RestartHandoverTest

open RestartHandoverTest

/-- The checks of the hand-over record and the restart's plan
(`Editor/Restart/Handover.lean`). -/
def restartHandoverChecks : List Check :=
  [{  name := "encode of the fixture's value is tests/launch/handover-v1, byte for byte"
      run := pure (fixture.encode == fixtureText) },
    { name := "a value's backslash and newline are escaped, and nothing else"
      run :=
        pure
          (escape "a\\b\nc\td é" == "a\\\\b\\nc\td é" && escape "" == "" &&
            (escape "x\ny").all (· != '\n')) },
    { name :=
        "a restart's candidates are the running executable and the shipped one, the same path once; into comes first"
      run :=
        let launch : Launch := { running := some "/A/editor", shipped := some "/A/editor" }
        let other : Launch := { running := some "/u/7/editor", shipped := some "/A/editor" }
        pure
          (candidates launch none == paths ["/A/editor"] &&
            candidates other none == paths ["/u/7/editor", "/A/editor"] &&
            candidates other (some "/u/8/editor") ==
              paths ["/u/8/editor", "/u/7/editor", "/A/editor"] &&
            candidates {} (some "/u/8/editor") == paths ["/u/8/editor"]) },
    { name := "with a launcher the plan execs it with --handover and the record"
      run :=
        pure
          ((plan (some "/A.app/Contents/MacOS/leanmacs")).invocation ==
            { program := "/A.app/Contents/MacOS/leanmacs"
              arguments := #["--handover", "/s/session/handover"] }) },
    { name :=
        "with no launcher the plan execs its first candidate with --restore, --handed-over and the arguments"
      run :=
        pure
          ((plan none).invocation ==
            { program := "/Users/a/Library/Application Support/Leanmacs/executables/7/editor"
              arguments :=
                #["--restore",
                    "/Users/a/Library/Application Support/Leanmacs/session/session-3.json",
                    "--handed-over", "/s/session/handover"] ++
                  fixture.arguments.toArray }) },
    { name := "the line said while handing over names no fallback without a launcher"
      run :=
        pure
          (handingLine true == "restart: handing the session over; the window closes and reopens" &&
            handingLine false ==
              "restart: handing the session over; the window closes and reopens (no launcher, so no fallback)") },
    { name :=
        "a host execs the plan's invocation once through the exec it was handed, and when that answers, the exec failed: it says so, keeping the session, and answers status 1"
      run := do
        let happened ← IO.mkRef (#[] : Array String)
        let replaced ← IO.mkRef (#[] : Array Invocation)
        let replace (invocation : Invocation) : IO String := do
          replaced.modify (·.push invocation)
          happened.modify (·.push "exec")
          return "it is not there"
        let say (line : String) : IO Unit := happened.modify (·.push line)
        let launched := plan (some "/A.app/Contents/MacOS/leanmacs")
        let status ← launched.exec replace say
        return status == 1 && (← replaced.get) == #[launched.invocation] &&
            (← happened.get) ==
              #["exec",
                "editor: the restart could not start /A.app/Contents/MacOS/leanmacs: it is not there; the session is kept and the next start restores it"] },
    { name := "the exec of a host that has none refuses every plan, saying so"
      run := return (← noExec (plan none).invocation) == "no exec in this host" }]

end ModelTest
