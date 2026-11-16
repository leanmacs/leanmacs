import Editor.Config.Registry
import Editor.Files

/-!
# The file commands and their jobs, as compiled code registers them

What a host is handed so that it has the file commands (`Editor/Files.lean`):
their registrations, and those of the jobs they start. A host registers both
for the owner `compiled` when its loop starts, before any config
(`Editor/Config/Registry.lean`, "Compiled commands").

- **`Files.commands`**: `open-file` and `save-buffer`, each a command that
  is given what it was called with (`Action.call`).
  - `open-file` opens the path that is its first argument, a string, in
    the window it was called with (`Files.openCommand`), and then the
    strings after it, up to the first argument that is not one, one after
    another, so that the last is shown last. With no path it
    asks for one with a prompt, whose answer it then opens: the prompt's
    continuation is `open-file` itself, which receives the answer as its
    first argument. A host must be handed the minibuffer's commands too
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
- **`Files.jobs`**: `load-file` and `reload-file`, under the editor's limit
  (`Files.limit`), `save-file`, and `check-files`, which the loop itself
  starts to check file buffers for a change on disk, one stat a file
  (`Editor/Loop.lean`, "Files that changed on disk"): a host that is not
  handed it checks nothing. Each is started by its command with an order as its
  arguments. They are compiled jobs, so a reload does not cancel one: a
  save that was started is ended.

This module is apart from `Editor/Files.lean` because it names the registry,
which is the config session's: `Editor.lean` imports the commands, so that
config calls them, and not this.

Pinned by `ModelTest.fileCommandChecks`, on the models, and by
`ConfigTest.fileChecks`, through the headless host on real files.
-/

namespace Editor.Files

/-- The file commands, as a host registers them for the owner `compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := openName, action := .call openCommand },
    { name := saveName, action := .call saveCommand },
    { name := editName, action := .call editCommand },
    { name := reloadName, action := .call reloadCommand }]

/-- The jobs the file commands start, as a host registers them for the
owner `compiled`: the load job and the reload job, under the editor's limit,
and the save job. -/
def jobs : Array Config.JobRegistration :=
  #[{ name := loadJob, work := loadWork limit }, { name := saveJob, work := saveWork },
    { name := reloadJob, work := reloadWork limit }, { name := checkJob, work := checkWork }]

end Editor.Files
