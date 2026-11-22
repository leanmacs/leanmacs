import Editor.Extension
import Editor.FileJobs
import Editor.Test.Hosted
import FilesApi
import FilesApiTest.Contract
import FilesApiTest.Fake
import ModelTest.Check

/-!
# Model tests: `FilesApi.lean`

`filesApiChecks`: the interface library `files-api`'s names, its fake held
to its contract, the contract biting on implementations that leave
something out, and a set's own `Files` value replacing the feature's. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- Whether every check of `files-api`'s contract over `package` holds. -/
def filesKeeps (package : Package) : Bool :=
  (FilesApiTest.contractChecks package).all (·.2)

/-- Whether the contract over `package` has a check that names `name` and
does not hold. -/
def filesFailsOn (package : Package) (name : String) : Bool :=
  (FilesApiTest.contractChecks package).any fun (sentence, held) =>
    !held && (sentence.splitOn name).length > 1

/-- The fake, but for the commands of `dropped`, which it does not register,
and, with `hooks` false, its opener's runners nothing: a files feature that
runs no hook. -/
def filesFakeLacking (dropped : List String := []) (hooks : Bool := true) : Package :=
  { name := FilesApiTest.fake.name
    setup := FilesApiTest.fakeSetup (dropped := dropped) (hooks := hooks) }

/-- The fake, but its `Files` value's save starts the follow-up at once and
saves with none: an implementation that starts the follow-up before the
file is written, and on a refused save too. -/
def filesFakeFollowingAtOnce : Package :=
  { name := FilesApiTest.fake.name
    setup := do
      FilesApiTest.fakeSetup
      Extension.add
          { FilesApiTest.files with
            save := fun id force after => do
              if let some job := after then
                discard <| startJob job.name job.arguments
              Opener.save id force none } }

/-- The fake, but its `Files` value's visit replaced by `visit`. -/
def filesFakeVisiting (visit : FilesApi.Files → FilesApi.Files) : Package :=
  { name := FilesApiTest.fake.name
    setup := do
      FilesApiTest.fakeSetup
      Extension.add (visit FilesApiTest.files) }

/-- An implementation whose visit puts the cursor at the start of the file,
wherever the point is: the fake's visit to row 0, column 0. -/
def filesFakeIgnoringPoint : Package :=
  filesFakeVisiting fun files =>
    { files with
      visit := fun view path _ focus record =>
        files.visit view path { row := 0, column := 0 } focus record }

/-- An implementation whose visit records a jump whatever its flag says. -/
def filesFakeAlwaysRecording : Package :=
  filesFakeVisiting fun files =>
    { files with visit := fun view path point focus _ => files.visit view path point focus true }

/-- The checks of `files-api` (`FilesApi.lean`). -/
def filesApiChecks : List Check :=
  [{  name :=
        "the names files-api declares: open-file, the core's, save-buffer, edit-file, reload-buffer and auto-reload-mode, and the jobs check-files and follow-file, the core's"
      run :=
        pure <|
          FilesApi.names ==
              #["open-file", "save-buffer", "edit-file", "reload-buffer", "auto-reload-mode"] &&
            FilesApi.openFileName == FileJobs.openFileCommand &&
            FilesApi.jobs == #[FileJobs.checkJob, FileJobs.followJob] &&
            FilesApi.implementationName == "files" },
    { name := "the fake keeps the contract: every check of it holds"
      run := pure (filesKeeps FilesApiTest.fake) },
    { name :=
        "a package that registers every command but edit-file fails the contract, on edit-file's check alone"
      run :=
        pure <|
          let lacking := filesFakeLacking [FilesApi.editName]
          !filesKeeps lacking && filesFailsOn lacking s!"`{FilesApi.editName}`" &&
            ((FilesApiTest.contractChecks lacking).filter (!·.2)).length == 1 },
    { name := "a package that registers no command fails the contract, on every command's check"
      run :=
        pure <|
          let none := filesFakeLacking FilesApi.names.toList
          FilesApi.names.all fun name => filesFailsOn none s!"`{name}`" },
    { name :=
        "an implementation whose open and save run no hook fails the contract: the checks of Opened and of Saved are false, and those of what it registers hold"
      run :=
        pure <|
          let silent := filesFakeLacking (hooks := false)
          ((FilesApiTest.contractChecks silent).filter (!·.2)).length == 2 &&
            filesFailsOn silent "FilesApi.Opened" &&
            filesFailsOn silent "FilesApi.Saved" },
    { name :=
        "an implementation whose save starts the follow-up at once fails the contract: the checks that the follow-up waits for the file to be written and that a refused save starts it not are false, and the rest hold"
      run :=
        pure <|
          let hasty := filesFakeFollowingAtOnce
          ((FilesApiTest.contractChecks hasty).filter (!·.2)).length == 2 &&
            filesFailsOn hasty "only once the file is written" &&
            filesFailsOn hasty "a refused save" },
    { name :=
        "the fake records as the buffer of a file it opens the language the registry's table chooses for its path (languageOf), as files does, and sets no major mode; a path no entry matches has none"
      run :=
        pure <|
          let rs := inFiles "main.rs"
          let languages : Package := { name := "model-languages", setup := defineLanguage modelRs }
          let opened (path : System.FilePath) : Option (Option String × Option String) :=
            (hostedDriver #[FilesApiTest.fake, languages] (files :=
                  commandFiles.withFile rs "fn main() {}\n".toUTF8)).bind
              fun driver =>
              languageAndMajor
                (hostedRan driver
                  { command := FilesApi.openFileName, arguments := [.str path.toString] })
          opened rs == some (some modelRs.name, none) &&
            opened (inFiles "note.txt") == some (none, none) },
    { name :=
        "an implementation whose visit ignores the point fails the contract: the checks that a visit of a closed file and of an open one put the cursor at the point, and the check of record, which reads the cursor too, are false, and the rest hold"
      run :=
        pure <|
          let blind := filesFakeIgnoringPoint
          ((FilesApiTest.contractChecks blind).filter (!·.2)).length == 3 &&
            filesFailsOn blind "of a closed file shows it" &&
            filesFailsOn blind "of a file a buffer holds" &&
            filesFailsOn blind "records one jump" },
    { name :=
        "an implementation whose visit records a jump whatever its flag says fails the contract on the check of record alone"
      run :=
        pure <|
          let eager := filesFakeAlwaysRecording
          ((FilesApiTest.contractChecks eager).filter (!·.2)).length == 1 &&
            filesFailsOn eager "records one jump" },
    { name :=
        "a set's own Files value of the name files, registered after the feature's, as config's is, is the one files? answers: its visit runs in place of the feature's"
      run :=
        pure <|
          let own : Package :=
            { name := "own-files"
              setup := do
                Extension.add
                    ({  name := FilesApi.implementationName
                        adopt := fun _ _ _ => pure none
                        visit := fun _ _ _ _ _ => message "config's visit"
                        save := fun _ _ _ => pure () } : FilesApi.Files)
                command "visit-through-files" do
                    let some files ← FilesApi.files? | message "none"
                    files.visit ⟨0⟩ "/x" { row := 0, column := 0 } false true }
          match hostedDriver #[FilesApiTest.fake, own] with
          | some driver =>
            (hostedRan driver { command := "visit-through-files" }).loop.state.echo ==
              "config's visit"
          | none => false }]

end ModelTest
