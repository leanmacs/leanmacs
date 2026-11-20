import Editor.Api
import Editor.Package
import GreetingApi

/-!
# The fake of `greeting-api`

A package that registers a command under every name the interface
declares, each putting a fixed text in the echo area. A consumer's tests
use it in place of any implementation, so they import no implementation
package.
-/

namespace GreetingApiTest

/-- What each of the fake's commands says. -/
def fakeText : String :=
  "the greeting fake"

/-- The fake: a package named `greeting-fake` that registers a command
under each of `GreetingApi.names`, saying `fakeText`. -/
def fake : Editor.Package :=
  { name := "greeting-fake"
    setup :=
      for name in GreetingApi.names do
        Editor.command name (Editor.message fakeText) }

end GreetingApiTest
