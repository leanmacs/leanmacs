import Editor.Invocation
import Editor.Job
import Editor.Loop.Driver
import Editor.ProjectMode.Listing
import Editor.State
import Editor.Test.Driver
import Editor.Test.Files
import Editor.Test.Listing
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Test.Opener
import Editor.Workspace
import Editor.Workspace.Kit
import Editor.Workspace.Modes
import ModelTest.Check

/-!
# Model tests: `Editor/Workspace/Modes.lean`

The model tests of `Editor/Workspace/Modes.lean`: `workspaceModesChecks`. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

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
  let keys :=
    { keys with registered := { keys.registered with compile := listingRegistry.compileHook } }
  (Loop.Driver.over keys markerListingJobs (EditorState.initial ⟨640, 480⟩)
        editorModel).toOption.map
    fun driver => { driver with jobs := listingJobModel }

/-- The checks of the workspace's modes on markers
(`Editor/Workspace/Modes.lean`): that its marker search turns a found mode
on, and so starts the mode's listing, on the workspace driver over the
listing checks' world. -/
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
              (Compile.entriesOf second.loop.state (some (.local "/t"))).size == 1 }]

end ModelTest
