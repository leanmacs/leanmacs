import VersionControl.Views
import VersionControlTest.Check

/-!
# Model tests: `VersionControl/Views.lean`

The model tests of `VersionControl/Views.lean`: `versionControlViewsChecks`.
The test driver's root, `VersionControlTest/Model.lean`, runs them; its
module doc says what each shows.
-/

namespace VersionControlTest

open Editor.VersionControl

/-- The checks of what the version-control buffers share
(`VersionControl/Views.lean`), on values. -/
def versionControlViewsChecks : List Check :=
  [{  name :=
        "a day is the author time's date in UTC: 0 is 1970-01-01, 951782400 is 2000-02-29 and 1767225600 is 2026-01-01"
      run :=
        pure <|
          dayOf 0 == "1970-01-01" && dayOf 951782400 == "2000-02-29" &&
            dayOf 1767225600 == "2026-01-01" &&
            dayOf (1767225600 + 86399) == "2026-01-01" }]

end VersionControlTest
