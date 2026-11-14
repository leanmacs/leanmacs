import Editor.Config.Registry
import Editor.Ex
import Editor.Files

/-!
# The ex line's commands and the ex names that ship, as compiled code registers them

What a host is handed so that it has the ex command line (`Editor/Ex.lean`):
the registrations of its commands, and the ex bindings that ship. A host
registers both for the owner `compiled` when its loop starts, before any
config (`Editor/Config/Registry.lean`, "Compiled commands", "Ex bindings"),
so they hold when config fails to load, a reload does not replace them, and
config's binding of a shipped ex name runs in its place until a reload
drops it.

- **`Ex.commands`**: each a command that is given what it was called with
  (`Action.call`).
  - `ex` opens the ex line, and runs the line it is answered
    (`Ex.exCommand`). A host must be handed the minibuffer's commands too
    (`Editor/Minibuffer/Compiled.lean`) for that prompt to be answered.
  - `quit` asks the editor to quit, and says a refusal in the echo area
    (`Ex.quitCommand`).
  - `save-and-quit` saves the buffer of the window it was called with and
    asks the editor to quit if the save started (`Ex.saveQuitCommand`). A
    host must be handed the save job too (`Files.jobs`).
- **`Ex.bindings`**: the ex names that ship. Each is bound to a command by
  its name, so a host must be handed that command too.
  - `w` runs `save-buffer` (`Editor/Files.lean`) and takes nothing: it
    saves the buffer of the window the line was asked from. `w` with an
    argument is refused by the ex line (`Ex.noArgument`): saving under
    another name is not built, and the save command would ignore the name.
  - `e` runs `open-file` and takes text: the rest of the line is the path,
    whole, spaces included. `e` with no argument runs `open-file` with
    none, which asks for a path, by that command's own rule. Vim's `e`
    with no argument reads the current file again, which is not built.
  - `q` runs `quit` and takes nothing. It quits the editor, not the
    window the line was asked from: no shipped command splits a window.
  - `wq` runs `save-and-quit` and takes nothing.

This module is apart from `Editor/Ex.lean` because it names the registry,
which is the config session's: `Editor.lean` imports the commands, so that
config can call them, and not this.

Pinned by `ModelTest.exChecks`, on the models.
-/

namespace Editor.Ex

/-- The ex line's commands, as a host registers them for the owner
`compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := name, action := .call exCommand }, { name := quitName, action := .call quitCommand },
    { name := saveQuitName, action := .call saveQuitCommand }]

/-- The ex names that ship, as a host registers them for the owner
`compiled`. -/
def bindings : Array Binding :=
  #[{ name := "w", command := Files.saveName },
    { name := "e", command := Files.openName, takes := .text },
    { name := "q", command := quitName }, { name := "wq", command := saveQuitName }]

end Editor.Ex
