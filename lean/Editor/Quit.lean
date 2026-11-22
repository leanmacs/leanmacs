import Editor.Api

/-!
# The quit rule

What asks the editor to quit, and the name the quit command is registered
under. Both are the core's, because the loop runs both whether or not any
package registers a command (`Editor/Loop.lean`, "Quit"):

- **A window's close request runs the rule itself** (`closeRequested`): it
  asks the editor to quit (`quit`, `Editor/Api.lean`) and says a refusal in
  the echo area (`notQuitting`). So a host that registers no command still
  closes, and config's `quit` does not replace the close button's rule.
- **The system's quit runs the command named `quit`** (`name`), so config's
  command of that name runs in its place. The frame commands bind
  Command-Q to that name, and `window-quit` runs it on the last window.

The command registered under the name is a package's: the ex line's
(`Editor/Ex.lean`, "Quit"), whose `quit` is this rule and which binds the
ex name `q` to it. A set with no such package has no command `quit`: the
system's quit then says so, and the close button still quits. This is a
name the core itself must offer every implementation
(`docs/design/extension-points.md`, "Reaches by name"), as the clipboard
names are (`Editor/Clipboard.lean`).

Pinned by `ModelTest.quitChecks`, and by the loop's checks of a close
request and of the system's quit (`ModelTest.dispatchQuitChecks`,
`ModelTest.systemQuitChecks`, `ModelTest/Editor/Loop.lean`).
-/

namespace Editor.Quit

/-- The name the quit command is registered under. -/
def name : String :=
  "quit"

/-- What the echo area says when a quit was refused: the command's name,
then why. -/
def notQuitting : QuitRefusal → String
  | .unsaved buffer => s!"{name}: {buffer} has unsaved changes"

/-- The quit rule, as the quit command and a window's close request run it:
asks the editor to quit (`quit`, `Editor/Api.lean`), and says a refusal in
the echo area (`notQuitting`). The loop runs it for a close request
(`Editor/Loop.lean`, "Quit"). -/
def closeRequested : EditorM Unit := do
  if let .error refusal← quit then
    message (notQuitting refusal)

end Editor.Quit
