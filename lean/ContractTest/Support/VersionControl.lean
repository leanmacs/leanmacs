import BuffersApiTest.Fake
import Editor.Config.Packages
import Editor.Test.Linked.Rig
import Editor.Test.Workspace
import Editor.VersionControl.Compiled
import FilesApiTest.Fake
import ProjectApiTest.Fake

/-!
# Contract tests: support: VersionControl

The jobs and keys the version-control buffer checks run the loop with, and the
invocation that moves the window's cursor to a row. Shared by several test
modules; it holds no checks of its own.
-/

namespace ContractTest

open Editor
open Editor.Test.Linked

/-- The workspace a directory of the version-control buffer checks is in,
standing in for the workspace finder's answer over real git in the
repository `main` (`withRepository`): under `main`, its main checkout on
`main`; under `feature` beside it, the linked worktree the checks add on
`feature`; both of the project whose common directory is `main`'s `.git`,
with no origin (`Workspace.Found.ofGit`, the core's, as the finder's git
adapter answers); anywhere else, none. -/
def repositoryFound (main directory : System.FilePath) : Option Workspace.Found :=
  let linked := main.parent.getD main / "feature"
  let commonDir := main / ".git"
  if Workspace.holds main directory then
    some (Workspace.Found.ofGit { toplevel := main, commonDir, branch := .named "main" } none)
  else
    if Workspace.holds linked directory then
      some
        (Workspace.Found.ofGit { toplevel := linked, commonDir, branch := .named "feature" } none)
    else none

/-- The packages the status buffer checks in the repository `main` stand on
beside version control: `files-api`'s fake (the kit's opener over the real
file service), the kit's stand-in for the workspace's attach and
`project-api`'s fake, each over `repositoryFound main`, and `buffers-api`'s
fake. -/
def statusNeighbours (main : System.FilePath) : Array Package :=
  #[FilesApiTest.fake, Test.attachByPackage (repositoryFound main),
    ProjectApiTest.fakeWith (repositoryFound main), BuffersApiTest.fake]

/-- The jobs of the status buffer check in the repository `main`: the
neighbours' (`statusNeighbours`) and the status buffer's, as a host
registers them. -/
def statusJobs (main : System.FilePath) : Array Config.JobRegistration :=
  rigJobs (statusNeighbours main) ++ VersionControl.package.registered.jobs

/-- The keys of the status buffer check: none bound; the file commands',
the workspace's and the version-control commands by name, `to-row`, which
puts the window's cursor at the start of the row its argument names, and
`set-text`, which makes the window's text its argument; their jobs
registered; and the version-control modes known to the loop; in the
repository `main`. -/
def statusKeys (main : System.FilePath) : Loop.Keys TestScheme.scheme :=
  let toRow : Call → EditorM (Option Config.Write) := fun call => do
    if let .nat row :: _ := call.arguments then
      let offset ← call.target.buffer.text.offsetOf ⟨row, 0⟩
      discard <| call.target.window.id.select { ranges := #[⟨offset, offset⟩] }
    return none
  let setText : Call → EditorM (Option Config.Write) := fun call => do
    if let .str text :: _ := call.arguments then
      let target := call.target.buffer.text
      target.replaceRange 0 (← target.byteLength) text
    return none
  { command? := fun name =>
      if name == "to-row" then some toRow
      else
        if name == "set-text" then some setText
        else
          ((rigCommands (statusNeighbours main) ++ VersionControl.package.registered.commands).find?
                (·.name == name)).bind
            fun registration =>
            match registration.action with
            | .call run =>
              some fun call => do
                run call
                return none
            | _ => none
    registered :=
      { jobs := fun name => (statusJobs main).any (·.name == name)
        -- The neighbours' values at the extension points, as a host's
        -- registry holds them: the stand-in's attach at `FilesApi.Opened`,
        -- the fake's `FilesApi.Files`, `project-api`'s fake's reach at
        -- `ProjectApi.Workspaces` and `buffers-api`'s fake's `close`.
        extensions := (rigKeys (statusNeighbours main)).registered.extensions
        entering := fun name =>
          (VersionControl.package.registered.modes.find? (·.name == name)).map ([·]) } }

/-- The invocation that puts the window's cursor at the start of `row`. -/
def toRow (row : Nat) : Invocation :=
  { command := "to-row", arguments := [.nat row] }

/-- The keys of the review buffer check: the status buffer check's, and
`to-excerpt`, which puts the window's cursor at the start of the excerpt of
its text its argument names; in the repository `main`. -/
def reviewKeys (main : System.FilePath) : Loop.Keys TestScheme.scheme :=
  let toExcerpt : Call → EditorM (Option Config.Write) := fun call => do
    if let .nat index :: _ := call.arguments then
      if let some excerpt := (← call.target.buffer.text.excerpts)[index]? then
        discard <| call.target.window.id.select { ranges := #[⟨excerpt.start, excerpt.start⟩] }
    return none
  { statusKeys main with
    command? := fun name =>
      if name == "to-excerpt" then some toExcerpt else (statusKeys main).command? name }

end ContractTest
