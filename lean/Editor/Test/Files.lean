import Editor.Command.Model
import Editor.Config.Packages
import Editor.Display.Model
import Editor.File
import Editor.File.Cases
import Editor.File.Model
import Editor.FileJobs
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job.Model
import Editor.Language
import Editor.Language.IndentUnit
import Editor.Loop
import Editor.Loop.Driver
import Editor.Mode
import Editor.ModeLine
import Editor.Scene
import Editor.State
import Editor.Test.Driver
import Editor.Test.Jobs
import Editor.Test.Minibuffer

/-!
# The test kit: Files

The files of the file checks, the invocation that opens one under the
core's name of the open command (`FileJobs.openFileCommand`), and what a
check reads of a buffer's file and of its status line. Shared by several
test modules under `ModelTest/Editor/`; it holds no checks of its own. It
names no module of the files feature: the drivers that run the real file
commands are that feature's (`Editor/Files/Kit.lean`), and the kit's own
opener (`Editor/Test/Opener.lean`) opens and saves a file without it.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import"). The core's own model tests are written on it.
-/

namespace Editor.Test

open Editor

/-- A file of three lines of which two end in CRLF and one in a line
feed. -/
def mostlyCrlf : ByteArray :=
  "a\r\nb\r\nc\n".toUTF8

/-- A file of three lines of which two end in a line feed and one in
CRLF. -/
def mostlyLf : ByteArray :=
  "a\nb\nc\r\n".toUTF8

/-- A file with no line break. -/
def unbroken : ByteArray :=
  "no break".toUTF8

/-- The files of the file command checks, in `fileRoot`: `note.txt`, with a
two-byte character, a four-byte one and a byte that is not UTF-8
(`FileCases.noteBytes`), three files that differ in their line endings,
and two files called `x.txt`, in the directories `a` and `b`. -/
def commandFiles : FileModel :=
  [("a", "first x\n"), ("b", "second x\n")].foldl
    (fun (model : FileModel) (directory, text) =>
      (model.withDirectory (fileRoot / directory)).withFile (fileRoot / directory / "x.txt")
        text.toUTF8)
    (fileModelOf
      #[("note.txt", FileCases.noteBytes), ("crlf.txt", mostlyCrlf), ("lf.txt", mostlyLf),
        ("plain.txt", unbroken)])

/-- The path of a file of the file command checks, by its name. -/
def inFiles (name : String) : System.FilePath :=
  fileRoot / name

/-- The keys of the file command checks that open a file, and the path each
opens: `missing.txt` is not there, and `relative.txt` is not an absolute
path, which the open command reads under the working directory. -/
def openKeys : List (String × System.FilePath) :=
  [("C-o n", inFiles "note.txt"), ("C-o c", inFiles "crlf.txt"), ("C-o l", inFiles "lf.txt"),
    ("C-o p", inFiles "plain.txt"), ("C-o m", inFiles "missing.txt"), ("C-o r", "relative.txt"),
    ("C-o a", fileRoot / "a" / "x.txt"), ("C-o b", fileRoot / "b" / "x.txt")]

/-- The invocation that opens `path`: the open command, with the path as
its argument. -/
def opens (path : System.FilePath) : Invocation :=
  { command := FileJobs.openFileCommand, arguments := [.str path.toString] }

/-- The buffer's fields of the status line of the view `view` in the last
scene `driver`'s display recorded: those in the faces of the buffer's name,
of the modified mark and of the changed mark (`ModeLine.buffer`,
`ModeLine.modified`, `ModeLine.changed`), which is what the file checks
read. The other segments are `modeLineChecks`'s. -/
def statusOf (driver : TestDriver) (view : ViewId := ⟨0⟩) : Option (Array StatusField) :=
  driver.model.display.scenes.back?.bind fun scene =>
    (scene.views.find? (·.id == view)).map fun view =>
      view.status.filter fun field =>
        field.face == ModeLine.bufferFace || field.face == ModeLine.modifiedFace ||
          field.face == ModeLine.changedFace

/-- The buffer's fields of the status line of a selected view of a buffer
called `name` that is not modified: the name alone, in its face. -/
def named (name : String) : Array StatusField :=
  #[ModeLine.field name ModeLine.bufferFace]

/-- The buffer's fields of the status line of a selected view of a buffer
called `name` that is modified: the name, then the modified mark. -/
def namedModified (name : String) : Array StatusField :=
  named name ++ #[ModeLine.field ModeLine.modifiedMark ModeLine.modifiedFace]

/-- The stamp the files `driver`'s jobs reach have for `path`. -/
def stampOf (driver : TestDriver) (path : System.FilePath) : Option File.Stamp :=
  (driver.jobs.files.file? path).map (·.stamp)

/-- The bytes the files `driver`'s jobs reach hold at `path`. -/
def bytesOf (driver : TestDriver) (path : System.FilePath) : Option ByteArray :=
  (driver.jobs.files.file? path).map (·.bytes)

/-- `driver` once another program has written `bytes` as the file at
`path`. -/
def rewritten (driver : TestDriver) (path : System.FilePath) (bytes : ByteArray) : TestDriver :=
  { driver with jobs := { driver.jobs with files := driver.jobs.files.withFile path bytes } }

/-- The file the buffer the view `view` of `driver` shows holds. -/
def heldFile (driver : TestDriver) (view : ViewId := ⟨0⟩) : Option Buffer.File :=
  (showing driver view).bind (·.buffer.file)

/-- A test language for the language open checks: `*.rs`, parsed with the
syntax tree model's one grammar, `json`, so a path's extension is seen to
choose it on the models. -/
def modelRs : Language :=
  { name := "model-rs", patterns := [.extension "rs"], syntaxTree := { grammar := "json" } }

/-- The language and the major mode of the buffer view 0 of `driver`
shows. -/
def languageAndMajor (driver : TestDriver) : Option (Option String × Option String) :=
  (showing driver).map fun shown => (shown.buffer.language, shown.buffer.major)

/-- The text another program writes over `note.txt` in the reload checks:
a new first line before what was there. -/
def reloadedText : String :=
  "a new first line\n" ++ FileCases.noteText

/-- `reloadedText` as the file's bytes. -/
def reloadedBytes : ByteArray :=
  "a new first line\n".toUTF8 ++ FileCases.noteBytes

/-- The id of the job of `driver` started under `name` and not yet
delivered, the latest if there are several. -/
def pendingOf (driver : TestDriver) (name : String) : Option Nat :=
  ((driver.pending.filter (·.name == name)).back?).map (·.id)

/-- Finishes the job of `driver` started under `name` and not yet delivered;
`driver` as it was when there is none. -/
def finishNamed (driver : TestDriver) (name : String) : TestDriver :=
  match pendingOf driver name with
  | some id => (driver.finish id).1
  | none => driver

end Editor.Test
