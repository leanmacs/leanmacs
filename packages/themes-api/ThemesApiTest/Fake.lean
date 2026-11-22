import Editor.Api
import Editor.Package
import ThemesApi

/-!
# The fake of `themes-api`

A package that registers a command under every name the interface
declares, each putting a fixed text in the echo area. A consumer's tests
use it in place of any implementation, so they import no implementation
package.
-/

namespace ThemesApiTest

/-- What each of the fake's commands says. -/
def fakeText : String :=
  "the themes fake"

/-- The fake: a package named `themes-fake` that registers a command under
each of `ThemesApi.names`, saying `fakeText`. -/
def fake : Editor.Package :=
  { name := "themes-fake"
    setup :=
      for name in ThemesApi.names do
        Editor.command name (Editor.message fakeText) }

end ThemesApiTest
