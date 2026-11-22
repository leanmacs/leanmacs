import Editor.Api
import Editor.Package
import ExecuteCommandApi

/-!
# The fake of `execute-command-api`

A package that registers a command under every name the interface
declares, each putting a fixed text in the echo area. A consumer's tests
use it in place of any implementation, so they import no implementation
package.
-/

namespace ExecuteCommandApiTest

/-- What each of the fake's commands says. -/
def fakeText : String :=
  "the execute-command fake"

/-- The fake: a package named `execute-command-fake` that registers a
command under each of `ExecuteCommandApi.names`, saying `fakeText`. -/
def fake : Editor.Package :=
  { name := "execute-command-fake"
    setup :=
      for name in ExecuteCommandApi.names do
        Editor.command name (Editor.message fakeText) }

end ExecuteCommandApiTest
