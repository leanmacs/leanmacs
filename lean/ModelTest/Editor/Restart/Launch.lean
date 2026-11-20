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
            (({ shipped := some "/e" } : Launch), ["--restore"]) }]

end ModelTest
