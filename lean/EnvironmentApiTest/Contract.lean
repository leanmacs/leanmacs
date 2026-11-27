import Editor.Config.Packages
import Editor.Job
import Editor.Package
import Editor.Process.Environment
import EnvironmentApi

/-!
# The contract check of `environment-api`

What every source registered at the interface library `environment-api`'s
extension points (`EnvironmentApi.lean`) runs: a list of sentences, each
with whether it holds, as `files-api`'s and the fixture interface package
`greeting-api`'s are. It runs over a **rig**, which hands each check a
**scene**: a fresh directory where the source's lookup answers as the check
asks, with environments every job of the scene shares, installed from the
source as a host installs it (`EnvironmentApi.registered`). The model rigs
(`EnvironmentApiTest.Model`) script the lookup on the job model; a real
source's linked test gives a rig over the real process service, its
directories temporary and its own (mise's:
`MiseTest.Linked.Mise.Contract`).

## A directory source (`directoryContract`)

- D1: the package registers a `DirectorySource` of the name.
- D2: in a directory whose lookup sets `PATH` to `p`, `Process.prepared` of
  a command there gives the command with `PATH` set to `p` over the
  editor's environment, and nothing is said.
- D3: it is kept: a second prepare there, after the lookup's answer has
  changed with no stamp file touched, gives the old `p`; once the source's
  first stamp file there has changed, it gives the new one.
- D4: in a directory whose lookup fails, the command is prepared unchanged
  and the failure is said once, in `Process.failureMessage`'s words for
  that directory and source; a second prepare says nothing more.

## A base (`baseContract`)

- B1: the package registers a `BaseSource` of the name.
- B2: chosen by its name, a command in any directory gets the `PATH` its
  lookup sets, and nothing is said.
- B3: it is looked up once per run: after its answer has changed, a
  command in another directory keeps the old `PATH`; after an install, it
  gets the new one.
- B4: a failing base leaves commands unchanged and is said once, in
  `Process.failureMessage`'s words for the base, across two directories.
-/

namespace EnvironmentApiTest

open Editor

/-- What a directory source's check is handed: a directory of its own, where
the source's lookup answers as the rig set it up, and environments installed
from the source that every job of the scene shares. -/
structure DirectoryScene where
  /-- The directory, absolute. -/
  directory : System.FilePath
  /-- Runs `job` over the scene's environments, and whether it finished
  with `true`. -/
  run : JobM Bool → IO Bool
  /-- What the scene's environments have said so far, in order. -/
  said : IO (Array String)
  /-- From now on the lookup in the directory sets `PATH` to this, touching
  no stamp file. -/
  reanswer : String → IO Unit
  /-- Changes the source's first stamp file in the directory. -/
  restamp : IO Unit

/-- How a directory source's checks get their scenes. -/
structure DirectoryRig where
  /-- Runs the check in a scene whose lookup sets `PATH` to the given text,
  and ends the scene, whatever happened. -/
  answering : String → (DirectoryScene → IO Bool) → IO Bool
  /-- Runs the check in a scene whose lookup fails, with the failure it
  comes to, and ends the scene. -/
  failing : (DirectoryScene → Process.Failure → IO Bool) → IO Bool

/-- What a base's check is handed: two directories, environments installed
with the base chosen by its name, and the base's lookup answering as the rig
set it up. -/
structure BaseScene where
  /-- A directory a command starts in. -/
  directory : System.FilePath
  /-- Another one. -/
  other : System.FilePath
  /-- Runs `job` over the scene's environments, and whether it finished
  with `true`. -/
  run : JobM Bool → IO Bool
  /-- What the scene's environments have said so far, in order. -/
  said : IO (Array String)
  /-- From now on the base's lookup sets `PATH` to this. -/
  reanswer : String → IO Unit
  /-- Installs the layers again, as a reload that installs does. -/
  reinstall : IO Unit

/-- How a base's checks get their scenes. -/
structure BaseRig where
  /-- Runs the check in a scene whose base's lookup sets `PATH` to the given
  text, and ends the scene. -/
  answering : String → (BaseScene → IO Bool) → IO Bool
  /-- Runs the check in a scene whose base's lookup fails, with the failure
  it comes to, and ends the scene. -/
  failing : (BaseScene → Process.Failure → IO Bool) → IO Bool

/-- The values `package` registers at the extension point `α`, in order. -/
def registeredAt (α : Type) [TypeName α] (package : Package) : Array α :=
  package.registered.extensions.filterMap fun (key, value) =>
    if key == TypeName.typeName α then value.get? α else none

/-- The command the checks prepare in `directory`: an absolute program with
no environment of its own. -/
def child (directory : System.FilePath) : Process.Command :=
  { program := "/bin/sh", arguments := #["-c", "exit 0"], directory }

/-- `child directory` as it is prepared under a lookup that set `PATH` to
`path`: that over the editor's environment. -/
def childWithPath (directory : System.FilePath) (path : String) : Process.Command :=
  { child directory with environment := { clear := false, set := #[("PATH", path)] } }

/-- Whether `child directory` is prepared as `expected` in `scene`'s job. -/
def preparesAs (run : JobM Bool → IO Bool) (directory : System.FilePath)
    (expected : Process.Command) : IO Bool :=
  run do
    return (← Process.prepared (child directory)) == expected

/-- The `PATH` the checks' lookups set first. -/
def firstPath : String :=
  "/contract/first/bin:/usr/bin:/bin"

/-- The `PATH` the checks' lookups set once their answer has changed. -/
def secondPath : String :=
  "/contract/second/bin:/usr/bin:/bin"

/-- The contract of the directory source `name` that `package` registers,
over `rig` (the module docs, D1 to D4). -/
def directoryContract (package : Package) (name : String) (rig : DirectoryRig) :
    List (String × IO Bool) :=
  [(s!"D1: the package registers a directory source named {name}",
      pure ((registeredAt EnvironmentApi.DirectorySource package).any (·.name == name))),
    (s!"D2: in a directory whose lookup sets PATH, {name} prepares a command there with that PATH over the editor's environment, and says nothing",
      rig.answering firstPath fun scene => do
        let prepared ←
          preparesAs scene.run scene.directory (childWithPath scene.directory firstPath)
        return prepared && (← scene.said).isEmpty),
    (s!"D3: {name}'s result is kept: after its answer changes with no stamp file touched a second prepare gives the old PATH, and once its first stamp file changes the new one",
      rig.answering firstPath fun scene => do
        let first ← preparesAs scene.run scene.directory (childWithPath scene.directory firstPath)
        scene.reanswer secondPath
        let kept ← preparesAs scene.run scene.directory (childWithPath scene.directory firstPath)
        scene.restamp
        let renewed ←
          preparesAs scene.run scene.directory (childWithPath scene.directory secondPath)
        return first && kept && renewed && (← scene.said).isEmpty),
    (s!"D4: in a directory whose lookup fails, {name} prepares the command unchanged and says the failure once for the directory and source; a second prepare says nothing more",
      rig.failing fun scene failure => do
        let once ← preparesAs scene.run scene.directory (child scene.directory)
        let saidOnce ← scene.said
        let twice ← preparesAs scene.run scene.directory (child scene.directory)
        return once && twice &&
            saidOnce == #[Process.failureMessage (.directory scene.directory name) failure] &&
            (← scene.said) == saidOnce)]

/-- The contract of the base `name` that `package` registers, over `rig`
(the module docs, B1 to B4). -/
def baseContract (package : Package) (name : String) (rig : BaseRig) : List (String × IO Bool) :=
  [(s!"B1: the package registers a base named {name}",
      pure ((registeredAt EnvironmentApi.BaseSource package).any (·.name == name))),
    (s!"B2: chosen by its name, the base {name} gives a command in any directory the PATH its lookup sets, and says nothing",
      rig.answering firstPath fun scene => do
        let here ← preparesAs scene.run scene.directory (childWithPath scene.directory firstPath)
        let there ← preparesAs scene.run scene.other (childWithPath scene.other firstPath)
        return here && there && (← scene.said).isEmpty),
    (s!"B3: the base {name} is looked up once per run: after its answer changes a command in another directory keeps the old PATH, and after an install it gets the new one",
      rig.answering firstPath fun scene => do
        let first ← preparesAs scene.run scene.directory (childWithPath scene.directory firstPath)
        scene.reanswer secondPath
        let kept ← preparesAs scene.run scene.other (childWithPath scene.other firstPath)
        scene.reinstall
        let renewed ← preparesAs scene.run scene.other (childWithPath scene.other secondPath)
        return first && kept && renewed && (← scene.said).isEmpty),
    (s!"B4: a failing base {name} leaves commands in two directories unchanged and is said once",
      rig.failing fun scene failure => do
        let here ← preparesAs scene.run scene.directory (child scene.directory)
        let there ← preparesAs scene.run scene.other (child scene.other)
        return here && there && (← scene.said) == #[Process.failureMessage (.base name) failure])]

end EnvironmentApiTest
