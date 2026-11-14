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
    the window it was called with (`Files.openCommand`). With no path it
    asks for one with a prompt, whose answer it then opens: the prompt's
    continuation is `open-file` itself, which receives the answer as its
    first argument. A host must be handed the minibuffer's commands too
    (`Editor/Minibuffer/Compiled.lean`) for that prompt to be answered.
  - `save-buffer` saves the buffer of the window it was called with
    (`Files.saveCommand`), forced when its first argument is `true`. Its
    other arguments are ignored: an input scheme hands a command a key is
    bound to a count and a register.
- **`Files.jobs`**: `load-file`, under the editor's limit (`Files.limit`),
  and `save-file`. Each is started by its command with an order as its
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
    { name := saveName, action := .call saveCommand }]

/-- The jobs the file commands start, as a host registers them for the
owner `compiled`: the load job, under the editor's limit, and the save
job. -/
def jobs : Array Config.JobRegistration :=
  #[{ name := loadJob, work := loadWork limit }, { name := saveJob, work := saveWork }]

end Editor.Files
