import Editor.Config.Packages
import Editor.Config.Registry
import Editor.File.Model
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Loop
import Editor.Loop.Driver
import Editor.Package
import Editor.Test.Driver
import Editor.Test.Loop
import Editor.Test.Models

/-!
# The test kit: Hosted

The loop's driver over what a host would be handed: a list of packages
installed as a host installs them (`Config.State.ofPackages`), so the
driver's commands, jobs and extension points are the registry's. A command
run by name is the registry's entry of that name, a job's work is made from
the values registered at its extension point when it is started
(`JobRegistration.workWith`), and a command asking for an extension point's
values (`Extension.values`) is answered from the registry. It is what an
interface library's contract check runs an implementation's packages on,
beside a probe of its own, so a hook's values are seen to run.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import").
-/

namespace Editor.Test

open Editor

/-- The registry `packages` make, installed in order as a host installs
them; the refusals are dropped. -/
def hostedRegistry (packages : Array Package) : Config.Registry :=
  let (state, _) : Config.State Unit Unit × Array String := Config.State.ofPackages packages
  state.registry

/-- The keys of a driver hosted over `registry`, with `bindings`: each
command by name the registry's entry, and what the loop is told the
registry's. -/
def hostedKeys (registry : Config.Registry) (bindings : List (String × Invocation) := []) :
    Loop.Keys TestScheme.scheme :=
  { dispatchKeys
      bindings with
    command? := fun name =>
      (registry.find? name).bind fun entry =>
        match entry.registration.action with
        | .call run =>
          some fun call => do
            run call
            return none
        | .plain run =>
          some fun _ => do
            run
            return none
        | .store .. => none
    registered := registry.registered }

/-- A driver over the initial state with what `packages` register, installed
as a host installs them, `bindings` bound, and `files` as the files its
jobs reach; `none` if making the state was refused. -/
def hostedDriver (packages : Array Package) (bindings : List (String × Invocation) := [])
    (files : FileModel := {}) : Option TestDriver :=
  let registry := hostedRegistry packages
  let jobs (name : String) : Option (List Argument → Work) :=
    (registry.findJob? name).map (·.registration.workWith registry.extensionsAt)
  (Loop.Driver.over (hostedKeys registry bindings) jobs (EditorState.initial ⟨640, 480⟩)
        editorModel).toOption.map
    fun driver => { driver with jobs := { files } }

/-- `driver` once every job it holds, and every job their commands start,
is finished, oldest first, up to `depth` of them. -/
def hostedSettled (driver : TestDriver) (depth : Nat := 16) : TestDriver :=
  (List.range depth).foldl
    (fun driver _ =>
      match driver.pending[0]? with
      | some job => (driver.finish job.id).1
      | none => driver)
    driver

/-- `driver` once `invocation` has run as a step of its own, and every job it
started has settled (`hostedSettled`). -/
def hostedRan (driver : TestDriver) (invocation : Invocation) : TestDriver :=
  hostedSettled (driver.stepped (driver.loop.invoke driver.handed invocation)).1

/-- `keys` with the extension points answered as `packages`, installed as a
host installs them, register them: for a driver of handed commands and jobs
whose code reads an extension point (`Extension.values`), a hook's values
among them. -/
def withExtensionsOf {scheme : InputScheme} (keys : Loop.Keys scheme) (packages : Array Package) :
    Loop.Keys scheme :=
  { keys with
    registered := { keys.registered with extensions := (hostedRegistry packages).extensionsAt } }

end Editor.Test
