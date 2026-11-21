import BuffersApiTest.Fake
import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Completion
import Editor.Completion.Later
import Editor.Completion.Paths
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Ex
import Editor.Ex.Compiled
import Editor.Ex.Line
import Editor.File.Model
import Editor.Files
import Editor.Files.Compiled
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Loop
import Editor.Loop.Driver
import Editor.Test.Driver
import Editor.Test.Files
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Minibuffer
import Editor.Test.Models
import Editor.Test.Shell
import Editor.Test.Workspace

/-!
# The files feature's test kit: the drivers of the real file commands

The keys, jobs and drivers that run the files feature's own commands and
jobs (`Editor/Files.lean`, `Editor/Files/Compiled.lean`) on the loop's
driver over the models: what the files feature's tests, and the tests of
ex, evil, the menu and the compile mode, which still reach the real file
commands, are written on. It is a module of the files feature, not of the
core's kit (`Editor/Test/`), so that no core test and no module of the core's
kit imports the files feature: the core's tests open and save files with the
kit's own opener (`Editor/Test/Opener.lean`). Its namespace is the kit's,
`Editor.Test`, so a caller changes one import.

A package's test module may import it, as a test double, and its library
may not (`tools/package-imports-check.sh`, `is_double`). It moves into the
files package's test library when files moves out of the core.
-/

namespace Editor.Test

open Editor

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
        Files.visit ⟨0⟩ (inFiles "note.txt") { row := 0, column := 2 } true
        return none),
      ("visit-missing", fun _ => do
        Files.visit ⟨0⟩ (inFiles "missing.txt") { row := 1, column := 0 } true
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
(`Files.package.registered.commands`, `Files.package.registered.jobs`), and the kit's minibuffer's (`Minibuffer.package.registered.commands`, `Editor/Test/Minibuffer.lean`), each under the
name it is registered under, over the files of the file command checks:
`C-o n` is bound to the open command with the path of `note.txt`, `C-o o`
to the open command with no argument, `C-o w` to the save command, and
`C-o y` to the minibuffer's accept command, in every view. -/
def compiledDriver : Option TestDriver :=
  let keys : Loop.Keys TestScheme.scheme :=
    dispatchKeys
      [("C-o n", opens (inFiles "note.txt")), ("C-o o", invoke Files.openName),
        ("C-o w", invoke Files.saveName), ("C-o y", invoke Minibuffer.acceptName)]
      ((Files.package.registered.commands ++
            Minibuffer.package.registered.commands).toList.filterMap
        fun registration =>
        match registration.action with
        | .call run =>
          some
            (registration.name, fun call => do
              run call
              return none)
        | _ => none)
  (Loop.Driver.over keys
        (fun name => (Files.package.registered.jobs.find? (·.name == name)).map (·.work))
        (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { files := commandFiles } }

/-- A driver of the file command checks with the file `note.txt` open in
view 0, and the step that opened it: the open command, and its job
finished. The load is job 1. -/
def noteOpen (files : FileModel := commandFiles) : Option TestDriver :=
  (filesDriver (files := files)).map fun driver => ((fedTo driver (presses "C-o n")).1.finish 1).1

/-- The commands compiled code registers for files and the ex line, and the
kit's minibuffer's (`Editor/Test/Minibuffer.lean`), each under its name, and `undo` and `redo`, which move one step of the
history of the buffer of the window they are called with. -/
def reloadCommands : List (String × Dispatched) :=
  let compiled : List (String × Dispatched) :=
    (Ex.package.registered.commands ++ Minibuffer.package.registered.commands ++
          Files.package.registered.commands ++
          BuffersApiTest.fake.registered.commands).toList.filterMap
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
compiled code registers for files (`Files.package.registered.jobs`), the `ex` package's ex names, and
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
        { ex := fun name => Ex.package.registered.ex.findRev? (·.name == name)
          exNames := exNamesOf Ex.package.registered.ex } }
  (Loop.Driver.over keys
        (fun name => (Files.package.registered.jobs.find? (·.name == name)).map (·.work))
        (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { files := commandFiles } }

/-- `reloadDriver` with `note.txt` open in view 0, its load finished, and
then `note.txt` rewritten by another program with `reloadedBytes`. -/
def noteRewritten : Option TestDriver :=
  reloadDriver.map fun driver =>
    rewritten (finishNamed (fedTo driver (presses "C-o n")).1 Files.loadJob) (inFiles "note.txt")
      reloadedBytes

/-- The open command of the files feature, under its name, as a driver
dispatches it. -/
def fileCommands : List (String × Dispatched) :=
  [(Files.openName, fun call => do
      Files.openCommand call
      return none)]

/-- The jobs of the workspace driver checks with the files feature's in
place of the kit's opener's: the find job, the mode marker job and
`fileJobs`. -/
def fileWorkspaceJobs (name : String) : Option (List Argument → Work) :=
  workspaceJobsWith (fileJobs Files.limit) name

/-- The commands of the workspace driver checks with the files feature's
open command in place of the kit's opener's. -/
def fileWorkspaceCommands : List (String × Dispatched) :=
  workspaceCommandsWith fileCommands

/-- The jobs of the shell checks with the files feature's in place of the
kit's opener's (`fileWorkspaceJobs`). -/
def fileShellJobs (name : String) : Option (List Argument → Work) :=
  shellJobsWith fileWorkspaceJobs name

/-- The commands of the shell checks with the files feature's open command
in place of the kit's opener's (`fileWorkspaceCommands`). -/
def fileShellCommands : List (String × Dispatched) :=
  shellCommandsWith fileWorkspaceCommands

/-- The files feature's package, as a host registers it: what a test that
runs the real file commands over a host or a rig hands it, so that a
package's test, which may not import the module that defines the package
(`Editor/Files/Compiled.lean`), reaches it through this test double. -/
def filesPackage : Package :=
  Files.package

end Editor.Test
