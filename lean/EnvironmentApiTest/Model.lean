import Editor.File.Model
import Editor.Job
import Editor.Job.Model
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import EnvironmentApi
import EnvironmentApiTest.Contract

/-!
# The model rigs of `environment-api`

The contract's rigs on the job model (`EnvironmentApiTest.Contract`): each
scene is a `JobModel` behind a reference, carried from job to job and run
with `JobM.runModel`, with the source's lookup scripted in a made-up
directory and its environments installed from the source as a host
installs it (`EnvironmentApi.registered`). No thread, no clock, no file. A
package's model tests run the contract on them, as this library's run it on
its fakes (`ModelTest.environmentApiChecks`).

With them, the small helpers the core's and a package's model checks of a
child's environment share: `printed`, `requestsOf`, `runsOn` and `after`.
-/

namespace EnvironmentApiTest

open Editor

/-- A run that ends with the status 0 and prints `stdout`. -/
def printed (stdout : String) : Except ProcessError Process.Ran :=
  .ok { exit := .code 0, stdout := stdout.toUTF8, stderr := .empty }

/-- The requests `job` makes when it runs against the job port's model from
`model`, in order. -/
def requestsOf {α : Type} (job : JobM α) (model : JobModel) : Array JobRequest :=
  go 10000 job.run model #[]
where
  /-- The requests of `program` from `model`, with `fuel` steps at most. -/
  go : Nat → Program jobPort (Except String α) → JobModel → Array JobRequest → Array JobRequest
    | 0, _, _, seen => seen
    | _, .done _, _, seen => seen
    | fuel + 1, .step request next, model, seen =>
      let (reply, after) := JobModel.handle request model
      go fuel (next reply) after (seen.push request)

/-- A run of `command` that the model answers. -/
def runsOn (command : Process.Command) : JobM Bool := do
  return (← Process.run command 1000) matches .ok _

/-- Runs `job` on the model, and gives the model after it. -/
def after {α : Type} (job : JobM α) (model : JobModel) : JobModel :=
  (job.runModel model).2

/-- The directory a model scene's commands start in. -/
def sceneDirectory : System.FilePath :=
  "/rig/d"

/-- Another directory of a model scene. -/
def otherDirectory : System.FilePath :=
  "/rig/e"

/-- The failure a model scene's failing lookup comes to. -/
def modelFailure : Process.Failure :=
  .exited 1 "fake failing here"

/-- What a model scene's failing lookup answers: `modelFailure`. -/
def failingRun : Except ProcessError Process.Ran :=
  .ok { exit := .code 1, stdout := .empty, stderr := "fake failing here\n".toUTF8 }

/-- The executable `program` names on a model scene, and the files that
make it the one found: its path, or the first candidate, which the model
then holds. -/
def executableOf : Process.Program → System.FilePath × FileModel
  | .at path => (path, ({} : FileModel))
  | .firstOf candidates _ =>
    let first : System.FilePath := candidates[0]?.getD "/rig/no-candidate"
    (first, ({} : FileModel).withFile first "x".toUTF8)

/-- `model` with each script of `command` answering `reply` instead. -/
def reanswered (model : JobModel) (command : Process.Command)
    (reply : Except ProcessError Process.Ran) : JobModel :=
  { model with
    processes :=
      { model.processes with
        scripts :=
          model.processes.scripts.map fun script =>
            if script.command == command then { script with reply } else script } }

/-- Runs `job` on the model behind `state`, keeping the model after it, and
whether it finished with `true`. -/
def runOn (state : IO.Ref JobModel) (job : JobM Bool) : IO Bool := do
  let (outcome, model) := job.runModel (← state.get)
  state.set model
  return outcome == .finished true

/-- A directory rig on the job model over `source` in the mode `host`, whose
lookup prints the variables it is to set as `encode` writes them. The lookup
of a scene runs in `sceneDirectory`, over the inherited base. A source that
gives none in the mode has no scene, and every check run on it fails. -/
def modelDirectoryRig (source : EnvironmentApi.DirectorySource) (host : Process.Host)
    (encode : Array (String × String) → String) : DirectoryRig :=
  let scene (reply : Except ProcessError Process.Ran) : Option (IO (IO.Ref JobModel × Process.Command)) :=
    (source.source host).map fun resolved => do
      let (executable, files) := executableOf resolved.program
      let lookup := resolved.command executable sceneDirectory {}
      let environments :=
        ({ host } : Process.Environments).install
          (EnvironmentApi.registered #[source] #[] Process.inheritedName).1
      let state ← IO.mkRef ({ files, processes := { scripts := #[{ command := lookup, reply }] }, environments } : JobModel)
      return (state, lookup)
  let stampOf : Option System.FilePath :=
    ((source.source host).bind fun resolved => resolved.stampNames[0]?).map
      (Process.inDirectory sceneDirectory)
  let sceneOf (state : IO.Ref JobModel) (lookup : Process.Command) : DirectoryScene :=
    { directory := sceneDirectory, run := runOn state
      said := return (← state.get).reported
      reanswer := fun path =>
        state.modify (reanswered · lookup (printed (encode #[("PATH", path)])))
      restamp :=
        if let some stamp := stampOf then
          state.modify fun model => { model with files := model.files.withFile stamp "restamped".toUTF8 }
        else pure () }
  { answering := fun path check => do
      let some made := scene (printed (encode #[("PATH", path)])) | return false
      let (state, lookup) ← made
      check (sceneOf state lookup)
    failing := fun check => do
      let some made := scene failingRun | return false
      let (state, lookup) ← made
      check (sceneOf state lookup) modelFailure }

/-- A base rig on the job model over `base` in the mode `host`, chosen by its
name, whose lookup prints the variables it is to set as `encode` writes
them. A base that looks nothing up in the mode has no scene, and every check
run on it fails. -/
def modelBaseRig (base : EnvironmentApi.BaseSource) (host : Process.Host)
    (encode : Array (String × String) → String) : BaseRig :=
  let registered := (EnvironmentApi.registered #[] #[base] base.name).1
  let scene (reply : Except ProcessError Process.Ran) : Option (IO (IO.Ref JobModel × Process.Command)) :=
    match base.base host with
    | .inherited => none
    | .lookup resolved directory =>
      some do
        let (executable, files) := executableOf resolved.program
        let lookup := resolved.command executable directory {}
        let environments := ({ host } : Process.Environments).install registered
        let state ← IO.mkRef ({ files, processes := { scripts := #[{ command := lookup, reply }] }, environments } : JobModel)
        return (state, lookup)
  let sceneOf (state : IO.Ref JobModel) (lookup : Process.Command) : BaseScene :=
    { directory := sceneDirectory, other := otherDirectory, run := runOn state
      said := return (← state.get).reported
      reanswer := fun path =>
        state.modify (reanswered · lookup (printed (encode #[("PATH", path)])))
      reinstall :=
        state.modify fun model =>
          { model with environments := model.environments.install registered } }
  { answering := fun path check => do
      let some made := scene (printed (encode #[("PATH", path)])) | return false
      let (state, lookup) ← made
      check (sceneOf state lookup)
    failing := fun check => do
      let some made := scene failingRun | return false
      let (state, lookup) ← made
      check (sceneOf state lookup) modelFailure }

end EnvironmentApiTest
