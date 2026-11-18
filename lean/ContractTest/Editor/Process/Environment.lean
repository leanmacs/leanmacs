import ContractTest.Check
import ContractTest.Support.Jobs
import Editor.Command
import Editor.Ffi.Processes
import Editor.Invocation
import Editor.Job
import Editor.Job.Contract
import Editor.Job.Runner
import Editor.Process
import Editor.Process.Environment
import Editor.Program

/-!
# Contract tests: `Editor/Process/Environment.lean`

The tests of `Editor/Process/Environment.lean`: `environmentChecks` and
`environmentFailures`, a child's environment over the real process service. The
root module `ContractTest` runs them; its module doc says what each shows.
-/

namespace ContractTest

open Editor

/-! ## A child's environment over the real process service -/

/-- The standard output of `command` run through `services`, as text; a
refusal, a status other than 0 or output that is not UTF-8 fails the job. -/
def outputOf (command : Process.Command) : JobM String := do
  let ran ← JobContract.ranOk command
  unless ran.exit == .code 0 do
    throw s!"{command.program} ended with {repr ran.exit}"
  let some text := String.fromUTF8? ran.stdout | throw s!"{command.program} wrote what is not UTF-8"
  return text

/-- `services` whose jobs share environments over a state of their own with
`setting`, the headless mode and a limit of `limit` milliseconds, which
report into `said`. -/
def withEnvironment (services : Job.Services) (setting : Process.Setting) (limit : Nat)
    (said : IO.Ref (Array String)) : IO Job.Services := do
  let state ← IO.mkRef ({ setting, host := .headless, limit } : Process.Environments)
  return { services with
      environments := Job.sharedEnvironments state fun text => said.modify (·.push text) }

/-- A temporary directory of its own for `check`, holding the file
`fixture-path` with the line `<directory>/tools:/usr/bin:/bin`, the `PATH`
the mise fixture prints there; removed afterwards, whatever happened. -/
def withFixturePath (check : System.FilePath → String → IO Bool) : IO Bool := do
  let directory ← IO.FS.createTempDir
  try
    let path := s!"{directory}/tools:/usr/bin:/bin"
    IO.FS.writeFile (directory / "fixture-path") s!"{path}\n"
    check directory path
  finally
    IO.FS.removeDirAll directory

/-- What `command` prints when a job runs it through `services`; `none`
when the job did not finish with it. -/
def printedThrough (services : Job.Services) (command : Process.Command) : IO (Option String) := do
  let handle ← Job.spawn services (reporting fun _ => outputOf command) (pure ())
  unless ← eventually handle.ended do
    handle.cancel
    return none
  handle.settle
  match (← handle.outcome?).map texts with
  | some (.finished #[text]) =>
    return some text
  | _ =>
    return none

/-- What the job port shows only over the real process service: the lookup
of a child's environment with mise standing in as the fixtures under
`fixtures` (`tests/process-environment`). Each check works in temporary
directories of its own, which it removes, and none sets a variable of the
test process or changes its working directory. -/
def environmentChecks (services : Job.Services) (fixtures : System.FilePath) : List Check :=
  let printenv (directory : System.FilePath) (program := "/usr/bin/printenv") : Process.Command :=
    { program, arguments := #["PATH"], directory }
  [{  name :=
        "with mise standing in as a fixture, a child started in each of two directories, by its path and by a bare name, gets that directory's fixture PATH, and nothing is reported"
      run :=
        withFixturePath fun first firstPath =>
          withFixturePath fun second secondPath => do
            let said ← IO.mkRef #[]
            let services ← withEnvironment services (.mise (some (fixtures / "mise"))) 1000 said
            let before ← Ffi.processesPending
            let outcome ←
              runOnTimers services do
                  let byPath ← [first, second].mapM fun directory => outputOf (printenv directory)
                  let bare ←
                    [first, second].mapM fun directory => outputOf (printenv directory "printenv")
                  return byPath == [firstPath ++ "\n", secondPath ++ "\n"] && bare == byPath
            let reaped ← eventually (return (← Ffi.processesPending) == before)
            return outcome == .finished true && (← said.get).isEmpty && reaped },
    { name :=
        "with a mise that sleeps past a limit of 1 s, the lookup is killed within 2 s of its start, its group reaped, the child gets the inherited environment, and the timeout is reported once"
      run :=
        withFixturePath fun directory _ => do
          let some inherited ← printedThrough services (printenv directory) | return false
          let said ← IO.mkRef #[]
          let services ← withEnvironment services (.mise (some (fixtures / "slow-mise"))) 1000 said
          let before ← Ffi.processesPending
          let outcome ←
            runOnTimers services do
                -- The lookup starts after this reading.
                let start ← now
                let path ← outputOf (printenv directory)
                let ended ← now
                return ended - start < 2000 && path == inherited
          let reaped ← eventually (return (← Ffi.processesPending) == before)
          return outcome == .finished true &&
              (← said.get) == #[Process.failureMessage directory (.timedOut 1000)] &&
              reaped }]

/-- The names of the environment checks that fail over the real process
service, and, when the environment a child of the test process gets is not
the same after them as before, that: `/usr/bin/env` run with the inherited
setting, in a temporary directory, before the first and after the last. -/
def environmentFailures (services : Job.Services) (fixtures : System.FilePath) : IO (List String) :=
  do
  let env (directory : System.FilePath) : Process.Command :=
    { program := "/usr/bin/env", directory }
  let directory ← IO.FS.createTempDir
  try
    let before ← printedThrough services (env directory)
    let failed ← checkFailures (environmentChecks services fixtures)
    let after ← printedThrough services (env directory)
    return failed ++
        if before.isSome && before == after then []
        else
          ["the test process's environment after the environment checks is what it was before them"]
  finally
    IO.FS.removeDirAll directory

end ContractTest
