import Editor.Job
import Editor.RealHost
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Trees
import Editor.Workspace
import WorkspaceTest.Check
import WorkspaceTest.Finder.Contract
import WorkspaceTest.Finder.Model

/-!
# Linked tests: `WorkspaceTest/Finder/Contract.lean`

The tests of `WorkspaceTest/Finder/Contract.lean`:
`workspaceFinderContractChecks` and `modeMarkerContractChecks`, the
workspace finder's contract over the real process and file services, a
check for each property. They were the contract test's (`ContractTest.<name>`)
while the workspaces were modules of the core. The linked test's root,
`WorkspaceTest/Linked.lean`, runs them; its module doc says what each
shows.

It runs a port's contract against its real adapter, outside the rule of the
wiring set (`docs/dev-practices/real-thread-checks.md`): it declares
`.contract` because its root hands it the real services (W46, W48).
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.WorkspaceTest.Linked.Workspace.Contract : Editor.WiringSet :=
  .contract "Workspace.FinderContract and MarkerContract against real git and find"

namespace WorkspaceTest.Linked

open Editor
open Editor.Test.Linked

/-- Writes the git fixture's file for `repository` in its top level: the
three lines rev-parse prints there (`tests/workspaces/README`), and its
`origin`, if it has one. -/
def writeRepository (repository : Workspace.Repository) : IO Unit := do
  writeMaking (repository.toplevel / "fixture-git")
      ((String.fromUTF8? repository.revParsed).getD "")
  if let some origin := repository.origin then
    writeMaking (repository.toplevel / "fixture-origin") s!"{origin}\n"

/-- Writes `world` to disk, for the finder's run over the real services: each
repository's fixture files, each marker file, empty, each marker directory,
and each directory of `asked`. -/
def materialize (world : Workspace.World) (asked : Array System.FilePath) : IO Unit := do
  for repository in world.repositories do
    writeRepository repository
  for marker in world.markers do
    writeMaking marker ""
  for directory in world.markerDirectories ++ asked do
    IO.FS.createDirAll directory

/-- The git a property's finder runs over the real services: the fixture
under `fixtures`, or, in a world with no git, a path under `base` where
nothing is, which the process service refuses as `notFound`. -/
def gitOf (world : Workspace.World) (fixtures base : System.FilePath) : String :=
  if world.git then (fixtures / "git").toString else (base / "no-git").toString

/-- The workspace finder's contract properties
(`WorkspaceTest/Finder/Contract.lean`) against `Workspace.find` over the
library's process and file services, a check each, in the contract's
order: each world written out in a temporary directory of its own, removed
only once the process and file services have worked what was handed to
them (`withFlushedBase`), with git standing in as the fixture under
`fixtures` (`tests/workspaces`). A property that does not hold fails
through `saw` with its outcome. That each child is reaped is the process
service's own contract, not pinned here. -/
def workspaceFinderContractChecks (services : Job.Services) (fixtures : System.FilePath) :
    List Check :=
  (Workspace.FinderContract.properties "/").map fun named =>
    { name := s!"the workspace finder over the process and file services: {named.name}"
      run :=
        withFlushedBase services fun base => do
          let some property :=
            (Workspace.FinderContract.properties base).find? (·.name == named.name)
            | saw false "no property of that name at the temporary directory"
          materialize property.world (property.asked.map (·.1))
          let outcome ← runOnTimers services (property.holds (gitOf property.world fixtures base))
          saw (outcome == .finished true) s!"{repr outcome}" }

/-- The mode marker search's contract properties
(`WorkspaceTest/Finder/Contract.lean`, `Workspace.MarkerContract`) against
`Workspace.presentMarkers` over the library's file service, a check each,
in the contract's order: each world written out in a temporary directory of
its own, removed once the services have worked what was handed to them
(`withFlushedBase`). A property that does not hold fails through `saw` with
its outcome. -/
def modeMarkerContractChecks (services : Job.Services) : List Check :=
  (Workspace.MarkerContract.properties "/").map fun named =>
    { name := s!"the mode marker search over the file service: {named.name}"
      run :=
        withFlushedBase services fun base => do
          let some property :=
            (Workspace.MarkerContract.properties base).find? (·.name == named.name)
            | saw false "no property of that name at the temporary directory"
          materialize property.world (property.asked.map (·.1))
          let outcome ← runOnTimers services property.holds
          saw (outcome == .finished true) s!"{repr outcome}" }

end WorkspaceTest.Linked
