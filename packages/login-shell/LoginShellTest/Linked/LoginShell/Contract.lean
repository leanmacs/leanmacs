import Editor.Job
import Editor.Job.Runner
import Editor.Process.Environment
import Editor.RealHost
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Services
import EnvironmentApi
import EnvironmentApiTest.Contract
import LoginShell
import LoginShell.Compiled
import LoginShellTest.Check

/-!
# Linked tests: `LoginShell.lean` over the real process service

`loginShellContractChecks`, `environment-api`'s base contract
(`EnvironmentApiTest.baseContract`) against the package's login shell over
the library's process service, with a login shell standing in as the
fixture under `tests/login-shell`, a check for each sentence. B2 is the
phase's criterion 3: the base's variables are exactly the `PATH` the
fixture profile sets, since the fixture shell clears its environment and
the parser drops the shell's per-session variables, and the noise the
fixture prints outside the markers is ignored. That a child gets the
environment it was prepared with is the job port's process contract's
(`JobContract.processProperties`, run by `contract-test`), not pinned here.
The linked test's root, `LoginShellTest/Linked.lean`, runs them.

Each check works in a temporary directory of its own, the scene's home,
into which the fixture is copied and the profile written, removed only once
the process service has worked what was handed to it
(`Editor.Test.Linked.withFiles`); none sets a variable of the test process
or changes its working directory, and none runs the user's own shell.

It runs a port's contract against its real adapter, outside the rule of the
wiring set (`docs/dev-practices/real-thread-checks.md`): it declares
`.contract` because its root hands it the real services.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.LoginShellTest.Linked.LoginShell.Contract : Editor.WiringSet :=
  .contract
    "EnvironmentApi's base-source contract against a fixture login shell over the real process service"

namespace LoginShellTest.Linked

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

/-- Writes the profile the fixture shell sources in `directory`: a line of
noise, then `PATH` set to `path` and exported. -/
def writeProfile (directory : System.FilePath) (path : String) : IO Unit :=
  IO.FS.writeFile (directory / "profile") s!"echo profile-noise\nPATH='{path}'\nexport PATH\n"

/-- `services` whose jobs share environments over `state`, which report into
`said`. -/
def sharing (services : Job.Services) (state : IO.Ref Process.Environments)
    (said : IO.Ref (Array String)) : Job.Services :=
  { services with
    environments := Job.sharedEnvironments state fun text => said.modify (·.push text) }

/-- Whether `job` finished with `true` over `services`. -/
def ranTrue (services : Job.Services) (job : JobM Bool) : IO Bool := do
  return (← runOnTimers services job) == .finished true

/-- A scene of the contract in a fresh directory of its own under
`services`, the scene's home: the fixture shell copied in from `fixtures`,
`profile` setting `PATH` to `path`, a directory `other` in it, and
`fixture-fail` too when `fails`. Its environments are the headless mode's,
with the package's base and the login shell at the fixture shell, looked up
in the home, after it, as config's value would be: chosen by its name. -/
def scene (services : Job.Services) (fixtures : System.FilePath) (path : String) (fails : Bool)
    (check : EnvironmentApiTest.BaseScene → IO Bool) : IO Bool :=
  Editor.Test.Linked.withFiles services (targets := [.processes]) fun directory => do
    let shell ← copyFixture fixtures directory "shell"
    writeProfile directory path
    let other := directory / "other"
    IO.FS.createDir other
    if fails then
      IO.FS.writeFile (directory / "fixture-fail") ""
    let registered :=
      (EnvironmentApi.registered #[]
          ((EnvironmentApiTest.registeredAt EnvironmentApi.BaseSource LoginShell.package).push
            (LoginShell.at shell directory))
          LoginShell.name).1
    let state ← IO.mkRef (({ host := .headless } : Process.Environments).install registered)
    let said ← IO.mkRef #[]
    check {
          directory, other, run := ranTrue (sharing services state said), said := said.get
          reanswer := writeProfile directory
          reinstall := state.modify (·.install registered) }

/-- The contract's rig over the real process service, with a login shell
standing in as the fixture under `fixtures` (`tests/login-shell`): its
failing scene's shell exits 1, saying `login-shell fixture: failing
here`. -/
def realBaseRig (services : Job.Services) (fixtures : System.FilePath) :
    EnvironmentApiTest.BaseRig :=
  { answering := fun path check => scene services fixtures path false check
    failing := fun check =>
      scene services fixtures EnvironmentApiTest.firstPath true fun scene =>
        check scene (.exited 1 "login-shell fixture: failing here") }

/-- `environment-api`'s base contract against the login-shell package over
the library's process service (`realBaseRig`), a check for each sentence. -/
def loginShellContractChecks (services : Job.Services) (fixtures : System.FilePath) : List Check :=
  (EnvironmentApiTest.baseContract LoginShell.package LoginShell.name
        (realBaseRig services fixtures)).map
    fun (sentence, holds) =>
    { name := s!"the login shell over the real process service: {sentence}", run := holds }

end LoginShellTest.Linked
