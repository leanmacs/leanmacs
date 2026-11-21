import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Config.Stores
import Editor.Event
import Editor.Extension
import Editor.File.Model
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
import Editor.Test.Driver
import Editor.Test.Files
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Test.Opener
import Editor.Text
import Editor.Value
import Editor.Workspace
import Editor.Workspace.Attach
import Editor.Workspace.Model
import Editor.Workspace.Modes
import Editor.Workspace.Reach
import FilesApi
import ProjectApi

/-!
# The test kit: Workspace

The workspace's world, jobs, commands, keys and driver, and the workspace a
check sees settled. Shared by several test modules under `ModelTest/Editor/`; it
holds no checks of its own.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import"). The core's own model tests are written on it.
-/

namespace Editor.Test

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

/-- The jobs of the workspace driver checks with the file jobs `files`: the
find job, the mode marker job and those. -/
def workspaceJobsWith (files : String → Option (List Argument → Work)) (name : String) :
    Option (List Argument → Work) :=
  if name == Workspace.findJob then some Workspace.findWork
  else if name == Workspace.markerJob then some Workspace.markerWork else files name

/-- The jobs of the workspace driver checks: the find job, the mode marker
job and the kit's opener's (`Editor/Test/Opener.lean`), whose load attaches
a buffer that takes in a file to its workspace (`Workspace.attach`), as a
file's open does. -/
def workspaceJobs (name : String) : Option (List Argument → Work) :=
  workspaceJobsWith (Opener.jobsWith Workspace.attach) name

/-- The bindings of the workspace driver checks: `C-o a`, `C-o b`
and `C-o c` open `a.lean`, `b.lean` and `c.lean` in `/r/src`, `C-o w`
opens `/w/src/b.lean` and `C-o x` opens `/x/a.txt`; `C-o i` runs
`workspace-current`; `C-o n` makes a buffer `made` that inherits the
workspace of the window's buffer, and a buffer `bare` that does not. -/
def workspaceBindings : List (String × Invocation) :=
  [("C-o a", opens "/r/src/a.lean"), ("C-o b", opens "/r/src/b.lean"),
    ("C-o c", opens "/r/src/c.lean"), ("C-o w", opens "/w/src/b.lean"), ("C-o x", opens "/x/a.txt"),
    ("C-o i", invoke Workspace.currentName), ("C-o n", invoke "inherit")]

/-- The commands of the workspace driver checks, by name, with the file
commands `files`: those, `workspace-current` and `inherit`
(`workspaceBindings`). -/
def workspaceCommandsWith (files : List (String × Dispatched)) : List (String × Dispatched) :=
  files ++
    [(Workspace.currentName, fun call => do
        Workspace.currentCommand call
        return none),
      ("inherit", fun call => do
        if let .ok made← createBuffer "made" then
          discard <| made.inheritWorkspace call.target.window.buffer
        discard <| createBuffer "bare"
        return none)]

/-- The commands of the workspace driver checks, by name: the kit's opener's
(`Opener.commands`), `workspace-current` and `inherit`. -/
def workspaceCommands : List (String × Dispatched) :=
  workspaceCommandsWith Opener.commands

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

/-- Gives the buffer `id` the workspace `found` at once, as the workspace
finder's answer recorded for the directory of `path` under the config
generation now: a stand-in for the workspace feature's attach, which a
test of another feature registers at the interface library `files-api`'s
hook `FilesApi.Opened` in its place. It starts no job and looks for no
mode on markers. -/
def attachAt (found : Workspace.Found) (id : BufferId) (path : System.FilePath) : EditorM Unit := do
  let directory := (path.parent.map Process.trimmed).getD found.root
  let (_, generation) ← RegistryRequest.ask .workspaceSettings
  discard <| EditorState.ask (.recordWorkspace directory generation (some found))
  Workspace.setBufferWorkspace id (.local found.root)

/-- Gives the buffer `id` of the file at `path` the workspace the finder's
pure model of `world` answers for the file's directory (`World.find`), with
config's roots none (`attachAt`); nothing for a directory in none. -/
def attachIn (world : Workspace.World := workspaceWorld) (id : BufferId) (path : System.FilePath) :
    EditorM Unit := do
  let some directory := path.parent | return
  if let some found := world.find {} directory then
    attachAt found id path

/-- A package, standing in for the workspace's, that registers `attachIn
world` at `FilesApi.Opened` under the workspace's name. -/
def attachPackage (world : Workspace.World := workspaceWorld) : Package :=
  { name := "test-workspace"
    setup := Extension.add ({ name := "workspace", opened := attachIn world } : FilesApi.Opened) }

/-- A package that registers the workspace feature's own attach
(`Workspace.attach`) at `FilesApi.Opened`, as the workspace package does: for
a driver of handed commands and jobs whose files feature runs that hook, so
a file's open finds its workspace with the find job, as in a host. -/
def workspaceAttachPackage : Package :=
  { name := "test-workspace-attach"
    setup := Extension.add ({ name := "workspace", opened := Workspace.attach } : FilesApi.Opened) }

/-- The workspace feature's own finding and reaching, as a package the kit
makes of the workspace's modules (`Editor/Workspace/Attach.lean`,
`Editor/Workspace/Reach.lean`): the find job and the mode marker job, the
attach at `files-api`'s `FilesApi.Opened`, and the reach as `project-api`'s
`ProjectApi.Workspaces` value. It is for a check of another feature over real
files or real git, which finds workspaces as a host does but names no module
of the workspace feature. -/
def workspaceFinderPackage : Package :=
  { name := "test-workspace-finder"
    setup := do
      workJob Workspace.findJob Workspace.findWork (restarted := true)
      workJob Workspace.markerJob Workspace.markerWork (restarted := true)
      Extension.add ({ name := "workspace", opened := Workspace.attach } : FilesApi.Opened)
      Extension.add
          ({  name := ProjectApi.implementationName
              reach := fun continuation path git view carried =>
                Workspace.Reach.reach continuation path git view carried
              work := Workspace.Reach.work } : ProjectApi.Workspaces) }

end Editor.Test
