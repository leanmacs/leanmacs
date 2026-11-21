import Editor.Api
import Editor.Command.Call
import Editor.Extension
import Editor.File.Model
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Loop.Driver
import Editor.Test.Driver
import Editor.Test.Files
import Editor.Test.Keys
import Editor.Test.Listing
import Editor.Test.Models
import Editor.Test.Opener
import Editor.Test.Workspace
import Editor.Workspace
import Editor.Workspace.Attach
import Editor.Workspace.Compiled
import Editor.Workspace.Model
import Editor.Workspace.Modes
import Editor.Workspace.Reach
import FilesApi
import ProjectApi

/-!
# The workspace feature's test kit

The workspace's world, jobs, commands, keys and driver, made of the
workspace feature's modules (`Editor/Workspace/`): the world of the
workspace driver checks (`workspaceWorld`), the finder's find job and mode
marker job beside the kit's opener (`workspaceJobs`), the keys that open its
files and ask `workspace-current` (`workspaceKeys`), the driver over them
(`workspaceDriver`), the attach by the finder's model (`attachIn`,
`worldAttachPackage`), the feature's own attach (`workspaceAttachPackage`),
its finding and reaching as a package (`workspaceFinderPackage`), the
listing checks' world (`listingWorld`, `listingJobModel`), and its
package as a rig registers it (`Editor.Test.Linked.rigWorkspace`). The
workspace a check sees settled and the stand-in for the attach that names no
workspace module are the core's kit's (`Editor/Test/Workspace.lean`).

It is the workspace feature's kit: a test double, which a package's test
modules may import and its library may not (`docs/design/packages.md`,
"What a package may import"), and which moves into the workspace package's
test library when the feature moves out.
-/

namespace Editor.Test

open Editor

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
def worldAttachPackage (world : Workspace.World := workspaceWorld) : Package :=
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

/-- The world of the listing checks: the repositories `/t` and `/t2`, each
holding `t.toml`, and `/u`, a directory holding `t.toml` in no
repository. -/
def listingWorld : Workspace.World :=
  { repositories :=
      #[{ toplevel := "/t", commonDir := "/t/.git" },
        { toplevel := "/t2", commonDir := "/t2/.git" }]
    markerDirectories := #["/t/.git", "/t2/.git"]
    markers := #["/t/t.toml", "/t2/t.toml", "/u/t.toml"] }

/-- The job model of the listing checks: `listingWorld`'s, with the files
of `listingFiles`, the listings' runs (`listingScripts`) and the streaming
children `streams`. -/
def listingJobModel (streams : Array Process.StreamScript := #[]) : JobModel :=
  let model := listingWorld.jobModel "git" #["/t", "/t2", "/u"]
  let files :=
    listingFiles.foldl (fun (files : FileModel) (_, path) => files.withFile path "a".toUTF8)
      model.files
  { model with
    files
    processes :=
      { model.processes with
        scripts := model.processes.scripts ++ listingScripts, streams } }

end Editor.Test

namespace Editor.Test.Linked

open Editor

/-- The workspace package, as a host registers it: what a rig's checks of
files in a workspace pass beside the file commands' package, which the
rig does not name (the files feature's test kit hands it,
`Editor/Files/Kit.lean`, `filesPackage`). -/
def rigWorkspace : Package :=
  Workspace.package

end Editor.Test.Linked
