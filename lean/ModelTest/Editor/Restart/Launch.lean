import Editor.Restart.Launch
import ModelTest.Check

/-!
# Model tests: `Editor/Restart/Launch.lean`

The model tests of `Editor/Restart/Launch.lean`: `restartLaunchChecks`. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor.Restart

/-- The checks of the launch flags (`Launch.strip`). -/
def restartLaunchChecks : List Check :=
  [{  name :=
        "strip takes each launch flag from the front with its value, in any order, and --failed each time it is given"
      run :=
        pure <|
          Launch.strip
              ["--shipped", "/A.app/editor", "--failed", "/x", "--launched-by", "/A.app/leanmacs",
                "--restore", "/s/session-2.json", "--handed-over", "/s/handover", "--failed", "/y",
                "headless", "a"] ==
            (({ launchedBy := some "/A.app/leanmacs", shipped := some "/A.app/editor",
                restore := some "/s/session-2.json", handedOver := some "/s/handover",
                failed := #["/x", "/y"] } :
                Launch),
              ["headless", "a"]) },
    { name := "strip stops at the first other word, so a flag after it is the mode's"
      run :=
        pure <|
          Launch.strip ["--shipped", "/e", "--probe", "--launched-by", "/l"] ==
              (({ shipped := some "/e" } : Launch), ["--probe", "--launched-by", "/l"]) &&
            Launch.strip ["notes.txt"] == (({} : Launch), ["notes.txt"]) &&
            Launch.strip [] == (({} : Launch), []) },
    { name := "a launch flag with no value is left in the arguments, for the mode to refuse"
      run :=
        pure <|
          Launch.strip ["--shipped", "/e", "--restore"] ==
            (({ shipped := some "/e" } : Launch), ["--restore"]) },
    { name :=
        "a run handed a record with no --restore is a cold start under watch: with no state directory it removes the record at once, with one at its restore's hand-shake; a run handed none removes nothing"
      run :=
        let cold : Launch := { handedOver := some "/d/launch/cold-7" }
        pure
          (cold.removedAtStart (stateDirectory := false) == some "/d/launch/cold-7" &&
            cold.removedAtStart (stateDirectory := true) == none &&
            ({} : Launch).removedAtStart (stateDirectory := false) == none) },
    { name :=
        "a headless run that ends by itself, its script run or a command having quit it, removes the record it was handed, so its watcher sees it go and starts no fallback; one that handed the session on removes nothing, since the record is the next run's; a run handed none removes nothing"
      run :=
        let handed : Launch :=
          { restore := some "/s/session/session-1.json", handedOver := some "/s/session/handover" }
        pure
          (handed.removedAtEnd (handedOn := false) == some "/s/session/handover" &&
            handed.removedAtEnd (handedOn := true) == none &&
            ({} : Launch).removedAtEnd (handedOn := false) == none) },
    { name :=
        "the probe removes the record it was handed, once main is reached, and prints the executable it is"
      run :=
        let cold : Launch :=
          { launchedBy := some "/A.app/Contents/MacOS/leanmacs",
            handedOver := some "/d/launch/cold-7" }
        pure
          (cold.probeRemoves == some "/d/launch/cold-7" && ({} : Launch).probeRemoves == none &&
            probeLines cold "/d/editors/c0/2/editor" (some ("/A.app", some "io.x")) ==
              ["probe: ok", "launched-by /A.app/Contents/MacOS/leanmacs",
                "bundle /A.app identifier io.x", "executable /d/editors/c0/2/editor"] &&
            probeLines {} "/e" none ==
              ["probe: ok", "launched-by none", "bundle none", "executable /e"]) }]

end ModelTest
