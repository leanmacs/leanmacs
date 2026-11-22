import Editor.Api
import Editor.Package
import TabCommandsApi

/-!
# The fake of `tab-commands-api`

A package that registers a command under every name the interface
declares, each putting a fixed text in the echo area. A consumer's tests
use it in place of any implementation, so they import no implementation
package.
-/

namespace TabCommandsApiTest

/-- What each of the fake's commands says. -/
def fakeText : String :=
  "the tab commands fake"

/-- The fake: a package named `tab-commands-fake` that registers a command
under each of `TabCommandsApi.names`, saying `fakeText`. -/
def fake : Editor.Package :=
  { name := "tab-commands-fake"
    setup :=
      for name in TabCommandsApi.names do
        Editor.command name (Editor.message fakeText) }

end TabCommandsApiTest
