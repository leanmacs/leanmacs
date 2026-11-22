import Editor.File.Model
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Loop.Driver
import Editor.ProjectMode.Listing
import Editor.Setup
import Editor.State
import Editor.Test.Driver
import Editor.Test.Files
import Editor.Test.Listing
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Test.Opener
import Editor.Test.Workspace
import Editor.Workspace
import Workspace.Modes
import WorkspaceTest.Check
import WorkspaceTest.Kit

/-!
# Model tests: `Workspace/Modes.lean`

The model tests of `Workspace/Modes.lean`: `workspaceModesChecks`. The test
driver's root, `WorkspaceTest/Model.lean`, runs them; its module doc says
what each shows.
-/

namespace WorkspaceTest

open Editor
open Editor.Test

/-- The jobs of the workspace's modes checks: the workspace driver's, the
find job and the mode marker job over the kit's opener, whose load attaches
a buffer that takes in a file (`workspaceJobs`), and the listing job. -/
def markerListingJobs (name : String) : Option (List Argument → Work) :=
  if name == Compile.listJob then some Compile.listWork else workspaceJobs name

/-- A driver of the workspace's modes checks: the listing checks' world
(`listingJobModel`), whose files the kit's listing keys open
(`listingFiles`), the workspace's find job and mode marker job, and the
loop told `t-mode` registered in config (`listingRegistry`); `none` if
making the state was refused. -/
def markerListingDriver : Option TestDriver :=
  let keys := dispatchKeys (listingFiles.map fun (key, path) => (key, opens path)) Opener.commands
  let keys := toldHook keys listingRegistry
  (Loop.Driver.over keys markerListingJobs (EditorState.initial ⟨640, 480⟩)
        editorModel).toOption.map
    fun driver => { driver with jobs := listingJobModel }

/-- The world of the workspace's marker checks: the workspace driver checks'
world (`workspaceWorld`), a repository `/up/repo` with no origin, a
repository `/o` of another origin, and the marker files of
`markerRegistry`'s modes. -/
def markerWorld : Workspace.World :=
  { workspaceWorld with
    repositories :=
      workspaceWorld.repositories ++
        #[{ toplevel := "/up/repo", commonDir := "/up/repo/.git" },
          { toplevel := "/o", commonDir := "/o/.git", origin := some "git@github.com:o/other.git" }]
    markerDirectories :=
      workspaceWorld.markerDirectories ++ (#["/up/repo/.git", "/o/.git"] : Array System.FilePath)
    markers :=
      workspaceWorld.markers ++
        (#["/r/a/marker.toml", "/up/marker.toml", "/loose/marker.toml", "/loose2/marker.toml",
            "/r/hook/b.toml", "/r/hook/one/two/a.toml", "/r/crate/Cargo.toml",
            "/w/crate/Cargo.toml", "/o/Cargo.toml"] :
          Array System.FilePath) }

/-- Every directory a file of the marker checks opens in, each of which git
is scripted for: one git leaves unscripted would fall to the marker
adapter. -/
def markerDirectories : Array System.FilePath :=
  #["/r/src", "/r/a/b/c", "/up/repo/src", "/loose/deep", "/loose2", "/r/hook/one/two/three/four"]

/-- The files of the marker checks, each a path and a text, by the key that
opens it: `C-o a` `/r/src/a.lean`, `C-o m` `/r/a/b/c/x.txt`, `C-o u`
`/up/repo/src/u.txt`, `C-o l` `/loose/deep/l.txt`, `C-o 2` `/loose2/l.txt`,
and `C-o h` and `C-o g` `f.txt` and `g.txt` in
`/r/hook/one/two/three/four`. -/
def markerFiles : List (String × System.FilePath × String) :=
  [("C-o a", "/r/src/a.lean", "a"), ("C-o m", "/r/a/b/c/x.txt", "x"),
    ("C-o u", "/up/repo/src/u.txt", "u"), ("C-o l", "/loose/deep/l.txt", "l"),
    ("C-o 2", "/loose2/l.txt", "l"), ("C-o h", "/r/hook/one/two/three/four/f.txt", "f"),
    ("C-o g", "/r/hook/one/two/three/four/g.txt", "g")]

/-- The registry of the marker checks: in this order, `b-mode` on `b.toml`,
`a-mode` on `a.toml`, `marker-mode` on `marker.toml` and `cargo-mode` on
`Cargo.toml`, each a compile contribution registered by config with its
markers alone. -/
def markerRegistry : Config.Registry :=
  let setup : SetupM Unit := do
    compileContribution { mode := "b-mode", markers := #["b.toml"] }
    compileContribution { mode := "a-mode", markers := #["a.toml"] }
    compileContribution { mode := "marker-mode", markers := #["marker.toml"] }
    compileContribution { mode := "cargo-mode", markers := #["Cargo.toml"] }
  hostedRegistry #[] setup

/-- A driver of the marker checks over `registry`, `markerRegistry` by
default: the world of `markerWorld`, the workspace's find job and mode
marker job over the kit's opener, whose load attaches a buffer that takes in
a file (`workspaceJobs`), the keys that open `markerFiles`, and the loop
told `registry`'s contributions; `none` if making the state was refused. -/
def markerDriver (registry : Config.Registry := markerRegistry) : Option TestDriver :=
  let model := markerWorld.jobModel "git" markerDirectories
  let files :=
    markerFiles.foldl (fun (files : FileModel) (_, path, text) => files.withFile path text.toUTF8)
      model.files
  let keys := dispatchKeys (markerFiles.map fun (key, path, _) => (key, opens path)) Opener.commands
  let keys := toldHook keys registry
  (Loop.Driver.over keys workspaceJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { model with files } }

/-- The minor modes of the buffer the view 0 of `driver` shows. -/
def shownMinorModes (driver : TestDriver) : Option (Array String) :=
  (showing driver).map (·.buffer.minors)

/-- The checks of the workspace's modes on markers
(`Workspace/Modes.lean`), on the workspace driver: that its marker
search turns a found mode on, and so starts the mode's listing, over the
listing checks' world; and, over the world of `markerWorld` with the modes
of `markerRegistry`, which markers turn which modes on, with which roots and
in what order, when the search runs and when it does not, and the marker
job's order. -/
def workspaceModesChecks : List Check :=
  [{  name :=
        "turning t-mode on runs its listing t-list in its root once, after find-mode-markers; a second file under the root starts compile-list again and runs nothing"
      run :=
        pure <|
          match markerListingDriver with
          | none => false
          | some driver =>
            let (first, names) := settledNames driver "C-p 1"
            let (second, again) := settledNames first "C-p 2"
            shownOnModes first == some #[{ mode := "t-mode", root := "/t" }] &&
              names.filter (fun name => name == Workspace.markerJob || name == Compile.listJob) ==
                #[Workspace.markerJob, Compile.listJob] &&
              startedCount first (tList "/t") == 1 &&
              again.contains Compile.listJob &&
              startedCount second (tList "/t") == 1 &&
              (Compile.entriesOf second.loop.state (some (.local "/t"))).size == 1 },
    { name :=
        "hook criterion 1: a contribution registered in config with marker marker.toml turns marker-mode on in a buffer of /r/a/b/c/x.txt, two directories under /r/a/marker.toml, with /r/a as its root, and not in a buffer of /r/src/a.lean outside it"
      run :=
        pure <|
          match markerDriver with
          | none => false
          | some driver =>
            let inside := settledAfter driver "C-o m"
            let outside := settledAfter driver "C-o a"
            (shownWorkspace inside).map (·.1.location) == some (.local "/r") &&
              shownMinorModes inside == some #["marker-mode"] &&
              shownOnModes inside == some #[{ mode := "marker-mode", root := "/r/a" }] &&
              (shownWorkspace outside).map (·.1.location) == some (.local "/r") &&
              shownMinorModes outside == some #[] &&
              shownOnModes outside == some #[] },
    { name :=
        "hook criterion 2: a marker above the buffer's workspace root turns no mode on: /up/marker.toml above the workspace /up/repo; /loose/marker.toml above /loose/deep/l.txt, which has no workspace and looks in its own directory alone; /loose2/marker.toml beside /loose2/l.txt turns marker-mode on with root /loose2"
      run :=
        pure <|
          match markerDriver with
          | none => false
          | some driver =>
            let up := settledAfter driver "C-o u"
            let loose := settledAfter driver "C-o l"
            let beside := settledAfter driver "C-o 2"
            (shownWorkspace up).map (·.1.location) == some (.local "/up/repo") &&
              shownMinorModes up == some #[] &&
              shownOnModes up == some #[] &&
              (showing loose).map (·.buffer.name) == some "l.txt" &&
              (shownWorkspace loose).isNone &&
              shownMinorModes loose == some #[] &&
              shownOnModes loose == some #[] &&
              (shownWorkspace beside).isNone &&
              shownMinorModes beside == some #["marker-mode"] &&
              shownOnModes beside == some #[{ mode := "marker-mode", root := "/loose2" }] },
    { name :=
        "hook criterion 3: with a-mode's marker two directories above the file and b-mode's four, both inside /r, both modes are on, a-mode first with root /r/hook/one/two and b-mode with root /r/hook, though b-mode was registered first"
      run :=
        pure <|
          match markerDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o h"
            shownOnModes opened ==
                some
                  #[{ mode := "a-mode", root := "/r/hook/one/two" },
                    { mode := "b-mode", root := "/r/hook" }] &&
              shownMinorModes opened == some #["a-mode", "b-mode"] },
    { name :=
        "with no compile contribution registered, opening a file starts no find-mode-markers job and gives the buffer no on-modes"
      run :=
        pure <|
          match markerDriver (registry := {}) with
          | none => false
          | some driver =>
            let (opened, names) := settledNames driver "C-o a"
            names.contains Workspace.findJob && !names.contains Workspace.markerJob &&
              shownOnModes opened == some #[] &&
              shownMinorModes opened == some #[] },
    { name :=
        "a second file of a directory whose workspace is cached gets its on-modes from find-mode-markers, with no git run"
      run :=
        pure <|
          match markerDriver with
          | none => false
          | some driver =>
            let first := settledAfter driver "C-o h"
            let (second, names) := settledNames first "C-o g"
            (showing second).map (·.buffer.name) == some "g.txt" &&
              second.jobs.processes.started == first.jobs.processes.started &&
              names.contains Workspace.markerJob &&
              !names.contains Workspace.findJob &&
              shownOnModes second == shownOnModes first &&
              shownMinorModes second == some #["a-mode", "b-mode"] },
    { name :=
        "a marker order crosses as arguments and back, and arguments that are no order read as none; the marker job started with them fails"
      run :=
        let orders : List Workspace.MarkerOrder :=
          [{ buffer := ⟨1⟩, directory := "/r/src", bound := "/r", markers := #[] },
            { buffer := ⟨4⟩, directory := "/a b/é", bound := "/a b", markers := #["a.toml", "B"] }]
        pure
          (orders.all
              (fun order => Workspace.MarkerOrder.ofArguments? order.arguments == some order) &&
            [[], [.nat 1, .str "/r"], [.nat 1, .str "/r", .str "/r", .nat 0]].all
              (Workspace.MarkerOrder.ofArguments? · == none) &&
            ((Workspace.markerWork [.nat 1] ()).runModel {}).1 matches .failed _) }]

end WorkspaceTest
