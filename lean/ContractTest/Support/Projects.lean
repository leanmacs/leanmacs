import ContractTest.Support.Git
import ContractTest.Support.Jobs
import Editor.Api
import Editor.Clipboard
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Real
import Editor.Compile.Compiled
import Editor.Compile.Contribution
import Editor.Compile.Shipped
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Displays
import Editor.Completion.Styles
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.Display
import Editor.Display.Recorder
import Editor.DisplayRules
import Editor.Ex.Line
import Editor.Ffi.Snapshot
import Editor.Files
import Editor.Files.Compiled
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Real
import Editor.Job.Runner
import Editor.Keymap
import Editor.Language
import Editor.Layout
import Editor.Loop
import Editor.Menu
import Editor.Mode
import Editor.ModeLine
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.SyntaxTree
import Editor.TabBar
import Editor.Text
import Editor.Text.Real
import Editor.Value
import Editor.Watch
import Editor.Workspace
import Editor.Workspace.Compiled

/-!
# Contract tests: support: Projects

The editor's loop over the real services, as the project mode checks and the
status buffer checks drive it: its jobs and keys (`ProjectRig`), runs settled
until every job has run, an opened file and a buffer's text. Shared by several
test modules; it holds no checks of its own.
-/

namespace ContractTest

open Editor

/-- The jobs of the project mode checks: the file commands', the workspace
finder's and the compile mode's, as a host registers them. -/
def projectJobs : Array Config.JobRegistration :=
  Files.jobs ++ Workspace.jobs ++ Compile.jobs

/-- The keys of the project mode checks: none bound; the file commands',
the workspace's and the compile mode's commands by name; their jobs
registered; and the loop told the shipped contributions. -/
def projectKeys : Loop.Keys TestScheme.scheme :=
  { command? := fun name =>
      ((Files.commands ++ Workspace.commands ++ Compile.commands).find? (·.name == name)).bind
        fun registration =>
        match registration.action with
        | .call run =>
          some fun call => do
            run call
            return none
        | _ => none
    registered :=
      { jobs := fun name => projectJobs.any (·.name == name)
        compile := { contributions := Compile.shipped } } }

/-- What the project mode checks run with: their services, whose file
service reads the table of snapshots their texts publish and keeps its loads
in `held`, and the display those texts are drawn on. -/
structure ProjectRig where
  /-- The table of snapshots the texts publish. -/
  published : Snapshots
  /-- What the jobs hold. -/
  held : Job.HeldSnapshots
  /-- The display. -/
  display : DisplayHandler
  /-- The services the jobs run on. -/
  services : Job.Services

/-- A rig over `services`, with a file service and a diff service of its own,
each reading the snapshots its texts publish. -/
def ProjectRig.over (services : Job.Services) : IO ProjectRig := do
  let published ← Snapshots.new
  let held ← Job.HeldSnapshots.new
  let recorder ← DisplayRecorder.new { advance := 8, lineHeight := 16 } published.reader
  return {
      published, held, display := recorder.handle
      services :=
        { services with
          files := Job.realFiles services.completions published.reader held
          diffs :=
            Job.realDiffs services.completions published.reader held (← Job.RefusedDiffs.new) } }

/-- A rig over `services`, whose children get `path` as their `PATH`
(`onFixturePath`), with a file service of its own. -/
def ProjectRig.new (services : Job.Services) (path : String) : IO ProjectRig :=
  ProjectRig.over (onFixturePath services path)

/-- `stepped`'s loop once what the step asked for is done, as a host does
it, with `keys` and the jobs `jobs`, the project mode checks' by default:
each invocation it answered run as a step of its own; each job it
started spawned on the rig's services with its posts collected, waited for,
then each post delivered in order (`runPosted`) and then its command, handed
what the job held (`Job.finishWith`); each taken in the same way, at most
`depth` deep. Only a job's end is waited for. `none` when a job did not end
in time or ended otherwise than finished, or a step was refused. -/
partial def settleProjects (rig : ProjectRig) (texts : RealTexts)
    (stepped : Loop.Stepped TestScheme.scheme) (depth : Nat := 8)
    (keys : Loop.Keys TestScheme.scheme := projectKeys)
    (jobs : Array Config.JobRegistration := projectJobs) :
    IO (Option (Loop TestScheme.scheme × RealTexts)) := do
  if depth == 0 then
    return none
  let mut loop := stepped.loop
  let mut texts := texts
  for invocation in stepped.answered do
    let (next, after) ← (loop.invoke keys invocation).runReal texts rig.display
    let .ok next := next | return none
    let some (settled, after) ← settleProjects rig after next (depth - 1) keys jobs | return none
    loop := settled
    texts := after
  for start in stepped.starts do
    let some work := (jobs.find? (·.name == start.name)).map (·.work start.arguments) | return none
    let posts ← IO.mkRef (#[] : Array Invocation)
    let handle ←
      Job.spawn rig.services work (pure ()) fun invocation => posts.modify (·.push invocation)
    unless ← eventually handle.ended do
      handle.cancel
      return none
    let label := s!"job {start.name}"
    for invocation in ← posts.get do
      let (next, after) ← (loop.deliver keys label (runPosted invocation)).runReal texts rig.display
      let .ok next := next | return none
      let some (settled, after) ← settleProjects rig after next (depth - 1) keys jobs | return none
      loop := settled
      texts := after
    let some (.finished command) ← handle.outcome? | return none
    let (next, after) ←
      Job.finishWith rig.held handle (loop.deliver keys label command) texts rig.display
    let .ok next := next | return none
    let some (settled, after) ← settleProjects rig after next (depth - 1) keys jobs | return none
    loop := settled
    texts := after
  return some (loop, texts)

/-- `loop`, over `texts`, once each of `invocations` has run with `keys` and
settled with `jobs` (`settleProjects`), in order. -/
def runSettledFrom (rig : ProjectRig) (loop : Loop TestScheme.scheme) (texts : RealTexts)
    (invocations : List Invocation) (keys : Loop.Keys TestScheme.scheme := projectKeys)
    (jobs : Array Config.JobRegistration := projectJobs) :
    IO (Option (Loop TestScheme.scheme × RealTexts)) := do
  let mut loop := loop
  let mut texts := texts
  for invocation in invocations do
    let (stepped, after) ← (loop.invoke keys invocation).runReal texts rig.display
    let .ok stepped := stepped | return none
    let some (settled, after) ←
      settleProjects rig after stepped (keys := keys) (jobs := jobs) | return none
    loop := settled
    texts := after
  return some (loop, texts)

/-- The loop, with its working directory `base`, once each of
`invocations` has run with `keys` and settled with `jobs`
(`settleProjects`), in order. -/
def runSettled (rig : ProjectRig) (base : System.FilePath) (invocations : List Invocation)
    (keys : Loop.Keys TestScheme.scheme := projectKeys)
    (jobs : Array Config.JobRegistration := projectJobs) :
    IO (Option (Loop TestScheme.scheme × RealTexts)) := do
  let begin : EditorM (Loop TestScheme.scheme) := do
    let loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
    return { loop with state := { loop.state with workingDirectory := base } }
  let (started, texts) ← begin.runReal (RealTexts.over rig.published) rig.display
  let .ok loop := started | return none
  runSettledFrom rig loop texts invocations keys jobs

/-- The invocation that opens `path`. -/
def openFile (path : System.FilePath) : Invocation :=
  { command := Files.openName, arguments := [.str path.toString] }

/-- The text of the buffer called `name` in `loop`. -/
def bufferText (rig : ProjectRig) (texts : RealTexts) (loop : Loop TestScheme.scheme)
    (name : String) : IO (Option String) := do
  let read : EditorM (Option String) := do
    let some id := loop.state.findBuffer name | return none
    let some buffer := loop.state.buffer? id | return none
    return some (← buffer.text.read)
  let (text, _) ← read.runReal texts rig.display
  return text.toOption.join

end ContractTest
