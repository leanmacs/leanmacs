import Editor.Job
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Services
import Editor.Test.Linked.Trees
import Editor.Workspace
import WorkspaceTest.Finder.Contract
import WorkspaceTest.Finder.Model

/-!
# Linked tests: `WorkspaceTest/Finder/Contract.lean`

The tests of `WorkspaceTest/Finder/Contract.lean`: `workspaceFailures` and
`modeMarkerFailures`, the workspace finder's contract over the real process
and file services. They were the contract test's (`ContractTest.<name>`)
while the workspaces were modules of the core. The linked test's root,
`WorkspaceTest/Linked.lean`, runs them; its module doc says what each
shows.
-/

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

/-- The names of the workspace finder's contract properties
(`WorkspaceTest/Finder/Contract.lean`) that do not hold of `Workspace.find`
over the library's process and file services, each world written out in a
temporary directory of its own, with git standing in as the fixture under
`fixtures` (`tests/workspaces`); and that every child it ran is reaped. -/
def workspaceFailures (services : Job.Services) (fixtures : System.FilePath) : IO (List String) :=
  do
  let before ← Editor.Test.Linked.pendingChildren
  let failed ←
    (Workspace.FinderContract.properties "/").filterMapM fun named =>
        withBase fun base => do
          let some property :=
            (Workspace.FinderContract.properties base).find? (·.name == named.name)
            | return some named.name
          materialize property.world (property.asked.map (·.1))
          let outcome ← runOnTimers services (property.holds (gitOf property.world fixtures base))
          return if outcome == .finished true then none
            else some s!"{property.name} ({repr outcome})"
  let reaped ← eventually (return (← Editor.Test.Linked.pendingChildren) == before)
  return failed.map (s!"the workspace finder over the process and file services: {·}") ++
      if reaped then [] else ["every child the workspace finder ran is reaped"]

/-- The names of the mode marker search's contract properties
(`WorkspaceTest/Finder/Contract.lean`, `Workspace.MarkerContract`) that do not
hold of `Workspace.presentMarkers` over the library's file service, each
world written out in a temporary directory of its own. -/
def modeMarkerFailures (services : Job.Services) : IO (List String) := do
  let failed ←
    (Workspace.MarkerContract.properties "/").filterMapM fun named =>
        withBase fun base => do
          let some property :=
            (Workspace.MarkerContract.properties base).find? (·.name == named.name)
            | return some named.name
          materialize property.world (property.asked.map (·.1))
          let outcome ← runOnTimers services property.holds
          return if outcome == .finished true then none
            else some s!"{property.name} ({repr outcome})"
  return failed.map (s!"the mode marker search over the file service: {·}")

end WorkspaceTest.Linked
