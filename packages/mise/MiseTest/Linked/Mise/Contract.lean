import Editor.Job
import Editor.Job.Contract
import Editor.Process
import Editor.Process.Environment
import Editor.RealHost
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Services
import EnvironmentApi
import EnvironmentApiTest.Contract
import Mise
import Mise.Compiled
import MiseTest.Check

/-!
# Linked tests: `Mise.lean` over the real process service

The tests of `Mise.lean` over the library's process service:
`miseContractChecks`, `environment-api`'s directory-source contract
(`EnvironmentApiTest.directoryContract`) with mise standing in as the
fixture under `tests/process-environment`, a check for each sentence; and
the checks beside it, which were the core's contract test's
(`ContractTest.environmentChecks`, `environmentFailures`) while mise was the
core's: a child gets each directory's fixture `PATH`, by its path and by a
bare name; a mise that sleeps past its limit is killed at it and reported
once; and the test process's environment is the same after them as before.
The linked test's root, `MiseTest/Linked.lean`, runs them; its module doc
says what each shows.

Each check works in a temporary directory of its own, into which the
fixture is copied, removed only once the process service has worked what
was handed to it (`Editor.Test.Linked.withFiles`); none sets a variable of
the test process or changes its working directory. That each child is
reaped is the process service's own contract, not pinned here.

It runs a port's contract against its real adapter, outside the rule of the
wiring set (`docs/dev-practices/real-thread-checks.md`): it declares
`.contract` because its root hands it the real services.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.MiseTest.Linked.Mise.Contract : Editor.WiringSet :=
  .contract
    "EnvironmentApi's directory-source contract against mise-shaped fixtures over the real process service"

namespace MiseTest.Linked

open Editor
open Editor.Test.Linked

/-- Copies the fixture script `name` under `fixtures` into `directory`,
executable, and gives its path there. -/
def copyFixture (fixtures directory : System.FilePath) (name : String) : IO System.FilePath := do
  let target := directory / name
  IO.FS.writeBinFile target (← IO.FS.readBinFile (fixtures / name))
  IO.setAccessRights target
      { user := { read := true, write := true, execution := true }
        group := { read := true, execution := true }
        other := { read := true, execution := true } }
  return target

/-- `services` whose jobs share environments over a state of their own, the
headless mode with a limit of `limit` milliseconds, with mise at `executable`
installed as config's `Mise.executable` installs it, over the package's
value, and which report into `said`. -/
def withMiseAt (services : Job.Services) (executable : System.FilePath) (limit : Nat)
    (said : IO.Ref (Array String)) : IO Job.Services := do
  let registered :=
    (EnvironmentApi.registered
        ((EnvironmentApiTest.registeredAt EnvironmentApi.DirectorySource Mise.package).push
          (Mise.at executable))
        #[] Process.inheritedName).1
  let state ← IO.mkRef (({ host := .headless, limit } : Process.Environments).install registered)
  return { services with
      environments := Job.sharedEnvironments state fun text => said.modify (·.push text) }

/-- Whether `job` finished with `true` over `services`. -/
def ranTrue (services : Job.Services) (job : JobM Bool) : IO Bool := do
  return (← runOnTimers services job) == .finished true

/-- A scene of the contract in a fresh directory of its own under `services`:
mise copied in from `fixtures`, `fixture-path` holding `path`, and
`fixture-fail` too when `fails`. -/
def scene (services : Job.Services) (fixtures : System.FilePath) (path : String) (fails : Bool)
    (check : EnvironmentApiTest.DirectoryScene → IO Bool) : IO Bool :=
  Editor.Test.Linked.withFiles services (targets := [.processes]) fun directory => do
    let executable ← copyFixture fixtures directory "mise"
    IO.FS.writeFile (directory / "fixture-path") s!"{path}\n"
    if fails then
      IO.FS.writeFile (directory / "fixture-fail") ""
    let said ← IO.mkRef #[]
    let services ← withMiseAt services executable 1000 said
    check {
          directory, run := ranTrue services, said := said.get
          reanswer := fun path => IO.FS.writeFile (directory / "fixture-path") s!"{path}\n"
          restamp := IO.FS.writeFile (directory / Mise.stampNames[0]!) "" }

/-- The contract's rig over the real process service, with mise standing in
as the fixture under `fixtures` (`tests/process-environment`): its failing
scene's lookup exits 1, saying `mise fixture: failing here`. -/
def realDirectoryRig (services : Job.Services) (fixtures : System.FilePath) :
    EnvironmentApiTest.DirectoryRig :=
  { answering := fun path check => scene services fixtures path false check
    failing := fun check =>
      scene services fixtures EnvironmentApiTest.firstPath true fun scene =>
        check scene (.exited 1 "mise fixture: failing here") }

/-- `environment-api`'s directory-source contract against the mise package
over the library's process service (`realDirectoryRig`), a check for each
sentence. -/
def miseContractChecks (services : Job.Services) (fixtures : System.FilePath) : List Check :=
  (EnvironmentApiTest.directoryContract Mise.package "mise"
        (realDirectoryRig services fixtures)).map
    fun (sentence, holds) =>
    { name := s!"mise over the real process service: {sentence}", run := holds }

/-- The standard output of `command` run through `services`, as text; a
refusal, a status other than 0 or output that is not UTF-8 fails the job. -/
def outputOf (command : Process.Command) : JobM String := do
  let ran ← JobContract.ranOk command
  unless ran.exit == .code 0 do
    throw s!"{command.program} ended with {repr ran.exit}"
  let some text := String.fromUTF8? ran.stdout | throw s!"{command.program} wrote what is not UTF-8"
  return text

/-- A temporary directory of its own for `check`, holding the file
`fixture-path` with the line `<directory>/tools:/usr/bin:/bin`, the `PATH`
the mise fixture prints there; removed afterwards, whatever happened, once
the process service of `services` has ended every child it ran there
(`Editor.Test.Linked.withFiles`). -/
def withFixturePath (services : Job.Services) (check : System.FilePath → String → IO Bool) :
    IO Bool := do
  Editor.Test.Linked.withFiles services (targets := [.processes]) fun directory => do
      let path := s!"{directory}/tools:/usr/bin:/bin"
      IO.FS.writeFile (directory / "fixture-path") s!"{path}\n"
      check directory path

/-- What `command` prints when a job runs it through `services`; `none`
when the job did not finish with it. -/
def printedThrough (services : Job.Services) (command : Process.Command) : IO (Option String) := do
  let handle ← Job.spawn services (reporting fun _ => outputOf command) (pure ())
  -- hang guard: the job's end, on its outcome.
  if (← Job.awaitWithin patience handle.outcome.result?).isNone then
    handle.cancel
    return none
  handle.settle
  match (← handle.outcome?).map texts with
  | some (.finished #[text]) =>
    return some text
  | _ =>
    return none

/-- The command that prints `PATH`, `program` (`printenv`) run in
`directory`. -/
def printenv (directory : System.FilePath) (program := "/usr/bin/printenv") : Process.Command :=
  { program, arguments := #["PATH"], directory }

/-- The checks beside the contract, over the library's process service with
mise standing in as the fixtures under `fixtures`. -/
def miseFixtureChecks (services : Job.Services) (fixtures : System.FilePath) : List Check :=
  [{  name :=
        "with mise standing in as a fixture, a child started in each of two directories, by its path and by a bare name, gets that directory's fixture PATH, and nothing is reported"
      run :=
        withFixturePath services fun first firstPath =>
          withFixturePath services fun second secondPath => do
            let executable ← copyFixture fixtures first "mise"
            let said ← IO.mkRef #[]
            let services ← withMiseAt services executable 1000 said
            let outcome ←
              runOnTimers services do
                  let byPath ← [first, second].mapM fun directory => outputOf (printenv directory)
                  let bare ←
                    [first, second].mapM fun directory => outputOf (printenv directory "printenv")
                  return byPath == [firstPath ++ "\n", secondPath ++ "\n"] && bare == byPath
            return outcome == .finished true && (← said.get).isEmpty },
    { name :=
        "with a mise that sleeps past a limit of 1 s, the lookup is killed at its limit and not before it, the child gets the inherited environment, and the timeout is reported once"
      run :=
        withFixturePath services fun directory _ => do
          let some inherited ← printedThrough services (printenv directory) | return false
          let executable ← copyFixture fixtures directory "slow-mise"
          let said ← IO.mkRef #[]
          let services ← withMiseAt services executable 1000 said
          let outcome ←
            runOnTimers services do
                -- The lookup starts after this reading.
                let start ← now
                let path ← outputOf (printenv directory)
                let ended ← now
                -- real time under test: the 1 s limit is not cut short, a lower
                -- bound load only makes surer. That the limit fired is the
                -- timeout reported; how soon after is bounded only by the
                -- job's hang guard (`runOnTimers`).
                return ended - start >= 1000 && path == inherited
          return outcome == .finished true &&
              (← said.get) ==
                #[Process.failureMessage (.directory directory "mise") (.timedOut 1000)] }]

/-- The contract's checks and those beside it, then one more: the
environment a child of the test process gets is the same after a mise
lookup as before it (`/usr/bin/env` run with nothing installed, in a
temporary directory, before and after a child that mise's lookup prepared). -/
def miseChecks (services : Job.Services) (fixtures : System.FilePath) : List Check :=
  let env (directory : System.FilePath) : Process.Command :=
    { program := "/usr/bin/env", directory }
  miseContractChecks services fixtures ++ miseFixtureChecks services fixtures ++
    [{  name := "the test process's environment after a mise lookup is what it was before it"
        run :=
          withFixturePath services fun directory path => do
            let before ← printedThrough services (env directory)
            let executable ← copyFixture fixtures directory "mise"
            let said ← IO.mkRef #[]
            let looked ← withMiseAt services executable 1000 said
            let printed ←
              runOnTimers looked do
                  return (← outputOf (printenv directory)) == path ++ "\n"
            let after ← printedThrough services (env directory)
            return printed == .finished true && before.isSome && before == after }]

end MiseTest.Linked
