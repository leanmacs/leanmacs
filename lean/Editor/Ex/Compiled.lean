import Editor.Buffers
import Editor.Ex
import Editor.Files
import Editor.Package

/-!
# The `ex` package: the ex line's commands and the core's ex names

What a host registers so that it has the ex command line (`Editor/Ex.lean`):
the package `ex` (`Ex.package`, `Editor/Package.lean`), whose `setup`
registers the ex line's commands, the files', its own and the buffers' ex
names and its completion sources. A host registers it for the owner `ex` when its loop starts,
before any config (`Editor/Config/Packages.lean`;
`Editor/Config/Registry.lean`, "Ex bindings"), so they hold when config
fails to load, a reload does not replace them, and config's binding of a
shipped ex name runs in its place until a reload drops it.

- **The commands**: each a command that is given what it was called with
  (`commandWith`).
  - `ex` opens the ex line, and runs the line it is answered
    (`Ex.exCommand`). A host must be handed the minibuffer's commands too
    (`Editor/Minibuffer/Compiled.lean`) for that prompt to be answered, and
    the shell's package (`Editor/Shell/Compiled.lean`) for a `:!`
    line or a filter to run.
  - `quit` asks the editor to quit, and says a refusal in the echo area
    (`Ex.quitCommand`).
  - `save-and-quit` saves the buffer of the window it was called with and
    asks the editor to quit if the save started (`Ex.saveQuitCommand`). A
    host must be handed the save job too (`Editor/Files/Compiled.lean`).
  - `reload-config` asks for the config to be reloaded
    (`Ex.reloadCommand`).
- **The ex names** of the files, of the ex line itself and of the buffers
  (`exCommand`). Each is bound to a command by its name, so a host must be
  handed that command's package too.
  - `w` runs `save-buffer` (`Editor/Files.lean`) and takes nothing: it
    saves the buffer of the window the line was asked from. `w` with an
    argument is refused by the ex line (`Ex.noArgument`): saving under
    another name is not built, and the save command would ignore the name.
  - `w!` runs `save-buffer` with `true`, the forced save, and takes
    nothing: it writes the buffer over whatever the file on disk now is,
    the "write mine over theirs" resolution of a file that changed under
    unsaved edits (`docs/design/agent-hosting.md`).
  - `e` runs `edit-file` and takes text: the rest of the line is the path,
    whole, spaces included, which it opens. `e` with no argument reads the
    window's file again, as Vim's does (`Files.reload`), refused while the
    buffer has unsaved changes; on a buffer with no file it asks for a
    path, as `open-file` does.
  - `e!` runs `edit-file` with `true` first, and takes text: with no
    argument the reload is forced, the file's text taken as one step that
    `u` undoes ("take theirs"); with a path it opens it as `e` does, since
    buffers persist and nothing is discarded. Only a leading `!` is
    parsed, as the shell's: `e!` and `w!` are names of their own
    (`Editor/Ex/Line.lean`), each a binding with fixed arguments
    (`exCommand`'s `arguments`, `Binding.arguments`).
  - `q` runs `quit` and takes nothing. It quits the editor, not the
    window the line was asked from: no shipped command splits a window.
  - `wq` runs `save-and-quit` and takes nothing.
  - `reload` runs `reload-config` and takes nothing.
  - `b` runs `switch-buffer` (`Editor/Buffers.lean`) and takes text: the
    rest of the line names the buffer, exactly or by fuzzy match. `b` with
    no argument runs it with none, which asks, by that command's own rule,
    as `e` does. Vim's `b` refuses a pattern that matches more than one
    buffer; this one takes the best match.
  - `ls` runs `list-buffers` and takes nothing.
  - `bd` runs `close-buffer` and takes text: the rest of the line is the
    name of the buffer to close, and with none it closes the buffer of the
    window the line was asked from.

  A feature with ex names of its own binds them in its own package, and
  this package names no such feature: the compile mode's `compile`,
  `compile-command`, `recompile`, `kill-compilation`, `next-error` and
  `previous-error` (`Editor/Compile/Compiled.lean`), and version control's
  twelve `vc-…` names (`Editor/VersionControl/Compiled.lean`). The files'
  and the buffers' names are bound here because both features are the
  core's, as this one is (`docs/design/packages.md`). The shipped set
  registers this package before those two (`PackageSet.lean`), so
  the names are bound in the order they were when this package bound them
  all, which is the order the ex names' completion source lists them in.
- **The sources**: the `:!` history, then the ex names, so config can ask
  for them by name.

This module is apart from `Editor/Ex.lean` because it is what a host is
handed, not what config calls: `Editor.lean` imports the commands, so that
config can call them, and not this.

Pinned by `ModelTest.exPackageChecks` and `ModelTest.exChecks`, on the
models; by `ConfigTest.exChecks` and
`ConfigTest.exScriptChecks`, through the headless host; and on the
executable by the fixture `tests/headless/ex` and the two process checks
of the `ffi-test` task.
-/

namespace Editor.Ex

/-- The package `ex`: the ex line's commands, the ex names that ship and the
ex line's completion sources, the `:!` history then the ex names. -/
def package : Package :=
  { name := "ex"
    setup := do
      commandWith name exCommand
      commandWith quitName quitCommand
      commandWith saveQuitName saveQuitCommand
      commandWith reloadName reloadCommand
      Editor.exCommand "w" Files.saveName
      Editor.exCommand "w!" Files.saveName (arguments := [.bool true])
      Editor.exCommand "e" Files.editName (takes := .text)
      Editor.exCommand "e!" Files.editName (takes := .text) (arguments := [.bool true])
      Editor.exCommand "autoread" Files.autoReloadName (arguments := [.bool true])
      Editor.exCommand "noautoread" Files.autoReloadName (arguments := [.bool false])
      Editor.exCommand "q" quitName
      Editor.exCommand "wq" saveQuitName
      Editor.exCommand "reload" reloadName
      Editor.exCommand "b" Buffers.switchName (takes := .text)
      Editor.exCommand "ls" Buffers.listName
      Editor.exCommand "bd" Buffers.closeName (takes := .text)
      defineSource historySource
      defineSource namesSource }

end Editor.Ex
