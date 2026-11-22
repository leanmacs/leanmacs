import Editor.Api
import Editor.Package
import WindowCommandsApi

/-!
# The fake of `window-commands-api`

A package that registers a command under every name the interface
declares, each putting a fixed text in the echo area. A consumer's tests
use it in place of any implementation, so they import no implementation
package.
-/

namespace WindowCommandsApiTest

/-- What each of the fake's commands says. -/
def fakeText : String :=
  "the window commands fake"

/-- The fake: a package named `window-commands-fake` that registers a command
under each of `WindowCommandsApi.names`, saying `fakeText`. -/
def fake : Editor.Package :=
  { name := "window-commands-fake"
    setup :=
      for name in WindowCommandsApi.names do
        Editor.command name (Editor.message fakeText) }

end WindowCommandsApiTest
