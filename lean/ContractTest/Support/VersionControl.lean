import BuffersApiTest.Fake
import Editor.Config.Packages
import Editor.Test.Linked.Rig
import Editor.Test.Workspace
import Editor.VersionControl.Compiled
import FilesApiTest.Fake

/-!
# Contract tests: support: VersionControl

The jobs and keys the version-control buffer checks run the loop with, and the
invocation that moves the window's cursor to a row. Shared by several test
modules; it holds no checks of its own.
-/

namespace ContractTest

open Editor
open Editor.Test.Linked

/-- The packages the status buffer checks stand on beside version control:
`files-api`'s fake (the kit's opener over the real file service), the
kit's package of the workspace's finding and reaching
(`Test.workspaceFinderPackage`), and `buffers-api`'s fake. -/
def statusNeighbours : Array Package :=
  #[FilesApiTest.fake, Test.workspaceFinderPackage, BuffersApiTest.fake]

/-- The jobs of the status buffer check: the neighbours' (`statusNeighbours`)
and the status buffer's, as a host registers them. -/
def statusJobs : Array Config.JobRegistration :=
  rigJobs statusNeighbours ++ VersionControl.package.registered.jobs

/-- The keys of the status buffer check: none bound; the file commands',
the workspace's and the version-control commands by name, `to-row`, which
puts the window's cursor at the start of the row its argument names, and
`set-text`, which makes the window's text its argument; their jobs
registered; and the version-control modes known to the loop. -/
def statusKeys : Loop.Keys TestScheme.scheme :=
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
          ((rigCommands statusNeighbours ++ VersionControl.package.registered.commands).find?
                (·.name == name)).bind
            fun registration =>
            match registration.action with
            | .call run =>
              some fun call => do
                run call
                return none
            | _ => none
    registered :=
      { jobs := fun name => statusJobs.any (·.name == name)
        -- The neighbours' values at the extension points, as a host's
        -- registry holds them: the workspace's attach at `FilesApi.Opened`,
        -- the fake's `FilesApi.Files`, the reach at `ProjectApi.Workspaces`
        -- and `buffers-api`'s fake's `close`.
        extensions := (rigKeys statusNeighbours).registered.extensions
        entering := fun name =>
          (VersionControl.package.registered.modes.find? (·.name == name)).map ([·]) } }

/-- The invocation that puts the window's cursor at the start of `row`. -/
def toRow (row : Nat) : Invocation :=
  { command := "to-row", arguments := [.nat row] }

/-- The keys of the review buffer check: the status buffer check's, and
`to-excerpt`, which puts the window's cursor at the start of the excerpt of
its text its argument names. -/
def reviewKeys : Loop.Keys TestScheme.scheme :=
  let toExcerpt : Call → EditorM (Option Config.Write) := fun call => do
    if let .nat index :: _ := call.arguments then
      if let some excerpt := (← call.target.buffer.text.excerpts)[index]? then
        discard <| call.target.window.id.select { ranges := #[⟨excerpt.start, excerpt.start⟩] }
    return none
  { statusKeys with
    command? := fun name =>
      if name == "to-excerpt" then some toExcerpt else statusKeys.command? name }

end ContractTest
