import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Config.Stores
import Editor.Event
import Editor.File.Model
import Editor.Files
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Loop
import Editor.Loop.Driver
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Store
import Editor.Text
import Editor.Value
import Editor.Workspace
import Editor.Workspace.Attach
import Editor.Workspace.Model
import Editor.Workspace.Modes
import ModelTest.Support.Driver
import ModelTest.Support.Files
import ModelTest.Support.Keys
import ModelTest.Support.Loop
import ModelTest.Support.Models

/-!
# Model tests: support: Workspace

The workspace's world, jobs, commands, keys and driver, and the workspace a
check sees settled. Shared by several test modules under `ModelTest/Editor/`; it
holds no checks of its own.
-/

namespace ModelTest

open Editor

/-- A store of a number, for the checks of the workspace and project
stores. -/
def countStore : Store Nat :=
  { name := "count", version := 1, initial := 0, encode := .nat
    decode := fun
      | .nat n => some n
      | _ => none }

/-- The `origin` of the repository of the workspace driver checks. -/
def workspaceOrigin : String :=
  "git@github.com:o/r.git"

/-- The world of the workspace driver checks: a main checkout at `/r` on
`main` and a linked worktree of it at `/w` on `feature`, both with
`workspaceOrigin`; `/x` is in no repository and holds no marker. -/
def workspaceWorld : Workspace.World :=
  { repositories :=
      #[{ toplevel := "/r", commonDir := "/r/.git", origin := some workspaceOrigin },
        { toplevel := "/w", commonDir := "/r/.git", branch := some "feature"
          origin := some workspaceOrigin }]
    markerDirectories := #["/r/.git"], markers := #["/w/.git"] }

/-- The jobs of the workspace driver checks: the find job, the mode marker
job and the file command checks' jobs. -/
def workspaceJobs (name : String) : Option (List Argument → Work) :=
  if name == Workspace.findJob then some Workspace.findWork
  else if name == Workspace.markerJob then some Workspace.markerWork else fileJobs Files.limit name

/-- The bindings of the workspace driver checks: `C-o a`, `C-o b`
and `C-o c` open `a.lean`, `b.lean` and `c.lean` in `/r/src`, `C-o w`
opens `/w/src/b.lean` and `C-o x` opens `/x/a.txt`; `C-o i` runs
`workspace-current`; `C-o n` makes a buffer `made` that inherits the
workspace of the window's buffer, and a buffer `bare` that does not. -/
def workspaceBindings : List (String × Invocation) :=
  [("C-o a", opens "/r/src/a.lean"), ("C-o b", opens "/r/src/b.lean"),
    ("C-o c", opens "/r/src/c.lean"), ("C-o w", opens "/w/src/b.lean"), ("C-o x", opens "/x/a.txt"),
    ("C-o i", invoke Workspace.currentName), ("C-o n", invoke "inherit")]

/-- The commands of the workspace driver checks, by name: the open command,
`workspace-current` and `inherit` (`workspaceBindings`). -/
def workspaceCommands : List (String × Dispatched) :=
  [(Files.openName, fun call => do
      Files.openCommand call
      return none),
    (Workspace.currentName, fun call => do
      Workspace.currentCommand call
      return none),
    ("inherit", fun call => do
      if let .ok made← createBuffer "made" then
        discard <| made.inheritWorkspace call.target.window.buffer
      discard <| createBuffer "bare"
      return none)]

/-- The keys of the workspace driver checks (`workspaceBindings`,
`workspaceCommands`). -/
def workspaceKeys : Loop.Keys TestScheme.scheme :=
  dispatchKeys workspaceBindings workspaceCommands

/-- A driver with the keys `keys`, those of the workspace driver checks by
default, and the jobs `registered`, whose jobs meet the processes and the
files of `world`, `workspaceWorld` by default, for its three directories,
its git the program `git`, with the files the keys open, and two more in `/r/src` for the shell
checks' filters; `none` if making the state was refused. -/
def workspaceDriver (registered : String → Option (List Argument → Work) := workspaceJobs)
    (keys : Loop.Keys TestScheme.scheme := workspaceKeys) (git : String := "git")
    (world : Workspace.World := workspaceWorld) : Option TestDriver :=
  let model := world.jobModel git #["/r/src", "/w/src", "/x"]
  let files :=
    [("/r/src/a.lean", "a"), ("/r/src/b.lean", "b"), ("/r/src/c.lean", "c"), ("/w/src/b.lean", "w"),
          ("/x/a.txt", "x"), ("/r/src/s.txt", "b\nc\na\n"), ("/r/src/t.txt", "d\nb\nc\na")].foldl
      (fun (files : FileModel) (path, text) => files.withFile path text.toUTF8) model.files
  (Loop.Driver.over keys registered (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { model with files } }

/-- `driver` once `events` are fed and every job they start, and every job
those jobs' commands start, is finished, oldest first. -/
def settledOn (driver : TestDriver) (events : List Event) : TestDriver :=
  (List.range 8).foldl
    (fun driver _ =>
      match driver.pending[0]? with
      | some job => (driver.finish job.id).1
      | none => driver)
    (fedTo driver events).1

/-- `driver` once `keys` are pressed and every job they start, and every job
those jobs' commands start, is finished, oldest first. -/
def settledAfter (driver : TestDriver) (keys : String) : TestDriver :=
  settledOn driver (presses keys)

/-- The workspace of the buffer the view 0 of `driver` shows, and its
project. -/
def shownWorkspace (driver : TestDriver) : Option (Workspace × Project) := do
  driver.loop.state.workspaceOf? (← showing driver).id

end ModelTest
