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

/-- `registry` with what config owns replaced by what `config` registers,
as a reload that installs replaces it (`Config.Registry.replaceOwned`):
config's commands, bindings and the rest, and its values at extension
points. A `config` that is refused installs nothing and leaves `registry`
as it was, as a rejected reload does. -/
def hostedReloaded (registry : Config.Registry) (config : SetupM Unit) : Config.Registry :=
  match Config.Registrations.ofSetup config with
  | .ok registrations => registry.replaceOwned .config registrations
  | .error _ => registry

/-- The registry `packages` make, installed in order as a host installs
them, and then `config`, when it registers anything, installed for config
as a reload installs what config owns (`Config.Registry.replaceOwned`); the
refusals are dropped, and a `config` that is refused installs nothing. -/
def hostedRegistry (packages : Array Package) (config : SetupM Unit := pure ()) : Config.Registry :=
  let (state, _) : Config.State Unit Unit × Array String := Config.State.ofPackages packages
  hostedReloaded state.registry config

/-- The message `setup` is refused with, a package's or config's, if it is:
the one it threw, or what is wrong with what it registered
(`Config.Registrations.ofSetup`). -/
def hostedRefusal (setup : SetupM Unit) : Option String :=
  match Config.Registrations.ofSetup setup with
  | .error message => some message
  | .ok _ => none

/-- What `command` answers when a loop told of `registry` dispatches it in a
state that holds nothing, run against the editor's model; `none` if it does
not finish. For a check of what a command reads of the registry, an
extension point's values among it. -/
def hostedAsked {α : Type} (registry : Config.Registry) (command : EditorM α) : Option α :=
  match ((command.dispatched registry.registered EditorState.none).runModel editorModel).1 with
  | .ok (.finished answer, _) => some answer
  | _ => none

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

/-- `keys` with nothing registered at the extension point of `α`, the other
points answered as before: a set with no implementation of an interface,
for the checks of what a caller does when there is none. -/
def withoutExtension {scheme : InputScheme} (α : Type) [TypeName α] (keys : Loop.Keys scheme) :
    Loop.Keys scheme :=
  { keys with
    registered :=
      { keys.registered with
        extensions := fun key =>
          if key == TypeName.typeName α then #[] else keys.registered.extensions key } }

end Editor.Test
