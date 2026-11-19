import Editor.Api
import Editor.Command.Call
import Editor.Completion.Filtering
import Editor.Completion.Later
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Loop
import Editor.Loop.Driver
import Editor.Minibuffer
import Editor.Process
import Editor.Process.Model
import Editor.State
import Editor.Workspace
import Editor.Workspace.Attach
import Editor.Workspace.FindFile
import Editor.Workspace.Lister
import Editor.Workspace.Model
import ModelTest.Support.Candidates
import ModelTest.Support.Driver
import ModelTest.Support.Files
import ModelTest.Support.Keys
import ModelTest.Support.Loop
import ModelTest.Support.Prompts
import ModelTest.Support.Workspace

/-!
# Model tests: support: FindFile

The driver of the workspace finder checks: its listers' scripts and
records, its jobs, commands and keys, and how a check drains it and reads
the prompt it opened. Shared by the checks of `find-file-in-workspace`
(`ModelTest/Editor/Workspace/FindFile.lean`) and of `find-file-in-project`
(`ModelTest/Editor/Workspace/FindInProject.lean`), which builds on its
driver; it holds no checks of its own.
-/

namespace ModelTest

open Editor

namespace FindFileTest

/-- `texts` as NUL-ended records. -/
def nul (texts : List String) : ByteArray :=
  texts.foldl (fun bytes text => (bytes ++ text.toUTF8).push 0) .empty

/-- A run that exits 0, writing `texts` as NUL-ended records. -/
def ran (texts : List String) : Except ProcessError Process.Ran :=
  .ok { exit := .code 0, stdout := nul texts, stderr := .empty }

/-- Git's lister, as the driver's git is `git`. -/
def git : Workspace.Lister :=
  .git "git"

/-- The lister config declares for the root `/w`. -/
def rootDeclared : Workspace.DeclaredLister :=
  { scope := .root "/w", program := "fd", arguments := #["-0", "--type", "f"], nul := true }

/-- The lister config declares for the project of `/r` and `/w`. -/
def projectDeclared : Workspace.DeclaredLister :=
  { scope := .project (.remote "github.com/o/r"), program := "rg",
    arguments := #["--files", "--null"]
    nul := true }

/-- The scripts of `lister` at `root`: it lists `records`, and the filter
answers each text of `filters` with its records. -/
def listing (lister : Workspace.Lister) (root : System.FilePath) (records : List String)
    (filters : List (String × List String)) : Array Process.Script :=
  #[{ command := lister.command root, reply := ran records }] ++
    (filters.map fun (text, matched) =>
        ({  command := (Workspace.FindFile.filtering lister root).filterFor text
            reply := ran matched } : Process.Script)).toArray

/-- What git lists in `/w`. -/
def wRecords : List String :=
  ["src/w.lean", "src/b.lean", "only-w"]

/-- What git lists in `/r`. -/
def rRecords : List String :=
  ["src/a.lean", "only-r"]

/-- The process scripts of the checks: each root's lister and its filters. -/
def scripts : Array Process.Script :=
  listing git "/w" wRecords [("", wRecords), ("b", ["src/b.lean"]), ("bc", [])] ++
    listing git "/r" rRecords [("", rRecords)] ++
    listing .fallback "/x" ["./a.txt", "./d/e.txt"] [("", ["./a.txt", "./d/e.txt"])] ++
    listing .fallback "/" ["./etc/hosts"] [("", ["./etc/hosts"])] ++
    listing .fallback "/m" ["./src/a.txt", "./mise.toml"] [("", ["./src/a.txt", "./mise.toml"])] ++
    -- Config's listers: their filters' command lines are git's at the
    -- same root, so what the filter is fed tells them apart.
    listing (.ofDeclared rootDeclared) "/w" ["src/fd-w"] [] ++
    listing (.ofDeclared projectDeclared) "/w" ["proj-w"] [] ++
    listing (.ofDeclared projectDeclared) "/r" ["proj-r"] []

/-- The location of the workspace the checks register, which cannot read
files. -/
def remote : Location :=
  .reachable "ssh" "host" "/srv/r"

/-- The jobs of the checks: the workspace driver's, and the finder's
source's job, `workspace-files`. -/
def jobs (name : String) : Option (List Argument → Work) :=
  if name == Workspace.FindFile.job then some (Completion.answering Workspace.FindFile.answer)
  else workspaceJobs name

/-- The commands of the checks: the workspace driver's, the finder, the
minibuffer's next, the candidate checks' accept and self-insert, `register`,
which registers `remote` as a workspace of the project on `main`, and
`strand`, which registers it and gives it to the window's buffer. -/
def commands : List (String × Dispatched) :=
  let registers : EditorM Unit := discard <| Workspace.register remote workspaceOrigin (some "main")
  workspaceCommands ++
    [(Workspace.FindFile.name, fun call => do
        Workspace.FindFile.command call
        return none),
      (Minibuffer.nextName, fun call => do
        Minibuffer.nextCommand call
        return none),
      ("register", fun _ => do
        registers
        return none),
      ("strand", fun call => do
        registers
        Workspace.setBufferWorkspace call.target.window.buffer remote
        return none)] ++
    candidateCommands

/-- The bindings of the checks: the workspace driver's, `C-o f` the finder,
`C-o j` the next candidate, `C-o y` accept, `C-o r` and `C-o s` register
and strand, `C-o g` the finder rooted at `remote`, `C-o u` at a local
location the table does not know, and `C-o m` opens `/m/src/a.txt`. -/
def bindings : List (String × Invocation) :=
  workspaceBindings ++
    [("C-o f", invoke Workspace.FindFile.name), ("C-o j", invoke Minibuffer.nextName),
      ("C-o y", invoke "accept"), ("C-o r", invoke "register"), ("C-o s", invoke "strand"),
      ("C-o g", { command := Workspace.FindFile.name, arguments := remote.arguments }),
      ("C-o u",
        { command := Workspace.FindFile.name, arguments := (Location.local "/nowhere").arguments }),
      ("C-o m", opens "/m/src/a.txt")]

/-- The driver of the checks over `world`, its loop told of config's
`listers`, its jobs `registered`, its commands `commands` and its keys
`bindings`, with the scripts and two more files, `/w/src/w.lean` and
`/m/src/a.txt`; `none` if making the state was refused. -/
def driver (listers : Array Workspace.DeclaredLister := #[])
    (world : Workspace.World := workspaceWorld)
    (registered : String → Option (List Argument → Work) := jobs)
    (commands : List (String × Dispatched) := commands)
    (bindings : List (String × Invocation) := bindings) : Option TestDriver :=
  let keys := dispatchKeys bindings commands
  (workspaceDriver registered
        { keys with registered := { keys.registered with workspaceListers := listers } } (world :=
        world)).map
    fun driver =>
    { driver with
      jobs :=
        { driver.jobs with
          files :=
            (driver.jobs.files.withFile "/w/src/w.lean" "ww".toUTF8).withFile "/m/src/a.txt"
              "m".toUTF8
          processes :=
            { driver.jobs.processes with scripts := driver.jobs.processes.scripts ++ scripts } } }

/-- `driver` once every post it holds has arrived and every job it holds has
finished, and every job those start, oldest first. -/
def drained (driver : TestDriver) : TestDriver :=
  (List.range 12).foldl
    (fun driver _ =>
      match driver.posting[0]? with
      | some job => (driver.posted job.id).1
      | none =>
        match driver.pending[0]? with
        | some job => (driver.finish job.id).1
        | none => driver)
    driver

/-- `driver` once `keys` are pressed, and drained. -/
def drainedAfter (driver : TestDriver) (keys : String) : TestDriver :=
  drained (fedTo driver (presses keys)).1

/-- The texts the prompt open in `driver` lists. -/
def listedTexts (driver : TestDriver) : Option (Array String) :=
  (candidatesOf driver).map (·.listed.map (·.text))

/-- The label of the prompt open in `driver`. -/
def labelOf (driver : TestDriver) : Option String :=
  driver.loop.state.prompt.map (·.label)

end FindFileTest

end ModelTest
