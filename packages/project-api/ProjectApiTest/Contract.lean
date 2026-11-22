import Editor.Config.Packages
import Editor.Extension
import Editor.Test.Hosted
import ProjectApi

/-!
# The contract check of `project-api`

What every implementation of the interface library `project-api`
(`ProjectApi.lean`) runs over its package, in two parts.

- **What it registers**, collected with the pure collector
  (`Package.registered`): a command under each name the interface declares,
  a job under each job name, and a `ProjectApi.Workspaces` value under the
  implementation's name, `workspace`.
- **What it does**, on the loop's driver over the models with the package
  installed as a host installs it beside a probe of the interface's own
  (`Editor.Test.hostedDriver`, `probe`), whose continuation's find job is
  registered over the point (`Extension.workJob`): reaching a path ends, once
  every job is settled, in exactly one of the continuation's two outcomes,
  reached with the arguments it carried on its order or its gone sentence;
  and reaching it again answers from the table at once, starting no job.

It is a list of sentences, each with whether it holds, as the fixture
interface package `greeting-api`'s (`tests/packages/greeting-api`).
-/

namespace ProjectApiTest

open Editor
open Editor.Test
open Editor.Workspace

/-- The probe's continuation: its find runs under `probe-find`, and what it
reaches, or that a path is gone, it says in the echo area, with what its
order carried. -/
def probeContinuation : Reach.Continuation :=
  { job := "probe-find", name := "probe", gone := fun path => s!"probe: {path} is gone"
    reached := fun order location =>
      message s!"probe: reached {location.describe} carrying {repr order.carried}" }

/-- The probe: its continuation's find job over the point, and `probe-reach`,
which reaches `/p` through the implementation's `Workspaces` value, carrying
`b`. -/
def probe : Package :=
  { name := "project-api-probe"
    setup := do
      Extension.workJob ProjectApi.Workspaces probeContinuation.job fun values =>
          ProjectApi.workOver values probeContinuation
      commandWith "probe-reach" fun call => do
          let some workspaces ← ProjectApi.workspaces? | message "no workspace implementation"
          workspaces.reach probeContinuation "/p" "git" call.target.window.id [.str "b"] }

/-- The checks of the contract over `package`, each with what must hold as a
sentence. -/
def contractChecks (package : Package) : List (String × Bool) :=
  let registered := Package.registered package
  let commands := registered.commands.map (·.name)
  let jobs := registered.jobs.map (·.name)
  let values : Array ProjectApi.Workspaces :=
    registered.extensions.filterMap fun (key, value) =>
      if key == TypeName.typeName ProjectApi.Workspaces then value.get? ProjectApi.Workspaces
      else none
  let reached :=
    (hostedDriver #[package, probe]).map fun driver => hostedRan driver { command := "probe-reach" }
  let outcome (driver : TestDriver) : Bool :=
    let echo := driver.loop.state.echo
    (echo.startsWith "probe: reached " &&
        echo.endsWith s!"carrying {repr ([.str "b"] : List Argument)}") ||
      echo == "probe: /p is gone"
  (ProjectApi.names.toList.map fun name =>
      (s!"`{package.name}` registers a command under `{name}`, a name `project-api` declares",
        commands.contains name)) ++
    (ProjectApi.jobs.toList.map fun name =>
      (s!"`{package.name}` registers a job under `{name}`, a job name `project-api` declares",
        jobs.contains name)) ++
    [(s!"`{package.name}` registers a `ProjectApi.Workspaces` value named `{ProjectApi.implementationName}`",
        values.any (·.name == ProjectApi.implementationName)),
      (s!"reaching a path through `{package.name}`'s `ProjectApi.Workspaces` value ends, once every job is settled, in exactly one of the continuation's outcomes: reached, with the arguments it carried, or its gone sentence",
        reached.any outcome),
      (s!"reaching the path again through `{package.name}`'s value answers from the table at once, with the same outcome and no job started",
        match reached with
        | some first =>
          let (again, _) :=
            fedTo
              { first with
                loop := { first.loop with state := { first.loop.state with echo := "" } } }
              []
          let stepped :=
            (again.stepped (again.loop.invoke again.handed { command := "probe-reach" })).1
          outcome stepped && stepped.pending.isEmpty &&
            stepped.loop.state.echo == first.loop.state.echo
        | none => false)]

end ProjectApiTest
