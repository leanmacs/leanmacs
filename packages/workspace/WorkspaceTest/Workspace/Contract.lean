import Editor.Job
import Editor.Job.Model
import Editor.Process
import Editor.Process.Model
import Editor.Workspace
import WorkspaceTest.Finder.Contract
import WorkspaceTest.Finder.Model

/-!
# Model tests: `WorkspaceTest/Finder/Contract.lean`

The model tests of `WorkspaceTest/Finder/Contract.lean`:
`workspaceFinderFailures` and `modeMarkerFailures`. The test driver's root,
`WorkspaceTest/Model.lean`, runs them; its module doc says what each shows.
-/

namespace WorkspaceTest

open Editor

/-- The names of the workspace finder's contract properties
(`WorkspaceTest/Finder/Contract.lean`) that do not hold of the pure model
(`World.find`), or of the real finder run on the job model of the
property's world (`World.jobModel`); and, for a property that must not ask
git, of a run that started a process. -/
def workspaceFinderFailures : IO (List String) :=
  pure <|
    (Workspace.FinderContract.properties "/").flatMap fun property =>
      let settings := property.settings "git"
      let directories := property.asked.map (·.1)
      let byModel := property.asked.map fun (directory, _) => property.world.find settings directory
      let (outcome, after) :=
        (property.answers "git").runModel (property.world.jobModel "git" directories)
      (if byModel == property.expected then []
        else [s!"the workspace finder's model: {property.name}"]) ++
        (if outcome == .finished property.expected then []
        else [s!"the workspace finder on the job model: {property.name}"]) ++
        if property.asksGit || after.processes.started.isEmpty then []
        else [s!"the workspace finder on the job model starts no process: {property.name}"]

/-- The names of the mode marker search's contract properties
(`WorkspaceTest/Finder/Contract.lean`, `Workspace.MarkerContract`) that do not
hold of the pure model (`World.presentMarkers`), or of the real search run
on the job model of the property's world (`World.jobModel`); and of a run
that started a process, which the search never does. -/
def modeMarkerFailures : IO (List String) :=
  pure <|
    (Workspace.MarkerContract.properties "/").flatMap fun property =>
      let byModel :=
        property.asked.map fun (directory, bound, _) =>
          property.world.presentMarkers property.markers directory bound
      let (outcome, after) := property.answers.runModel (property.world.jobModel "git" #[])
      (if byModel == property.expected then []
        else [s!"the mode marker search's model: {property.name}"]) ++
        (if outcome == .finished property.expected then []
        else [s!"the mode marker search on the job model: {property.name}"]) ++
        if after.processes.started.isEmpty then []
        else [s!"the mode marker search on the job model starts no process: {property.name}"]

end WorkspaceTest
