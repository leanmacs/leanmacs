import Editor.Api
import Editor.Clipboard
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Real
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Displays
import Editor.Completion.Styles
import Editor.Config.Packages
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
import Editor.Process
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.SyntaxTree
import Editor.TabBar
import Editor.Test.Linked.Jobs
import Editor.Text
import Editor.Text.Real
import Editor.Value
import Editor.Watch
import Editor.Workspace
import Editor.Workspace.Compiled

/-!
# The linked test kit: Rig

The editor's loop over the real services, as the checks of a feature over
them drive it: its jobs, commands and keys (`ProjectRig`, `rigJobs`,
`rigCommands`, `rigKeys`), runs
settled until every job has run, an opened file and a buffer's text; and a
child's `PATH`, set for every child a rig's services start (`withPath`,
`onChanged`, `onFixturePath`). Shared by several test modules; it holds no
checks of its own.

**The rig names no feature that is not the core's.** Its default keys and
jobs are the file commands' and the workspace's, with no contribution told
to the loop. A check of another feature passes its own: the version-control
checks theirs (`ContractTest/Support/VersionControl.lean`), and the compile
mode's, in its package, the compile mode's commands and jobs and the
shipped contributions (`packages/compile/CompileTest/Linked/Compile/Shipped.lean`).

Published for a package's linked test: it is a module of the core's linked
test kit, in the namespace `Editor.Test.Linked`, which the root of a
package's linked test and the modules under it may import, and no other
module of a package may (`docs/design/packages.md`, "What a package may
import"). It runs over the
Rust library, so only a test linked as the editor is can use it: a
package's linked test (`<P>Test.Linked` and the modules under it), as the
core's `contract-test` does.
-/

namespace Editor.Test.Linked

open Editor

/-- `command` with `PATH` set to `path` in its own environment, in place of
any `PATH` it sets. -/
def withPath (path : String) (command : Process.Command) : Process.Command :=
  { command with
    environment :=
      { command.environment with
        set := (command.environment.set.filter (·.1 != "PATH")).push ("PATH", path) } }

/-- `services` whose process service starts every child with its command
changed by `change`, after the environment its directory's lookup gives it:
each request that starts a child is matched constructor by constructor, so
the replies' types line up. The test process's own environment is never
touched. -/
def onChanged (services : Job.Services) (change : Process.Command → Process.Command) :
    Job.Services :=
  let processes := services.processes
  let changed : ProcessRequest → ProcessRequest
    | .run command limit => .run (change command) limit
    | .runWithin command limit time => .runWithin (change command) limit time
    | .runInput command input limit time => .runInput (change command) input limit time
    | .runHead command input limit time => .runHead (change command) input limit time
    | .start command streaming => .start (change command) streaming
    | other => other
  { services with
    processes :=
      { start := fun id request => processes.start id (changed request)
        take := fun id request =>
          match request with
          | .run command limit => processes.take id (.run (change command) limit)
          | .runWithin command limit time =>
            processes.take id (.runWithin (change command) limit time)
          | .runInput command input limit time =>
            processes.take id (.runInput (change command) input limit time)
          | .runHead command input limit time =>
            processes.take id (.runHead (change command) input limit time)
          | .start command streaming => processes.take id (.start (change command) streaming)
          | .read process => processes.take id (.read process)
          | .write process bytes => processes.take id (.write process bytes)
          | .closeInput process => processes.take id (.closeInput process)
        cancel := processes.cancel } }

/-- `services` whose process service starts every child with `PATH` set to
`path`, after the environment its directory's lookup gives it
(`onChanged`). -/
def onFixturePath (services : Job.Services) (path : String) : Job.Services :=
  onChanged services (withPath path)

/-- The jobs a rig's checks run by default: the file commands' and the
workspace's, the listing job among them, as a host registers them. -/
def rigJobs : Array Config.JobRegistration :=
  Files.package.registered.jobs ++ Workspace.package.registered.jobs

/-- The commands a rig's checks run by default: the file commands' and the
workspace's, as a host registers them. A check of another feature appends
its own, as it appends its jobs to `rigJobs`. -/
def rigCommands : Array Config.Registration :=
  Files.package.registered.commands ++ Workspace.package.registered.commands

/-- The keys a rig's checks run by default: none bound; the file commands'
and the workspace's commands by name (`rigCommands`); their jobs
registered; and no contribution told to the loop. -/
def rigKeys : Loop.Keys TestScheme.scheme :=
  { command? := fun name =>
      (rigCommands.find? (·.name == name)).bind fun registration =>
        match registration.action with
        | .call run =>
          some fun call => do
            run call
            return none
        | _ => none
    registered := { jobs := fun name => rigJobs.any (·.name == name) } }

/-- What a rig's checks run with: their services, whose file
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
          diffs := Job.realDiffs services.completions published.reader held (← Job.RefusedDiffs.new)
          greps :=
            Job.realGreps services.completions published.reader held (← Job.RealGreps.new) } }

/-- A rig over `services`, whose children get `path` as their `PATH`
(`onFixturePath`), with a file service of its own. -/
def ProjectRig.new (services : Job.Services) (path : String) : IO ProjectRig :=
  ProjectRig.over (onFixturePath services path)

/-- `stepped`'s loop once what the step asked for is done, as a host does
it, with `keys` and the jobs `jobs`, the rig's by default:
each invocation it answered run as a step of its own; each job it
started spawned on the rig's services with its posts collected, waited for,
then each post delivered in order (`runPosted`) and then its command, handed
what the job held (`Job.finishWith`); each taken in the same way, at most
`depth` deep. Only a job's end is waited for. `none` when a job did not end
in time or ended otherwise than finished, or a step was refused. -/
partial def settleProjects (rig : ProjectRig) (texts : RealTexts)
    (stepped : Loop.Stepped TestScheme.scheme) (depth : Nat := 8)
    (keys : Loop.Keys TestScheme.scheme := rigKeys)
    (jobs : Array Config.JobRegistration := rigJobs) :
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
    (invocations : List Invocation) (keys : Loop.Keys TestScheme.scheme := rigKeys)
    (jobs : Array Config.JobRegistration := rigJobs) :
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
    (keys : Loop.Keys TestScheme.scheme := rigKeys)
    (jobs : Array Config.JobRegistration := rigJobs) :
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

end Editor.Test.Linked
