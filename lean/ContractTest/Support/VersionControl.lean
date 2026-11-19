import ContractTest.Support.Projects
import Editor.Config.Packages
import Editor.VersionControl.Compiled

/-!
# Contract tests: support: VersionControl

The jobs and keys the version-control buffer checks run the loop with, and the
invocation that moves the window's cursor to a row. Shared by several test
modules; it holds no checks of its own.
-/

namespace ContractTest

open Editor

/-- The jobs of the status buffer check: the file commands', the workspace
finder's and the status buffer's, as a host registers them. -/
def statusJobs : Array Config.JobRegistration :=
  Files.package.registered.jobs ++ Workspace.package.registered.jobs ++
    VersionControl.package.registered.jobs

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
          ((Files.package.registered.commands ++ Workspace.package.registered.commands ++
                    VersionControl.package.registered.commands).find?
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
