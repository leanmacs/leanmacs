import BuffersApi
import Editor.Package
import Ex
import FilesApi

/-!
# The `ex` package: the ex line's commands and the ex names that ship

What a host registers so that it has the ex command line (`Ex.lean`):
the package `ex` (`Ex.package`, `lean/Editor/Package.lean`), whose `setup`
registers the ex line's commands, the files', its own and the buffers' ex
names and its completion sources. A host registers it for the owner `ex` when its loop starts,
before any config (`lean/Editor/Config/Packages.lean`;
`lean/Editor/Config/Registry.lean`, "Ex bindings"), so they hold when config
fails to load, a reload does not replace them, and config's binding of a
shipped ex name runs in its place until a reload drops it. Both of the
executable's hosts are handed it, through the entry module of the Lake
package `ex` (`Ex/EditorPackage.lean`).

- **The commands**: each a command that is given what it was called with
  (`commandWith`).
  - `ex` opens the ex line, and runs the line it is answered
    (`Ex.exCommand`). A host must be handed the minibuffer's commands too
    (`packages/minibuffer/Minibuffer/Compiled.lean`) for that prompt to be answered, and
    the shell's package (`packages/shell/Shell/Compiled.lean`) for a `:!`
    line or a filter to run.
  - `quit` asks the editor to quit, and says a refusal in the echo area
    (`Ex.quitCommand`).
  - `save-and-quit` saves the buffer of the window it was called with and
    asks the editor to quit if the save started (`Ex.saveQuitCommand`). A
    host must be handed the save job too (`packages/files/Files/Compiled.lean`).
  - `reload-config` asks for the config to be reloaded
    (`Ex.reloadCommand`).
- **The ex names** of the files, of the ex line itself and of the buffers
  (`exCommand`). Each is bound to a command by its name, so a host must be
  handed that command's package too. The names of the files' and the
  buffers' commands are the interface libraries' (`FilesApi.saveName`,
  `.editName`, `.autoReloadName`; `BuffersApi.switchName`, `.listName`,
  `.closeName`): this module imports neither feature.
  - `w` runs `save-buffer` (`packages/files/Files.lean`) and takes nothing: it
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
    (`lean/Editor/Ex/Line.lean`), each a binding with fixed arguments
    (`exCommand`'s `arguments`, `Binding.arguments`).
  - `q` runs `quit` and takes nothing. It quits the editor, not the
    window the line was asked from: no shipped command splits a window.
  - `wq` runs `save-and-quit` and takes nothing.
  - `reload` runs `reload-config` and takes nothing.
  - `b` runs `switch-buffer` (`packages/buffers/Buffers.lean`) and takes text: the
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
  `previous-error`, in its package outside the core
  (`packages/compile/Compile/Compiled.lean`), and version control's twelve
  `vc-…` names (`packages/version-control/VersionControl/Compiled.lean`). The files'
  and the buffers' names are bound here because they were bound here
  while all three features were the core's (`docs/design/packages.md`);
  each names its command by an interface's constant, so the binding
  holds whatever implements `files-api` and `buffers-api`. The default
  set requires this package first (`packages/lakefile.toml`), so the ex
  names' completion source, which keeps the order the names were bound
  in, lists this package's, then the restore's and the package set's,
  then version control's, then the compile mode's.
- **The sources**: the `:!` history, then the ex names, so config can ask
  for them by name.

This module is apart from `Ex.lean` because it is what a host is
handed, not what config calls.

Pinned by `ExTest.exPackageChecks` and `ExTest.exChecks`, on the
models; by `ExTest.Linked.exChecks` and
`ExTest.Linked.exScriptChecks`, through the headless host; and on the
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
      Editor.exCommand "w" FilesApi.saveName
      Editor.exCommand "w!" FilesApi.saveName (arguments := [.bool true])
      Editor.exCommand "e" FilesApi.editName (takes := .text)
      Editor.exCommand "e!" FilesApi.editName (takes := .text) (arguments := [.bool true])
      Editor.exCommand "autoread" FilesApi.autoReloadName (arguments := [.bool true])
      Editor.exCommand "noautoread" FilesApi.autoReloadName (arguments := [.bool false])
      Editor.exCommand "q" quitName
      Editor.exCommand "wq" saveQuitName
      Editor.exCommand "reload" reloadName
      Editor.exCommand "b" BuffersApi.switchName (takes := .text)
      Editor.exCommand "ls" BuffersApi.listName
      Editor.exCommand "bd" BuffersApi.closeName (takes := .text)
      defineSource historySource
      defineSource namesSource }

end Editor.Ex
