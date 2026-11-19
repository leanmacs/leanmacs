import Editor.Files
import Editor.Package

/-!
# The `files` package: the file commands and their jobs

What a host registers so that it has the file commands (`Editor/Files.lean`):
the package `files` (`Files.package`, `Editor/Package.lean`), whose `setup`
registers the commands, the jobs they start, the file source and the file
category's style. A host registers it for the owner `files` when its loop
starts, before any config (`Editor/Config/Packages.lean`).

- **The commands**: `open-file`, `save-buffer`, `edit-file`, `reload-buffer`
  and `auto-reload-mode`, each a command that is given what it was called
  with (`commandWith`).
  - `open-file` opens the path that is its first argument, a string, in
    the window it was called with (`Files.openCommand`), and then the
    strings after it, up to the first argument that is not one, one after
    another, so that the last is shown last. With no path it
    asks for one with a prompt, whose answer it then opens: the prompt's
    continuation is `open-file` itself, which receives the answer as its
    first argument. A host must be handed the minibuffer's package too
    (`Editor/Minibuffer/Compiled.lean`) for that prompt to be answered.
  - `save-buffer` saves the buffer of the window it was called with
    (`Files.saveCommand`), forced when its first argument is `true`. Its
    other arguments are ignored: an input scheme hands a command a key is
    bound to a count and a register.
  - `edit-file` (`Files.editCommand`) is what the ex names `e` and `e!`
    run: a leading `true` is the force; a path opens it, as `open-file`
    does; with no path it reloads the window's buffer when that has a
    file, and otherwise asks for a path with the open prompt.
  - `reload-buffer` reloads the window's buffer from its file
    (`Files.reloadCommand`), forced when its first argument is `true`: a
    name for keys and config, as Emacs's `revert-buffer` is.
  - The ex names `e`, `e!`, `w` and `w!` are bound to these
    (`Editor/Ex/Compiled.lean`): `e` hands `edit-file` the rest of its
    line as the path, `e!` the same after `true`, and `w` and `w!` take
    nothing, so `save-buffer` is never handed a string it would ignore.
- **The jobs**: `load-file` and `reload-file`, under the editor's limit
  (`Files.limit`), `save-file`, and `check-files`, which the loop itself
  starts to check file buffers for a change on disk, one stat a file
  (`Editor/Loop.lean`, "Files that changed on disk"): a host that is not
  handed it checks nothing, and `files`, the file source's job
  (`Completion.Paths.gather`), which lists the directory a file prompt's
  text names. Each is started by its command with an order as its
  arguments, and registered as its work (`workJob`), since its finishing
  command is built from the order. They are the package's jobs, so a
  reload does not cancel one: a save that was started is ended.
- **The source**: the file source, `files`, of the category `file`
  (`Completion.Paths.shipped`, `Editor/Completion/Paths.lean`), which
  `open-file`'s prompt asks for.
- **The style default**: the path style for the category `file`
  (`useStyleFor`, which in a package is a default): config's `useStyleFor
  "file"` overrides it and its `useStyle` does not reach it.

This module is apart from `Editor/Files.lean` because it is what a host is
handed, not what config calls: `Editor.lean` imports the commands, so that
config calls them, and not this.

Pinned by `ModelTest.fileCommandChecks`, on the models, and by
`ConfigTest.fileChecks`, through the headless host on real files.
-/

namespace Editor.Files

/-- The package `files`: the file commands, the jobs they start, the file
source and the path style as the category `file`'s default. -/
def package : Package :=
  { name := "files"
    setup := do
      commandWith openName openCommand
      commandWith saveName saveCommand
      commandWith editName editCommand
      commandWith reloadName reloadCommand
      commandWith autoReloadName autoReloadCommand
      workJob loadJob (loadWork limit)
      workJob saveJob saveWork
      workJob reloadJob (reloadWork limit)
      workJob checkJob checkWork
      workJob followJob followWork
      sourceJob Completion.Paths.job Completion.Paths.gather
      for source in Completion.Paths.shipped do
        defineSource source
      useStyleFor Completion.Paths.category Completion.Styles.path.name }

end Editor.Files
