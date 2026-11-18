import Editor.VersionControl.Views
import ModelTest.Check

/-!
# Model tests: `Editor/VersionControl/Views.lean`

The model tests of `Editor/VersionControl/Views.lean`:
`versionControlViewsChecks`. The root module `ModelTest` runs them; its
module doc says what each shows.
-/

namespace ModelTest

open Editor.VersionControl

/-- The checks of what the version-control buffers share
(`Editor/VersionControl/Views.lean`), on values. -/
def versionControlViewsChecks : List Check :=
  [{  name :=
        "a day is the author time's date in UTC: 0 is 1970-01-01, 951782400 is 2000-02-29 and 1767225600 is 2026-01-01"
      run :=
        pure <|
          dayOf 0 == "1970-01-01" && dayOf 951782400 == "2000-02-29" &&
            dayOf 1767225600 == "2026-01-01" &&
            dayOf (1767225600 + 86399) == "2026-01-01" }]

end ModelTest
