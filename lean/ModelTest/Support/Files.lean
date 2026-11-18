import Editor.Api
import Editor.Buffers.Compiled
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Compile.Contribution
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Later
import Editor.Completion.Paths
import Editor.Completion.Styles
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.Display.Model
import Editor.DisplayRules
import Editor.Ex
import Editor.Ex.Compiled
import Editor.Ex.Line
import Editor.File
import Editor.File.Cases
import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Files
import Editor.Files.Compiled
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Language
import Editor.Language.IndentUnit
import Editor.Layout
import Editor.Loop
import Editor.Loop.Driver
import Editor.Minibuffer
import Editor.Minibuffer.Compiled
import Editor.Mode
import Editor.ModeLine
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Text
import Editor.Value
import Editor.Workspace
import ModelTest.Support.Driver
import ModelTest.Support.Jobs
import ModelTest.Support.Keys
import ModelTest.Support.Loop
import ModelTest.Support.Models

/-!
# Model tests: support: Files

The file commands' keys, files and driver, and what a check reads of a buffer's
file and its reload. Shared by several test modules under `ModelTest/Editor/`;
it holds no checks of its own.
-/

namespace ModelTest

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
  { command := Files.openName, arguments := [.str path.toString] }

/-- What a step of the file command checks is handed: the keys of
`openKeys`, each bound to the open command with its path, `C-o o` bound to
the open command with no argument, `C-o V` to the open command with the
arguments the Vim scheme gives a command a key is bound to, a count and a
register, and the open command under its name. `C-o 2` is bound to the open
command with two paths, `note.txt` and then `crlf.txt`, and `C-o 3` with
`missing.txt` and then `lf.txt`.

`C-o w` is bound to the save command, under its name, `C-o f` to the save
command with `true` as its argument, and `C-o v` to the save command with
the arguments the Vim scheme gives a command a key is bound to, a count
and a register.

Eight more commands, written here: `scratch` (`C-o 0`) shows the scratch
buffer in the window it is called with, `split` (`C-o s`) splits that
window and focuses the new one, `close` (`C-o k`) closes it, `shut`
(`C-o K`) closes the view 1, the first a split makes, whichever window it
is called with, `undo` (`C-o u`) undoes one step of its buffer's history,
`drop` (`C-o d`) removes the buffer 1, the first a file is opened into, and
`save-absent` (`C-o x`) saves a buffer there is none of. Two more visit a
file in the view 0, focusing it (`Files.visit`): `visit-note` (`C-o g`)
`note.txt` at row 0, character column 2, and `visit-missing` (`C-o G`)
`missing.txt`. And `save-then` (`C-o t`) saves its buffer with the follow-up
job `follow`, keyed `k`, with the argument `x`. -/
def fileKeys : Loop.Keys TestScheme.scheme :=
  dispatchKeys
    (openKeys.map (fun (text, path) => (text, opens path)) ++
      [("C-o o", invoke Files.openName),
        ("C-o V", { command := Files.openName, arguments := [.nat 0, .str ""] }),
        ("C-o 0", invoke "scratch"), ("C-o s", invoke "split"), ("C-o k", invoke "close"),
        ("C-o K", invoke "shut"), ("C-o w", invoke Files.saveName),
        ("C-o f", { command := Files.saveName, arguments := [.bool true] }),
        ("C-o v", { command := Files.saveName, arguments := [.nat 0, .str ""] }),
        ("C-o u", invoke "undo"), ("C-o d", invoke "drop"), ("C-o x", invoke "save-absent"),
        ("C-o g", invoke "visit-note"), ("C-o G", invoke "visit-missing"),
        ("C-o t", invoke "save-then"),
        ("C-o 2",
          { command := Files.openName
            arguments :=
              [.str (inFiles "note.txt").toString, .str (inFiles "crlf.txt").toString] }),
        ("C-o 3",
          { command := Files.openName
            arguments :=
              [.str (inFiles "missing.txt").toString, .str (inFiles "lf.txt").toString] })])
    [(Files.openName, fun call => do
        Files.openCommand call
        return none),
      (Files.saveName, fun call => do
        Files.saveCommand call
        return none),
      ("undo", fun call => do
        discard <| call.target.window.buffer.undo
        return none),
      ("drop", fun _ => do
        discard <| (⟨1⟩ : BufferId).remove
        return none),
      ("save-absent", fun _ => do
        Files.save ⟨9⟩
        return none),
      ("save-then", fun call => do
        Files.save call.target.window.buffer (after :=
            some { name := "follow", arguments := [.str "x"], key := some "k" })
        return none),
      ("scratch", fun call => do
        discard <| call.target.window.id.show ⟨0⟩
        return none),
      ("split", fun call => do
        if let .ok made← call.target.window.id.split then
          discard <| made.focus
        return none),
      ("close", fun call => do
        discard <| call.target.window.id.close
        return none),
      ("shut", fun _ => do
        discard <| (⟨1⟩ : ViewId).close
        return none),
      ("visit-note", fun _ => do
        Files.visit ⟨0⟩ (inFiles "note.txt") ⟨0, 2⟩ true
        return none),
      ("visit-missing", fun _ => do
        Files.visit ⟨0⟩ (inFiles "missing.txt") ⟨1, 0⟩ true
        return none)]

/-- The jobs of the file command checks, by name: the load job, whose loads
are refused over `limit` bytes, and the save job. -/
def fileJobs (limit : Nat := Files.limit) (name : String) : Option (List Argument → Work) :=
  if name == Files.loadJob then some (Files.loadWork limit)
  else
    if name == Files.saveJob then some Files.saveWork
    else
      if name == Completion.Paths.job then some (Completion.answering Completion.Paths.gather)
      else none

/-- A driver over the initial state with the keys of the file command
checks, the jobs `registered`, and `files` as the files its jobs reach;
`none` if making the state was refused. -/
def filesDriver (registered : String → Option (List Argument → Work) := fileJobs)
    (files : FileModel := commandFiles) : Option TestDriver :=
  (Loop.Driver.over fileKeys registered (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { files } }

/-- A driver whose commands and jobs are the ones compiled code registers
(`Files.commands`, `Files.jobs`, and `Minibuffer.commands`), each under the
name it is registered under, over the files of the file command checks:
`C-o n` is bound to the open command with the path of `note.txt`, `C-o o`
to the open command with no argument, `C-o w` to the save command, and
`C-o y` to the minibuffer's accept command, in every view. -/
def compiledDriver : Option TestDriver :=
  let keys : Loop.Keys TestScheme.scheme :=
    dispatchKeys
      [("C-o n", opens (inFiles "note.txt")), ("C-o o", invoke Files.openName),
        ("C-o w", invoke Files.saveName), ("C-o y", invoke Minibuffer.acceptName)]
      ((Files.commands ++ Minibuffer.commands).toList.filterMap fun registration =>
        match registration.action with
        | .call run =>
          some
            (registration.name, fun call => do
              run call
              return none)
        | _ => none)
  (Loop.Driver.over keys (fun name => (Files.jobs.find? (·.name == name)).map (·.work))
        (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { files := commandFiles } }

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

/-- A driver of the file command checks with the file `note.txt` open in
view 0, and the step that opened it: the open command, and its job
finished. The load is job 1. -/
def noteOpen (files : FileModel := commandFiles) : Option TestDriver :=
  (filesDriver (files := files)).map fun driver => ((fedTo driver (presses "C-o n")).1.finish 1).1

/-- A test language for the language open checks: `*.rs`, parsed with the
syntax tree model's one grammar, `json`, so a path's extension is seen to
choose it on the models. -/
def modelRs : Language :=
  { name := "model-rs", patterns := [.extension "rs"], syntaxTree := { grammar := "json" } }

/-- The language and the major mode of the buffer view 0 of `driver`
shows. -/
def languageAndMajor (driver : TestDriver) : Option (Option String × Option String) :=
  (showing driver).map fun shown => (shown.buffer.language, shown.buffer.major)

/-- The commands compiled code registers for files, the minibuffer and the ex
line, each under its name, and `undo` and `redo`, which move one step of the
history of the buffer of the window they are called with. -/
def reloadCommands : List (String × Dispatched) :=
  let compiled : List (String × Dispatched) :=
    (Ex.commands ++ Minibuffer.commands ++ Files.commands ++ Buffers.commands).toList.filterMap
      fun (registration : Config.Registration) =>
      match registration.action with
      | .call run =>
        let dispatched : Dispatched := fun call => do
          run call
          return none
        some (registration.name, dispatched)
      | _ => none
  compiled ++
    [("undo", fun call => do
        discard <| call.target.window.buffer.undo
        return none),
      ("redo", fun call => do
        discard <| call.target.window.buffer.redo
        return none),
      ("type-x", fun call => do
        Loop.insert call.target "x"
        return none)]

/-- A driver of the reload checks: the commands of `reloadCommands`, every job
compiled code registers for files (`Files.jobs`), the ex names that ship, and
the files of the file command checks. `C-o n` opens `note.txt`, `C-o r` runs
the reload command, `C-o R` the forced reload, `C-o u` undoes and `C-o U`
redoes; `C-e e` opens the ex line and `C-e y` accepts it. -/
def reloadDriver : Option TestDriver :=
  let keys : Loop.Keys TestScheme.scheme :=
    {
      dispatchKeys
        [("C-o n", opens (inFiles "note.txt")), ("C-o l", opens (inFiles "lf.txt")),
          ("C-o x", invoke "type-x"), ("C-o r", invoke Files.reloadName),
          ("C-o R", { command := Files.reloadName, arguments := [.bool true] }),
          ("C-o u", invoke "undo"), ("C-o U", invoke "redo"), ("C-e e", invoke Ex.name),
          ("C-e y", invoke Minibuffer.acceptName)]
        reloadCommands with
      registered :=
        { ex := fun name => Ex.bindings.findRev? (·.name == name)
          exNames := exNamesOf Ex.bindings } }
  (Loop.Driver.over keys (fun name => (Files.jobs.find? (·.name == name)).map (·.work))
        (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { files := commandFiles } }

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

/-- `reloadDriver` with `note.txt` open in view 0, its load finished, and
then `note.txt` rewritten by another program with `reloadedBytes`. -/
def noteRewritten : Option TestDriver :=
  reloadDriver.map fun driver =>
    rewritten (finishNamed (fedTo driver (presses "C-o n")).1 Files.loadJob) (inFiles "note.txt")
      reloadedBytes

end ModelTest
