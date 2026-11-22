import Editor.Api
import Editor.Package
import ProjectSearchApi

/-!
# The fake of `project-search-api`

A package that registers a command under every name the interface
declares, each putting a fixed text in the echo area. A consumer's tests
use it in place of any implementation, so they import no implementation
package.
-/

namespace ProjectSearchApiTest

/-- What each of the fake's commands says. -/
def fakeText : String :=
  "the project-search fake"

/-- The fake: a package named `project-search-fake` that registers a command
under each of `ProjectSearchApi.names`, saying `fakeText`. -/
def fake : Editor.Package :=
  { name := "project-search-fake"
    setup :=
      for name in ProjectSearchApi.names do
        Editor.command name (Editor.message fakeText) }

end ProjectSearchApiTest
