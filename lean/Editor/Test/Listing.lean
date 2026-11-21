import Editor.Config.Registry
import Editor.Extension
import Editor.File.Model
import Editor.Job.Model
import Editor.Loop.Driver
import Editor.Process
import Editor.Process.Model
import Editor.ProjectMode
import Editor.ProjectMode.Listing
import Editor.Setup
import Editor.Test.Driver
import Editor.Test.Keys
import Editor.Test.Shell
import Editor.Test.Workspace
import Editor.Workspace
import FilesApi

/-!
# The test kit: Listing

A contribution with a listing, `t-mode`, and its world: the repositories it
is found in, what its listing prints in each, and what a driver is asked
about it. The world it is found in (`listingWorld`, `listingJobModel`)
names the workspace finder's model and is the workspace feature's kit's
(`packages/workspace/WorkspaceTest/Kit.lean`). It names core modules only, with stand-ins
written over the core's API for what the workspace does once a file opens:
a listing file's workspace and on-modes (`listingFound`, `listingOn`,
`listingOpened`, and `kubeOpened` for a workspace that cannot run
commands), modes on markers turned on as given (`markedPackage`), and the
marker search over a known set of marker files (`markersBy`,
`markersByPackage`). So the checks of the listing
(`ModelTest/Editor/ProjectMode/Listing.lean`) build their host from it with
no package outside the core, and the compile mode's checks of what it makes
of a listing and of its hook, in its package
(`packages/compile/CompileTest/`), use the same world. It holds no checks of
its own.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import"). The core's own model tests are written on it.
-/

namespace Editor.Test

open Editor

/-- What `t-mode`'s listing prints, read: one command a line, `name=line`
or `name=line=directory`. -/
def tRead (bytes : ByteArray) : Except String (Array Compile.NamedCommand) := do
  let some text := String.fromUTF8? bytes | throw "it is not UTF-8"
  ((text.splitOn "\n").filter (!·.isEmpty)).toArray.mapM fun line =>
      match line.splitOn "=" with
      | [name, line] => pure { name, line }
      | [name, line, directory] => pure { name, line, directory := some directory }
      | _ => throw s!"{line} is no command"

/-- The contribution of the listing checks: `t-mode` on `t.toml`, with the
commands `build` (`t-fixed-build`) and `check` (`t-check`), and its listing
`t-list`, read by `tRead`. -/
def tContribution : Compile.Contribution :=
  { mode := "t-mode", markers := #["t.toml"]
    commands :=
      #[{ name := "build", line := "t-fixed-build" }, { name := "check", line := "t-check" }]
    listing := some { program := "t-list", read := tRead } }

/-- The registry of the listing checks: `t-mode` registered by config. -/
def listingRegistry : Config.Registry :=
  match Config.Registrations.ofSetup (compileContribution tContribution) with
  | .ok registrations =>
    ({} : Config.Registry).replaceContributions .config registrations.contributions
  | .error _ => {}

/-- The listing `t-list` in `directory`. -/
def tList (directory : System.FilePath) : Process.Command :=
  { program := "t-list", directory }

/-- What each run of the listing checks does: `t-list` in `/t` lists
`build`, `fmt` and `sub`, in `sub`; in `/t2` it fails; in `/u` it lists
`u-only`. -/
def listingScripts : Array Process.Script :=
  #[{ command := tList "/t", reply := shellReply "build=t-build\nfmt=t-fmt\nsub=t-sub=sub\n" },
    { command := tList "/t2", reply := shellReply "" "t-list: broken\nmore\n" (.code 3) },
    { command := tList "/u", reply := shellReply "u-only=u-only\n" }]

/-- The files the listing checks open, by the key that opens each: `C-p 1`
and `C-p 2` two files of `/t`, `C-p 3` and `C-p 5` two of `/t2`, and `C-p 4`
one of `/u`. -/
def listingFiles : List (String × System.FilePath) :=
  [("C-p 1", "/t/a.txt"), ("C-p 2", "/t/b.txt"), ("C-p 3", "/t2/a.txt"), ("C-p 4", "/u/a.txt"),
    ("C-p 5", "/t2/b.txt")]

/-- The job model of the listing checks with no workspace world: the files
of `listingFiles`, the listings' runs (`listingScripts`) and the streaming
children `streams`. A check that runs the workspace's finder and marker search
takes the workspace feature's kit's `listingJobModel`, which adds its world. -/
def listingRuns (streams : Array Process.StreamScript := #[]) : JobModel :=
  { files :=
      listingFiles.foldl (fun (files : FileModel) (_, path) => files.withFile path "a".toUTF8) {}
    processes := { scripts := listingScripts, streams } }

/-- A package, standing in for the workspace's modes on markers, that
registers at `files-api`'s hook `FilesApi.Opened` a value turning the
on-modes `on`, nearest first, on in every buffer that takes in a file
(`Workspace.turnOnModes`, the core's): what a check of a listing, the core's
or the compile mode's, registers in place of the workspace package's marker
search. -/
def markedPackage (on : Array Workspace.OnMode) : Package :=
  { name := "test-marked"
    setup :=
      Extension.add
        ({ name := "marker-modes", opened := fun id _ => Workspace.turnOnModes id on } :
          FilesApi.Opened) }

/-- The workspace a file of the listing checks is in, standing in for the
workspace finder's answer: the repository `/t` or `/t2` that holds it, and
none for one in `/u`, which is in no repository. -/
def listingFound (path : System.FilePath) : Option Workspace.Found :=
  (#["/t2", "/t"] : Array System.FilePath).findSome? fun root =>
    if (path.parent.map (Workspace.holds root)).getD false then
      some
        { root,
          project := { identity := .commonDir (root / ".git"), name := root.fileName.getD "" } }
    else none

/-- The on-modes a file of the listing checks turns on, standing in for the
workspace's modes on markers: `t-mode` at the directory of `/t`, `/t2` or
`/u` that holds it, each of which holds `t.toml`. -/
def listingOn (path : System.FilePath) : Array Workspace.OnMode :=
  match
    (#["/t2", "/t", "/u"] : Array System.FilePath).find? fun root =>
      (path.parent.map (Workspace.holds root)).getD false with
  | some root => #[{ mode := "t-mode", root }]
  | none => #[]

/-- What the listing checks run once a buffer takes in a file, in place of the
workspace's attach and its marker search: the file's workspace by
`listingFound` (the kit's `attachAt`), then its on-modes by `listingOn`, as
the kit's stand-in for modes on markers (`markedPackage`) turns them on
(`Workspace.turnOnModes`, the core's). -/
def listingOpened (id : BufferId) (path : System.FilePath) : EditorM Unit := do
  if let some found := listingFound path then
    attachAt found id path
  Workspace.turnOnModes id (listingOn path)

/-- What the listing checks run once a buffer takes in a file in a workspace
whose location cannot run commands: the buffer's workspace is the reachable
`kube` location, registered over the core's API, and then its on-modes by
`listingOn`. -/
def kubeOpened (id : BufferId) (path : System.FilePath) : EditorM Unit := do
  let location := Location.reachable "kube" "pod" "/app"
  discard <| Workspace.register location "git@github.com:o/r.git"
  Workspace.setBufferWorkspace id location
  Workspace.turnOnModes id (listingOn path)

/-- Turns on, in the buffer `id` of the file at `path`, the on-modes the
marker files `present` give by the core's rules (`Workspace.markerSearchPaths`,
`Workspace.onModes`) for the marker modes registered now: looking from the
file's directory up to the root of the workspace `found` answers for it, or
in the directory alone when it answers none, as the workspace's marker
search bounds its look. A stand-in for that search over a known set of
marker files, which stats none and starts no job. -/
def markersBy (found : System.FilePath → Option Workspace.Found) (present : Array System.FilePath)
    (id : BufferId) (path : System.FilePath) : EditorM Unit := do
  let some directory := path.parent.map Process.trimmed | return
  let (settings, _) ← RegistryRequest.ask .workspaceSettings
  let bound := ((found directory).map (·.root)).getD directory
  let searched :=
    Workspace.markerSearchPaths (Workspace.markersOf settings.markerModes) directory bound
  let seen :=
    searched.filterMap fun (at_, file, marker) =>
      if present.contains file then some (at_, marker) else none
  Workspace.turnOnModes id (Workspace.onModes settings.markerModes directory bound seen)

/-- A package, standing in for the workspace's modes on markers, that
registers `markersBy found present` at `files-api`'s hook `FilesApi.Opened`:
for a driver or a rig whose files `files-api`'s fake opens, registered after
the stand-in for the workspace's attach, as the workspace looks for markers
once a file's workspace is found. -/
def markersByPackage (found : System.FilePath → Option Workspace.Found)
    (present : Array System.FilePath) : Package :=
  { name := "test-marked"
    setup :=
      Extension.add
        ({ name := "marker-modes", opened := markersBy found present } : FilesApi.Opened) }

/-- The on-modes of the buffer the view 0 of `driver` shows. -/
def shownOnModes (driver : TestDriver) : Option (Array Workspace.OnMode) := do
  return Workspace.onModesOf driver.loop.state (← showing driver).id

/-- `driver` once `keys` are pressed and every job they start, and every job
those jobs' commands start, is finished, oldest first; with the names of the
jobs finished, in order. -/
def settledNames (driver : TestDriver) (keys : String) : TestDriver × Array String :=
  (List.range 8).foldl
    (fun (driver, names) _ =>
      match driver.pending[0]? with
      | some job => ((driver.finish job.id).1, names.push job.name)
      | none => (driver, names))
    ((fedTo driver (presses keys)).1, #[])

/-- How many times `driver` has started `command`. -/
def startedCount (driver : TestDriver) (command : Process.Command) : Nat :=
  (driver.jobs.processes.started.filter (· == command)).size

end Editor.Test
