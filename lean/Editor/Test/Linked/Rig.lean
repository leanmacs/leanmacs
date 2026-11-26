import Editor.Api
import Editor.Clipboard
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Real
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.Display
import Editor.Display.Recorder
import Editor.DisplayRules
import Editor.Ex.Line
import Editor.Ffi.Snapshot
import Editor.FileJobs
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
import Editor.Package
import Editor.Process
import Editor.Program
import Editor.RealHost
import Editor.Scene
import Editor.State
import Editor.SyntaxTree
import Editor.TabBar
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Services
import Editor.Text
import Editor.Text.Real
import Editor.Value
import Editor.Watch
import Editor.Workspace

/-!
# The linked test kit: Rig

The editor's loop over the real services, as the checks of a feature over
them drive it: its jobs, commands and keys (`ProjectRig`, `rigJobs`,
`rigCommands`, `rigKeys`), over the real services or stepped over fakes
(`ProjectRig.stepped`), runs settled until every job has run, an opened
file and a buffer's text; and services whose children's commands are
changed, set for every child a rig's services start (`onChanged`). Shared
by several test modules; it holds no checks of its own.

**The rig names no file feature.** A check passes the keys and jobs it
runs with (`runSettled`'s `keys` and `jobs`), which `rigKeys` and `rigJobs`
make of the packages it names, with no contribution told to the loop: a
check of files in a workspace names the files package (the files feature's
test kit hands it, `filesPackage`) and the workspace's (`rigWorkspace`, the workspace feature's kit's,
`packages/workspace/WorkspaceTest/Kit.lean`), the
version-control checks theirs (`ContractTest/Support/VersionControl.lean`),
and the compile mode's, in its package, the compile mode's commands and jobs
and the shipped contributions
(`packages/compile/CompileTest/Linked/Compile/Shipped.lean`). The invocation
that opens a file names the core's name of the open command
(`FileJobs.openFileCommand`).

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
        cancel := processes.cancel
        flush := processes.flush } }

/-- The jobs a rig's checks run over `packages`: every package's, as a host
registers them. -/
def rigJobs (packages : Array Package) : Array Config.JobRegistration :=
  packages.flatMap (·.registered.jobs)

/-- The commands a rig's checks run over `packages`: every package's, as a
host registers them. A check of another feature appends its own, as it
appends its jobs to `rigJobs`. -/
def rigCommands (packages : Array Package) : Array Config.Registration :=
  packages.flatMap (·.registered.commands)

/-- The keys a rig's checks run over `packages`: none bound; the packages'
commands by name (`rigCommands`); their jobs registered; the values they
register at extension points, as a host installs them, so a hook a feature
runs finds the values its neighbours registered; and no contribution told
to the loop. -/
def rigKeys (packages : Array Package) : Loop.Keys TestScheme.scheme :=
  { command? := fun name =>
      ((rigCommands packages).find? (·.name == name)).bind fun registration =>
        match registration.action with
        | .call run =>
          some fun call => do
            run call
            return none
        | _ => none
    registered :=
      { jobs := fun name => (rigJobs packages).any (·.name == name)
        extensions :=
          let (state, _) : Config.State Unit Unit × Array String := Config.State.ofPackages packages
          state.registry.extensionsAt } }

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
  /-- The fakes the jobs run on, for a stepped rig (`ProjectRig.stepped`),
  with the clock they wait on: each job is run to its end on the check's
  thread (`Job.FakePump.runToEnd`); none for a rig over the real services. -/
  fakes : Option (SteppedServices × Job.FakeClock) := none

/-- The mark of `ProjectRig.over`: it runs a real background service (`Editor/RealHost.lean`). -/
def ProjectRig.over.realHost : RealHost :=
  .service

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
          greps := Job.realGreps services.completions published.reader held (← Job.RealGreps.new)
          grammars := Job.realGrammars services.completions (← Job.RefusedGrammars.new) } }

/-- A rig over fakes alone (`SteppedServices`): a table of waits, a fake clock
and a fake watch service of its own, the file fake over `files`, as the
files, the diffs and the searches, reading the snapshots the rig's texts
publish and holding its loads in the rig's table, and the process fake over
`processes`. Its jobs run on the check's thread, each to its end
(`settleProjects`): no thread, no count. -/
def ProjectRig.stepped (files : FileModel := {}) (processes : ProcessModel := {}) :
    IO (ProjectRig × SteppedServices) := do
  let completions ← Job.Completions.new
  let clock ← Job.FakeClock.new completions
  let watches ← Job.FakeFileWatches.new completions
  let published ← Snapshots.new
  let held ← Job.HeldSnapshots.new
  let stepped ←
    SteppedServices.new completions clock watches (Job.realSnapshots published.reader) held files
        processes
  let recorder ← DisplayRecorder.new { advance := 8, lineHeight := 16 } published.reader
  return ({
        published, held, display := recorder.handle, services := stepped.jobs
        fakes := some (stepped, clock) },
      stepped)

/-- Waits for `handle`'s job to end: on a stepped rig, run to its end on the
caller's thread with its clock moved as its waits start
(`Job.FakePump.runToEnd`), which throws when something is left; over real
services, on its outcome, with `patience` a hang guard. Whether it ended. -/
def ProjectRig.ran (rig : ProjectRig) (handle : Job.Handle) : IO Bool := do
  match rig.fakes with
  | some (stepped, clock) =>
    stepped.pump.runToEnd handle.outcome.result? patience (some clock) (some stepped.scheduler)
    return true
  | none =>
    -- hang guard: the job's end, on its outcome.
    return (← Job.awaitWithin patience handle.outcome.result?).isSome

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
    (keys : Loop.Keys TestScheme.scheme) (jobs : Array Config.JobRegistration)
    (journal : Restore.Order → IO Unit := fun _ => pure ()) :
    IO (Option (Loop TestScheme.scheme × RealTexts)) := do
  if depth == 0 then
    return none
  let mut loop := stepped.loop
  let mut texts := texts
  -- The journal's orders, handed on as a host hands them, and the snapshots
  -- they name released after.
  for order in stepped.journal do
    journal order
  for id in stepped.journal.filterMap (·.release) do
    let releasing : EditorM Unit :=
      discard <| (observing (TextSource.snapshot id).release : TextM _)
    texts := (← releasing.runReal texts rig.display).2
  for invocation in stepped.answered do
    let (next, after) ← (loop.invoke keys invocation).runReal texts rig.display
    let .ok next := next | return none
    let some (settled, after) ←
      settleProjects rig after next (depth - 1) keys jobs journal | return none
    loop := settled
    texts := after
  for start in stepped.starts do
    let some work :=
      (jobs.find? (·.name == start.name)).map
        (·.workWith keys.registered.extensions start.arguments) | return none
    let posts ← IO.mkRef (#[] : Array Invocation)
    let handle ←
      Job.spawn rig.services work (pure ()) fun invocation => posts.modify (·.push invocation)
    -- A job that hangs is cancelled and the settling fails.
    unless ← rig.ran handle do
      handle.cancel
      return none
    let label := s!"job {start.name}"
    for invocation in ← posts.get do
      let (next, after) ← (loop.deliver keys label (runPosted invocation)).runReal texts rig.display
      let .ok next := next | return none
      let some (settled, after) ←
        settleProjects rig after next (depth - 1) keys jobs journal | return none
      loop := settled
      texts := after
    let some (.finished command) ← handle.outcome? | return none
    let (next, after) ←
      Job.finishWith rig.held handle (loop.deliver keys label command) texts rig.display
    let .ok next := next | return none
    let some (settled, after) ←
      settleProjects rig after next (depth - 1) keys jobs journal | return none
    loop := settled
    texts := after
  return some (loop, texts)

/-- `loop`, over `texts`, once each of `invocations` has run with `keys` and
settled with `jobs` (`settleProjects`), in order. -/
def runSettledFrom (rig : ProjectRig) (loop : Loop TestScheme.scheme) (texts : RealTexts)
    (invocations : List Invocation) (keys : Loop.Keys TestScheme.scheme)
    (jobs : Array Config.JobRegistration) (journal : Restore.Order → IO Unit := fun _ => pure ()) :
    IO (Option (Loop TestScheme.scheme × RealTexts)) := do
  let mut loop := loop
  let mut texts := texts
  for invocation in invocations do
    let (stepped, after) ← (loop.invoke keys invocation).runReal texts rig.display
    let .ok stepped := stepped | return none
    let some (settled, after) ←
      settleProjects rig after stepped (keys := keys) (jobs := jobs) (journal :=
          journal) | return none
    loop := settled
    texts := after
  return some (loop, texts)

/-- The loop, with its working directory `base`, once each of
`invocations` has run with `keys` and settled with `jobs`
(`settleProjects`), in order. -/
def runSettled (rig : ProjectRig) (base : System.FilePath) (invocations : List Invocation)
    (keys : Loop.Keys TestScheme.scheme) (jobs : Array Config.JobRegistration) :
    IO (Option (Loop TestScheme.scheme × RealTexts)) := do
  let begin : EditorM (Loop TestScheme.scheme) := do
    let loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
    return { loop with state := { loop.state with workingDirectory := base } }
  let (started, texts) ← begin.runReal (RealTexts.over rig.published) rig.display
  let .ok loop := started | return none
  runSettledFrom rig loop texts invocations keys jobs

/-- The invocation that opens `path`. -/
def openFile (path : System.FilePath) : Invocation :=
  { command := FileJobs.openFileCommand, arguments := [.str path.toString] }

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
