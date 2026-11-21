import BuffersApi
import Editor.Ex
import Editor.Package
import FilesApi

/-!
# The kit's ex line: ex's command over the interfaces' names

A stand-in for the `ex` package (`Editor/Ex/Compiled.lean`) that a package's
tests may register, as that module defines a package still in the core and
no package's tests may import it (`tools/package-imports-check.sh`). It
registers ex's own command, `ex` (`Ex.exCommand`, the core's), and the ex
names that reach files and the buffers, each bound to the interface's name
as ex's package binds it: `w` and `w!` to `save-buffer`, `e` and `e!` to
`edit-file`, `autoread` and `noautoread` to `auto-reload-mode`
(`files-api`), and `b`, `ls` and `bd` to `switch-buffer`, `list-buffers` and
`close-buffer` (`buffers-api`). So a test of files or the buffers types an
ex line, `:e` or `:ls`, and its own commands run, with no module of ex but
the core's.

Which ex names ex's package binds, and to what, is ex's, pinned by
`ModelTest.exChecks` and the fixture `tests/headless/ex`; this module
copies the ones files' and the buffers' tests type, and nothing else (no
`q`, `wq` or `reload`).
-/

namespace Editor.Test

open Editor

/-- The kit's ex line (the module docs): a package named `ex` that
registers ex's command and the ex names of files and the buffers. -/
def exLinePackage : Package :=
  { name := "ex"
    setup := do
      commandWith Ex.name Ex.exCommand
      Editor.exCommand "w" FilesApi.saveName
      Editor.exCommand "w!" FilesApi.saveName (arguments := [.bool true])
      Editor.exCommand "e" FilesApi.editName (takes := .text)
      Editor.exCommand "e!" FilesApi.editName (takes := .text) (arguments := [.bool true])
      Editor.exCommand "autoread" FilesApi.autoReloadName (arguments := [.bool true])
      Editor.exCommand "noautoread" FilesApi.autoReloadName (arguments := [.bool false])
      Editor.exCommand "b" BuffersApi.switchName (takes := .text)
      Editor.exCommand "ls" BuffersApi.listName
      Editor.exCommand "bd" BuffersApi.closeName (takes := .text) }

end Editor.Test
