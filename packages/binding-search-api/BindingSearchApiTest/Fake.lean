import BindingSearchApi
import Editor.Api
import Editor.Package

/-!
# The fake of `binding-search-api`

A package that registers a command under every name the interface
declares, each putting a fixed text in the echo area. A consumer's tests
use it in place of any implementation, so they import no implementation
package.
-/

namespace BindingSearchApiTest

/-- What each of the fake's commands says. -/
def fakeText : String :=
  "the binding-search fake"

/-- The fake: a package named `binding-search-fake` that registers a
command under each of `BindingSearchApi.names`, saying `fakeText`. -/
def fake : Editor.Package :=
  { name := "binding-search-fake"
    setup :=
      for name in BindingSearchApi.names do
        Editor.command name (Editor.message fakeText) }

end BindingSearchApiTest
