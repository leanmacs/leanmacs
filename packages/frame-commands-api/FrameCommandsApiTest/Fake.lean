import Editor.Api
import Editor.Package
import FrameCommandsApi

/-!
# The fake of `frame-commands-api`

A package that registers a command under every name the interface
declares, each putting a fixed text in the echo area. A consumer's tests
use it in place of any implementation, so they import no implementation
package.
-/

namespace FrameCommandsApiTest

/-- What each of the fake's commands says. -/
def fakeText : String :=
  "the frame commands fake"

/-- The fake: a package named `frame-commands-fake` that registers a command
under each of `FrameCommandsApi.names`, saying `fakeText`. -/
def fake : Editor.Package :=
  { name := "frame-commands-fake"
    setup :=
      for name in FrameCommandsApi.names do
        Editor.command name (Editor.message fakeText) }

end FrameCommandsApiTest
