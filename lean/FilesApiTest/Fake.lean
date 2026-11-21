import Editor.Config.Packages
import Editor.Extension
import Editor.Test.Opener
import FilesApi

/-!
# The fake of `files-api`

The core's test kit's opener (`Editor.Test.Opener`, the core's
`lean/Editor/Test/Opener.lean`) as an implementation of the interface: a
package named `files` that opens and saves files over the core's API alone,
with the interface's hooks as the opener's runners (`FilesApi.runOpened`
once a buffer takes in a file, `FilesApi.runSaved` once a save writes one),
a `FilesApi.Files` value of the opener's `adopt`, `visit` and `save`, and
stand-ins under the interface's other names: `edit-file` opens as
`open-file` does, `reload-buffer` and `auto-reload-mode` say they are the
fake's, and the jobs `check-files` and `follow-file` finish with nothing.
So there is one hand-written opener, and this library's tests hold it to the
contract. A consumer's tests register it in place of the files feature.
-/

namespace FilesApiTest

open Editor
open Editor.Test

/-- The fake's `FilesApi.Files` value: the opener's, with `FilesApi.runOpened`
as its runner. -/
def files : FilesApi.Files :=
  { name := FilesApi.implementationName
    adopt := fun path loaded view => Opener.adopt FilesApi.runOpened path loaded view
    visit := fun view path point focus record =>
      Opener.visit view path
        { row := point.row, column := point.column, firstNonBlank := point.firstNonBlank, focus
          record }
    save := fun id force after => Opener.save id force after }

/-- The fake's `setup`: the opener with the interface's hooks as its
runners, unless `hooks` is false; its `Files` value; and stand-ins under the
interface's other names, but for the commands of `dropped`. -/
def fakeSetup (dropped : List String := []) (hooks : Bool := true) : SetupM Unit := do
  let opened : BufferId → System.FilePath → EditorM Unit :=
    if hooks then FilesApi.runOpened else fun _ _ => pure ()
  let saved : BufferId → EditorM Unit := if hooks then FilesApi.runSaved else fun _ => pure ()
  let commands : List (String × (Call → EditorM Unit)) :=
    [(FilesApi.openFileName, Opener.openCommand), (FilesApi.saveName, Opener.saveCommand),
      (FilesApi.editName, Opener.openCommand),
      (FilesApi.reloadName, fun _ => message "the fake reloads nothing"),
      (FilesApi.autoReloadName, fun _ => message "the fake follows nothing")]
  for (name, run) in commands do
    unless dropped.contains name do
      commandWith name run
  workJob Opener.loadJob (Opener.loadWork opened)
  workJob Opener.saveJob (Opener.saveWork saved)
  for job in FilesApi.jobs do
    workJob job fun _ _ => pure (pure ())
  Extension.add files

/-- The fake: a package named `files`, over the core's test kit's opener. -/
def fake : Package :=
  { name := FilesApi.implementationName, setup := fakeSetup }

/-- The fake's commands, under their names, as a driver of handed commands
dispatches them. -/
def commands : List (String × Dispatched) :=
  fake.registered.commands.toList.filterMap fun registration =>
    match registration.action with
    | .call run =>
      some
        (registration.name, fun call => do
          run call
          return none)
    | _ => none

/-- The fake's open and save commands alone, under their names: what a
driver of another feature's checks hands beside commands of its own, which
the fake's stand-ins would otherwise come before. -/
def openSaveCommands : List (String × Dispatched) :=
  commands.filter fun (name, _) => name == FilesApi.openFileName || name == FilesApi.saveName

/-- The fake's jobs, by name, as a driver of handed jobs starts them. -/
def jobs (name : String) : Option (List Argument → Work) :=
  (fake.registered.jobs.find? (·.name == name)).map (·.work)

end FilesApiTest
