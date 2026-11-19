import Editor.Api
import Editor.Command.Call
import Editor.Job
import Editor.Job.Model
import Editor.Workspace.Model
import Editor.Workspace.Reach
import ModelTest.Check
import ModelTest.Support.Driver
import ModelTest.Support.Keys
import ModelTest.Support.Loop
import ModelTest.Support.Workspace

/-!
# Model tests: `Editor/Workspace/Reach.lean`

The model tests of `Editor/Workspace/Reach.lean`: `reachChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

namespace ReachTest

/-- The name of the probe's find job. -/
def probeJob : String :=
  "probe-find"

/-- The continuation of the checks: its find runs under `probe-find`, its
refusals and its gone sentence are said under `probe`, and what it reaches it
says in the echo area, with the order's path and view. -/
def probe : Workspace.Reach.Continuation :=
  { job := probeJob, name := "probe", gone := fun path => s!"probe: {path} is gone"
    reached := fun order location =>
      message s!"probe: reached {location.describe} for {order.path} in view {order.view.index}" }

/-- The jobs of the checks: the workspace driver's and the probe's find. -/
def jobs (name : String) : Option (List Argument → Work) :=
  if name == probeJob then some (Workspace.Reach.work probe) else workspaceJobs name

/-- The commands of the checks: `reach-w`, `reach-x` and `reach-r` reach `/w`,
`/x` and `/r` through the probe, from the window's view. -/
def commands : List (String × Dispatched) :=
  workspaceCommands ++
    [("/w", "reach-w"), ("/x", "reach-x"), ("/r", "reach-r")].map fun (path, name) =>
      (name, fun call => do
        Workspace.Reach.reach probe path "git" call.target.window.id
        return none)

/-- The keys of the checks: the workspace driver's, and `C-r w`, `C-r x` and
`C-r r` (`commands`). -/
def keys : Loop.Keys TestScheme.scheme :=
  dispatchKeys
    (workspaceBindings ++
      [("C-r w", invoke "reach-w"), ("C-r x", invoke "reach-x"), ("C-r r", invoke "reach-r")])
    commands

/-- The driver of the checks: the workspace driver's with the jobs
`registered`, and the finder scripted in `/w`, `/x` and `/r`. -/
def driver (registered : String → Option (List Argument → Work) := jobs) : Option TestDriver :=
  (workspaceDriver registered keys).map fun driver =>
    let extra := (workspaceWorld.jobModel "git" #["/w", "/x", "/r"]).processes.scripts
    { driver with
      jobs :=
        { driver.jobs with
          processes :=
            { driver.jobs.processes with scripts := driver.jobs.processes.scripts ++ extra } } }

/-- How many times `driver` ran the finder's first git command in
`directory`. -/
def finds (driver : TestDriver) (directory : System.FilePath) : Nat :=
  (driver.jobs.processes.started.filter (· == Workspace.Git.revParseCommand "git" directory)).size

end ReachTest

open ReachTest in
/-- The checks of reaching the workspace at a path
(`Editor/Workspace/Reach.lean`), on the loop's driver over the editor's
models and the job model of `workspaceWorld`, with a probe continuation that
says what it reached. -/
def reachChecks : List Check :=
  [{  name :=
        "a path the table has no answer for starts the continuation's find job, records the finder's answer, its workspace and its cache, then hands the continuation the root found, with the order's path and the asking view"
      run :=
        pure <|
          match driver with
          | none => false
          | some driver =>
            let reached := settledAfter driver "C-r w"
            let table := reached.loop.state.workspaces
            reached.loop.state.echo == "probe: reached local /w for /w in view 0" &&
              finds reached "/w" == 1 &&
              (table.workspace? (.local "/w")).map (·.branch) == some (some (.named "feature")) &&
              table.cached? "/w" 0 == some (some (.local "/w")) },
    { name :=
        "a path the table caches under the generation goes to the continuation at once: no job starts and the finder does not run again"
      run :=
        pure <|
          match driver with
          | none => false
          | some driver =>
            let first := settledAfter driver "C-r w"
            let cleared :=
              { first with
                loop := { first.loop with state := { first.loop.state with echo := "" } } }
            let (again, _) := fedTo cleared (presses "C-r w")
            again.loop.state.echo == "probe: reached local /w for /w in view 0" &&
              again.pending.size == 0 &&
              finds again "/w" == 1 },
    { name :=
        "a path in no repository is said by the continuation's gone sentence, and the miss is cached, so a second reach says it with no find"
      run :=
        pure <|
          match driver with
          | none => false
          | some driver =>
            let first := settledAfter driver "C-r x"
            let (again, _) := fedTo first (presses "C-r x")
            first.loop.state.echo == "probe: /x is gone" &&
              first.loop.state.workspaces.cached? "/x" 0 == some none &&
              again.loop.state.echo == "probe: /x is gone" &&
              again.pending.size == 0 &&
              finds again "/x" == 1 },
    { name :=
        "a find job the host does not register is said under the continuation's name, and runs no process"
      run :=
        pure <|
          match driver workspaceJobs with
          | none => false
          | some driver =>
            let refused := settledAfter driver "C-r r"
            refused.loop.state.echo.startsWith "probe: " &&
              refused.loop.state.echo != "probe: reached local /r for /r in view 0" &&
              refused.jobs.processes.started.isEmpty },
    { name :=
        "an order crosses as arguments and back, its roots with and without a project, and arguments that are no order read as none; the work started with them fails, naming the continuation's job"
      run :=
        let orders : List Workspace.Reach.Order :=
          [{ path := "/u", git := "git", generation := 0, view := ⟨0⟩ },
            { path := "/a b/é", git := "/usr/bin/git", generation := 3, view := ⟨2⟩
              roots := #[{ root := "/c", project := some "c" }, { root := "/e" }] }]
        let failed :=
          match ((Workspace.Reach.work probe [.nat 1] ()).runModel {}).1 with
          | .failed said => some said
          | _ => none
        pure
          (orders.all
              (fun order => Workspace.Reach.Order.ofArguments? order.arguments == some order) &&
            [[], [.str "/u"], [.str "/u", .str "git", .nat 0, .nat 1, .str "/t"]].all
              (Workspace.Reach.Order.ofArguments? · == none) &&
            failed.map (·.startsWith s!"{probeJob}: ") == some true) }]

end ModelTest
