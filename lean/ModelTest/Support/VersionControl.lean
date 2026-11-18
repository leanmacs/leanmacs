import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Compile.Contribution
import Editor.Config.Owner
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.DisplayRules
import Editor.File
import Editor.File.Model
import Editor.Files
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Keymap
import Editor.Loop
import Editor.Loop.Driver
import Editor.Mode
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Text
import Editor.VersionControl
import Editor.VersionControl.Commit
import Editor.VersionControl.Compiled
import Editor.VersionControl.Hunk
import Editor.VersionControl.Model
import Editor.VersionControl.Show
import Editor.VersionControl.Stage
import Editor.VersionControl.Status
import Editor.Workspace
import Editor.Workspace.Attach
import ModelTest.Support.Driver
import ModelTest.Support.Keys
import ModelTest.Support.Loop
import ModelTest.Support.Shell
import ModelTest.Support.Workspace

/-!
# Model tests: support: VersionControl

The loop's driver of the version-control checks: the jobs, bindings,
commands and keys of the status buffer checks and of the hunk and message
buffer checks, the drivers over a model repository in `/r` they are built
with, and the git commands a driver has started there. Shared by several
test modules under `ModelTest/Editor/`; it holds no checks of its own.
-/

namespace ModelTest

open Editor

/-- The jobs of the status buffer checks: the workspace driver checks', and
the status buffer's read and apply jobs. -/
def statusJobs (name : String) : Option (List Argument → Work) :=
  if name == VersionControl.readJob then some VersionControl.readWork
  else
    if name == VersionControl.applyJob then some VersionControl.applyWork
    else if name == VersionControl.showJob then some VersionControl.showWork else workspaceJobs name

/-- The bindings of the status buffer checks: the workspace driver checks',
and `C-v s` (`vc-status`), `C-v t` (`vc-status-toggle`), `C-v v`
(`vc-status-visit`), `C-v r` (`vc-status-refresh`), `C-v a`
(`vc-status-stage`), `C-v u` (`vc-status-unstage`), `C-v k`, which gives
the window's buffer a workspace registered as reachable through `kube`,
and `C-v 0` to `C-v 5`, which put the window's cursor at the start of that
row. -/
def statusBindings : List (String × Invocation) :=
  workspaceBindings ++
    [("C-v s", invoke VersionControl.statusName), ("C-v t", invoke VersionControl.toggleName),
      ("C-v v", invoke VersionControl.visitName), ("C-v r", invoke VersionControl.refreshName),
      ("C-v a", invoke VersionControl.stageName), ("C-v u", invoke VersionControl.unstageName),
      ("C-v k", invoke "kube")] ++
    (List.range 6).map
      (fun row => (s!"C-v {row}", { command := "to-row", arguments := [.nat row] })) ++
    [("C-v w", { command := VersionControl.showName, arguments := [.str "v1 src/a.lean"] }),
      ("C-v h", invoke VersionControl.showName),
      ("C-v n", { command := VersionControl.showName, arguments := [.str "HEAD nope.txt"] }),
      ("C-v x", { command := VersionControl.showName, arguments := [.str "-x src/a.lean"] })]

/-- The commands of the status buffer checks (`statusBindings`). -/
def statusCommands : List (String × Dispatched) :=
  workspaceCommands ++ dispatchedOf VersionControl.commands ++
    [("to-row", fun call => do
        if let .nat row :: _ := call.arguments then
          let offset ← call.target.buffer.text.offsetOf ⟨row, 0⟩
          discard <| call.target.window.id.select { ranges := #[⟨offset, offset⟩] }
        return none),
      ("kube", fun call => do
        let location := Location.reachable "kube" "pod" "/app"
        discard <| Workspace.register location workspaceOrigin
        Workspace.setBufferWorkspace call.target.window.buffer location
        return none)]

/-- The keys of the status buffer checks (`statusBindings`), with the status
buffer's mode registered, as a host's registry holds it: the mode's roles
on their keys in a status buffer, and its name known to the loop that sets
it. -/
def statusKeys : Loop.Keys TestScheme.scheme :=
  let keys := dispatchKeys statusBindings statusCommands
  let registry := ({} : Config.Registry).replaceModes .compiled VersionControl.modes
  { keys with
    maps := fun state view =>
      registry.activeMaps TestScheme.scheme state view ++ keys.maps state view
    registered :=
      { keys.registered with
        entering := fun name => (VersionControl.modes.find? (·.name == name)).map ([·]) } }

/-- A driver of the status buffer checks: the workspace driver's world, with
the status buffer's keys and jobs (or `keys` and `registered`), whose git in `/r` meets `repository`
(`Repository.jobModel`) and answers `writes`, and with each file of
`repository`'s working tree on disk under `/r`; `none` if making the state
was refused. -/
def statusDriverOf (repository : VersionControl.Model.Repository)
    (writes : Array VersionControl.Request := #[]) (missing : Array (String × String) := #[])
    (registered : String → Option (List Argument → Work) := statusJobs)
    (keys : Loop.Keys TestScheme.scheme := statusKeys) : Option TestDriver :=
  (workspaceDriver registered keys).map fun driver =>
    let scripts := (repository.jobModel "git" "/r" writes missing).processes.scripts
    { driver with
      jobs :=
        { driver.jobs with
          files :=
            repository.worktree.foldl
              (fun (files : FileModel) (path, content) =>
                files.withFile (("/r" : System.FilePath) / path) content.toUTF8)
              driver.jobs.files
          processes :=
            { driver.jobs.processes with scripts := driver.jobs.processes.scripts ++ scripts } } }

/-- The name of the status buffer of `/r`. -/
def statusBufferName : String :=
  "*vc-status: r@main*"

/-- The git commands `driver`'s jobs have started in the root `/r`, oldest
first: the status buffer's, and none of the finder's, which runs in the
file's directory. -/
def gitStarted (driver : TestDriver) : Array Process.Command :=
  driver.jobs.processes.started.filter fun command =>
    command.program == "git" && command.directory == ("/r" : System.FilePath)

/-- The jobs of the hunk and message buffer checks: every job of the
version-control registrations (`VersionControl.jobs`), and the workspace
driver checks', the file commands' among them. -/
def stagingJobs (name : String) : Option (List Argument → Work) :=
  ((VersionControl.jobs.find? (·.name == name)).map (·.work)) <|> workspaceJobs name

/-- The bindings of the hunk and message buffer checks: the workspace driver
checks', and `C-v s` (`vc-status`), `C-v g` (`vc-stage-hunk`), `C-v G`
(`vc-unstage-hunk`), `C-v c` (`vc-commit`), `C-v y` (`vc-commit-accept`),
`C-v q` (`vc-commit-abort`), `C-v z`, which puts `0\n` at the start of the
window's text, `C-v m` and `C-v n`, which make the window's text the
messages `stagingMessage` and `edited\n`, `C-v d` and `C-v D`, which hand
the loop what a check of the window's file finds when another program has
changed it or removed it (`Files.checked`), and `C-r 0` to `C-r 9`, which
put the window's cursor at the start of that row, and `C-r t` of row 10. -/
def stagingBindings : List (String × Invocation) :=
  workspaceBindings ++
    [("C-v s", invoke VersionControl.statusName), ("C-v g", invoke VersionControl.stageHunkName),
      ("C-v G", invoke VersionControl.unstageHunkName), ("C-v c", invoke VersionControl.commitName),
      ("C-v y", invoke VersionControl.acceptName), ("C-v q", invoke VersionControl.abortName),
      ("C-v z", invoke "top-line"),
      ("C-v m",
        { command := "set-text",
          arguments := [.str "Subject line\n\n# kept, as git's own cleanup keeps it\n"] }),
      ("C-v n", { command := "set-text", arguments := [.str "edited\n"] }),
      ("C-v d", invoke "disk-changed"),
      ("C-v D", { command := "disk-changed", arguments := [.bool true] })] ++
    (List.range 10).map
      (fun row => (s!"C-r {row}", { command := "to-row", arguments := [.nat row] })) ++
    [("C-r t", { command := "to-row", arguments := [.nat 10] })]

/-- The keys of the hunk and message buffer checks (`stagingBindings`), with
the version-control modes known to the loop that sets them. -/
def stagingKeys : Loop.Keys TestScheme.scheme :=
  let keys :=
    dispatchKeys stagingBindings
      (statusCommands ++
        [("top-line", fun call => do
            call.target.buffer.text.insert 0 "0\n"
            return none),
          ("set-text", fun call => do
            if let .str text :: _ := call.arguments then
              let target := call.target.buffer.text
              target.replaceRange 0 (← target.byteLength) text
            return none),
          ("disk-changed", fun call => do
            let buffer := call.target.window.buffer
            if let some file := ((← editorState).buffer? buffer).bind (·.file) then
              Files.checked
                  #[({ buffer, path := file.path, stamp := file.stamp },
                      if call.arguments == [.bool true] then .error .notFound
                      else .ok { file.stamp with size := file.stamp.size + 1 })]
            return none)])
  { keys with
    registered :=
      { keys.registered with
        entering := fun name => (VersionControl.modes.find? (·.name == name)).map ([·]) } }

/-- The writes the hunk and message buffer checks expect git to be asked for
in `/r`: an apply, its reverse and a commit. -/
def stagingWrites : Array VersionControl.Request :=
  let none := VersionControl.LineHunk.make 0 0 "" "" "" ""
  #[.stageHunk "" none, .unstageHunk "" none, .commit ""]

/-- A driver of the hunk and message buffer checks over `repository`
(`statusDriverOf`), whose git says each revision and path of `missing` is
not there, by default that the index has no `src/b.lean`, and whose files
may be saved in `/r/src`. -/
def stagingDriverOf (repository : VersionControl.Model.Repository)
    (missing : Array (String × String) := #[("", "src/b.lean")]) : Option TestDriver :=
  (statusDriverOf repository stagingWrites missing stagingJobs stagingKeys).map fun driver =>
    { driver with
      jobs :=
        { driver.jobs with
          files :=
            { driver.jobs.files with
              directories := driver.jobs.files.directories.push "/r/src" } } }

end ModelTest
