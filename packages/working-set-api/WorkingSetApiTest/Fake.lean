import Editor.Api
import Editor.Package
import WorkingSetApi

/-!
# The fake of `working-set-api`

A package that registers a command under every name the interface
declares, each putting a fixed text in the echo area. A consumer's tests
use it in place of any implementation, so they import no implementation
package.
-/

namespace WorkingSetApiTest

/-- What each of the fake's commands says. -/
def fakeText : String :=
  "the working-set fake"

/-- The fake: a package named `working-set-fake` that registers a command
under each of `WorkingSetApi.names`, saying `fakeText`. -/
def fake : Editor.Package :=
  { name := "working-set-fake"
    setup :=
      for name in WorkingSetApi.names do
        Editor.command name (Editor.message fakeText) }

end WorkingSetApiTest
