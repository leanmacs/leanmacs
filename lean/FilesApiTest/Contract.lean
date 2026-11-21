import Editor.Config.Packages
import Editor.Extension
import Editor.Test.Files
import Editor.Test.Hosted
import FilesApi

/-!
# The contract check of `files-api`

What every implementation of the interface library `files-api`
(`FilesApi.lean`) runs over its package, in two parts.

- **What it registers**, collected with the pure collector
  (`Package.registered`): a command under each command name the interface
  declares, a job under each job name, and a `FilesApi.Files` value under
  the implementation's name, `files`.
- **What it does**, on the loop's driver over the models with the package
  installed as a host installs it beside a probe of the interface's own
  (`Editor.Test.hostedDriver`, `probe`): opening a file through `open-file`
  runs every `FilesApi.Opened` value once, with the buffer and the path,
  once the buffer holds the file; a save that writes runs every
  `FilesApi.Saved` value once; and `adopt` with no view answers the buffer
  that holds the path and shows it nowhere.

It is a list of sentences, each with whether it holds, as the fixture
interface package `greeting-api`'s (`tests/packages/greeting-api`).
-/

namespace FilesApiTest

open Editor
open Editor.Test

/-- The probe's hook values at `Opened`, and the one at `Saved`: each makes
a text saying what it was handed, and, for `Opened`, whether the buffer then
held the path. -/
def probe : Package :=
  { name := "files-api-probe"
    setup := do
      for name in ["probe-a", "probe-b"] do
        Extension.add
            ({  name
                opened := fun id path => do
                  let held := (← editorState).findFile path == some id
                  discard <| createText s!"opened {name} {id.index} {path} {held}" } :
              FilesApi.Opened)
      Extension.add
          ({ name := "probe", saved := fun id => discard <| createText s!"saved {id.index}" } :
            FilesApi.Saved)
      command "files-api-adopt" do
          let some files ← FilesApi.files? | message "no files implementation"
          let loaded : File.Loaded :=
            { snapshot := ⟨0⟩, stamp := { seconds := 0, nanoseconds := 0, size := 0 }
              endings := { lf := 0, crlf := 0 } }
          let before := (← editorState).window? ⟨0⟩ |>.map (·.buffer)
          let some id ← files.adopt (inFiles "note.txt") loaded none | message "adopted none"
          let after := (← editorState).window? ⟨0⟩ |>.map (·.buffer)
          message s!"adopted {id.index}, view 0 kept {before == after}" }

/-- The texts `driver`'s model holds that start with `lead`. -/
def textsStarting (driver : TestDriver) (lead : String) : Array String :=
  driver.model.texts.contents.filter (·.startsWith lead)

/-- The checks of the contract over `package`, each with what must hold as a
sentence. -/
def contractChecks (package : Package) : List (String × Bool) :=
  let registered := Package.registered package
  let commands := registered.commands.map (·.name)
  let jobs := registered.jobs.map (·.name)
  let files : Array FilesApi.Files :=
    registered.extensions.filterMap fun (key, value) =>
      if key == TypeName.typeName FilesApi.Files then value.get? FilesApi.Files else none
  let note := inFiles "note.txt"
  let opened :=
    (hostedDriver #[package, probe] (files := commandFiles)).map fun driver =>
      hostedRan driver { command := FilesApi.openFileName, arguments := [.str note.toString] }
  let id := opened.bind fun driver => driver.loop.state.findFile note
  let saved := opened.map fun driver => hostedRan driver { command := FilesApi.saveName }
  let adopted := opened.map fun driver => hostedRan driver { command := "files-api-adopt" }
  (FilesApi.names.toList.map fun name =>
      (s!"`{package.name}` registers a command under `{name}`, a name `files-api` declares",
        commands.contains name)) ++
    (FilesApi.jobs.toList.map fun name =>
      (s!"`{package.name}` registers a job under `{name}`, a job name `files-api` declares",
        jobs.contains name)) ++
    [(s!"`{package.name}` registers a `FilesApi.Files` value named `{FilesApi.implementationName}`",
        files.any (·.name == FilesApi.implementationName)),
      (s!"opening a file through `{FilesApi.openFileName}` of `{package.name}` runs every `FilesApi.Opened` value once, with the buffer and the path, once the buffer holds the file",
        match opened, id with
        | some driver, some id =>
          textsStarting driver "opened " ==
            #[s!"opened probe-a {id.index} {note} true", s!"opened probe-b {id.index} {note} true"]
        | _, _ => false),
      (s!"a save through `{FilesApi.saveName}` of `{package.name}` that writes the file runs every `FilesApi.Saved` value once, with the buffer",
        match saved, id with
        | some driver, some id => textsStarting driver "saved " == #[s!"saved {id.index}"]
        | _, _ => false),
      (s!"`adopt` of `{package.name}`'s `FilesApi.Files` value with no view answers the buffer that holds the path and shows it nowhere",
        match adopted, id with
        | some driver, some id => driver.loop.state.echo == s!"adopted {id.index}, view 0 kept true"
        | _, _ => false)]

end FilesApiTest
