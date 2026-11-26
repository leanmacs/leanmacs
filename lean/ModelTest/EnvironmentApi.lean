import Editor.Config.Packages
import Editor.Extension
import Editor.Job
import Editor.Job.Model
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import EnvironmentApi
import EnvironmentApiTest.Contract
import EnvironmentApiTest.Fake
import EnvironmentApiTest.Model
import ModelTest.Check
import ModelTest.Support.Elaborator

/-!
# Model tests: `EnvironmentApi.lean`

`environmentRegistryChecks`, the interface library `environment-api`'s
reading rules and, on the process model, what nothing registered and a base
chosen by name come to; and `environmentApiChecks`, its fakes held to its
contract and the contract biting on sources that leave something out. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open EnvironmentApiTest

/-- What the checks compare of a directory source value: its name, and the
program and stamp names of its source in each mode. -/
def directoryShape (value : EnvironmentApi.DirectorySource) :
    String × Option (Process.Program × Array String) × Option (Process.Program × Array String) :=
  let shape (host : Process.Host) := (value.source host).map fun source => (source.program, source.stampNames)
  (value.name, shape .headless, shape (.window (some "/u")))

/-- The name of the base `base` gives in `host`: `inherited`, or its lookup's
source's name and directory. -/
def baseShape (base : Process.Host → Process.Base) (host : Process.Host) : String :=
  match base host with
  | .inherited => Process.inheritedName
  | .lookup source directory => s!"{source.name} in {directory}"

/-- The command the registry checks start in `/p/d`, with an environment of
its own. -/
def registryChild : Process.Command :=
  { program := "/bin/build", arguments := #["all"], directory := "/p/d"
    environment := { set := #[("A", "own")] } }

/-- The checks of `environment-api`'s reading rules
(`EnvironmentApi.lean`): the hook's replace-in-place, the choice by name
with the core's `inherited`, `registered`, and, on the process model, a
child with nothing registered and with a base chosen by the setting. -/
def environmentRegistryChecks : List Check :=
  [{  name :=
        "the directory-source hook keeps registration order, and a later value of a name replaces the earlier in its place"
      run :=
        let a := fakeDirectory "a" "/bin/a"
        let b := fakeDirectory "b" "/bin/b"
        let a' := fakeDirectory "a" "/bin/a-again"
        pure
          ((EnvironmentApi.DirectorySource.ordered #[a, b, a']).map directoryShape ==
              #[directoryShape a', directoryShape b] &&
            (EnvironmentApi.DirectorySource.ordered #[b, a]).map (·.name) == #["b", "a"]) },
    { name :=
        "the base choice: inherited with nothing registered, the latest value of a name, and a name nobody answers to refused with the bases listed, inherited first"
      run :=
        let x := fakeBase "x" "/bin/x"
        let y := fakeBase "y" "/bin/y"
        let y' := fakeBase "y" "/bin/y" "/again"
        let chosen (values : Array EnvironmentApi.BaseSource) (wanted : String) : Option String :=
          (EnvironmentApi.BaseSource.choose values wanted).toOption.map (baseShape · .headless)
        pure
          (chosen #[] Process.inheritedName == some Process.inheritedName &&
            ((EnvironmentApi.BaseSource.choose #[] Process.inheritedName).toOption.map
                (baseShape · (.window (some "/u")))) ==
              some Process.inheritedName &&
            chosen #[x, y] "y" == some "y in /" &&
            chosen #[x, y, y'] "y" == some "y in /again" &&
            chosen #[x, fakeBase "inherited" "/bin/i"] "inherited" == some "inherited in /" &&
            (match EnvironmentApi.BaseSource.choose #[x] "nope" with
            | .error said => said == EnvironmentApi.unknownBase "nope" #["inherited", "x"]
            | .ok _ => false) &&
            EnvironmentApi.unknownBase "nope" #["inherited", "x"] ==
              "no base environment is named nope; the bases are inherited and x; children keep the base they had") },
    { name :=
        "registered: an unknown base name gives no base and the message; a known one a base and no message; the directory sources in the hook's order"
      run :=
        let (unknown, said) :=
          EnvironmentApi.registered #[fakeDirectory "a" "/bin/a"] #[fakeBase "x"] "nope"
        let (known, quiet) :=
          EnvironmentApi.registered #[fakeDirectory "a" "/bin/a"] #[fakeBase "x"] "x"
        let installed := ({} : Process.Environments).install known
        pure
          (unknown.base.isNone && said == some (EnvironmentApi.unknownBase "nope" #["inherited", "x"]) &&
            known.base.isSome &&
            quiet.isNone &&
            (match installed.sources.base with
            | .lookup source _ => source.name == "x"
            | .inherited => false) &&
            installed.sources.directories.map (·.name) == #["a"]) },
    { name :=
        "with nothing registered, a prepared child's environment is the editor's own: it starts exactly as its command says, no stamp is read, and only the policy request is made beyond the process request"
      run :=
        let model : JobModel :=
          { processes := { scripts := #[{ command := registryChild, reply := printed "built" }] }
            environments :=
              ({ host := .window (some "/u") } : Process.Environments).install
                (EnvironmentApi.ofRegistry (fun _ => #[]) Process.inheritedName).1 }
        pure
          ((after (runsOn registryChild) model).processes.started == #[registryChild] &&
            requestsOf (runsOn registryChild) model ==
              #[.environment .policy, .process (.run registryChild 1000)] &&
            (EnvironmentApi.ofRegistry (fun _ => #[]) Process.inheritedName).2.isNone) },
    { name :=
        "the base setting picks the registered base of that name: unset it is inherited and the child starts unchanged with no lookup; set to b, b's lookup runs and the child carries its PATH; a package's default a picks a, and config's b wins over it"
      run :=
        let bases : Package :=
          { name := "bases"
            setup := do
              Extension.add (fakeBase "a" "/bin/a")
              Extension.add (fakeBase "b" "/bin/b") }
        let defaultA : Package := { name := "default-a", setup := environmentBase "a" }
        let (state, _) : ModelState × Array String := Config.State.ofPackages #[bases]
        let (defaulted, _) : ModelState × Array String := Config.State.ofPackages #[bases, defaultA]
        let lookupOf (name : String) : Process.Command := { program := s!"/bin/{name}", directory := "/" }
        let carrying (name : String) : Process.Command :=
          { registryChild with environment := { set := #[("PATH", s!"/{name}/bin"), ("A", "own")] } }
        let modelOf (registry : Config.Registry) : JobModel :=
          { processes :=
              { scripts :=
                  #[{ command := lookupOf "a", reply := printed (linesOf #[("PATH", "/a/bin")]) },
                    { command := lookupOf "b", reply := printed (linesOf #[("PATH", "/b/bin")]) },
                    { command := registryChild, reply := printed "built" },
                    { command := carrying "a", reply := printed "built" },
                    { command := carrying "b", reply := printed "built" }] }
            environments :=
              ({} : Process.Environments).install
                (EnvironmentApi.ofRegistry registry.extensionsAt registry.baseName).1 }
        let unset := after (runsOn registryChild) (modelOf state.registry)
        let chosen :=
          after (runsOn registryChild)
            (modelOf { state.registry with environmentBase := some "b" })
        let overriding :=
          after (runsOn registryChild)
            (modelOf { defaulted.registry with environmentBase := some "b" })
        let byDefault := after (runsOn registryChild) (modelOf defaulted.registry)
        pure
          (unset.processes.started == #[registryChild] &&
            chosen.processes.started == #[lookupOf "b", carrying "b"] &&
            overriding.processes.started == #[lookupOf "b", carrying "b"] &&
            byDefault.processes.started == #[lookupOf "a", carrying "a"] &&
            [unset, chosen, overriding, byDefault].all (·.reported.isEmpty)) }]

/-- Whether every sentence of `contract` holds. -/
def contractHolds (contract : List (String × IO Bool)) : IO Bool :=
  contract.allM (·.2)

/-- Whether each sentence of `contract` whose label starts with one of
`labels` fails, and every other holds. -/
def contractFailsOn (contract : List (String × IO Bool)) (labels : List String) : IO Bool :=
  contract.allM fun (sentence, holds) => do
    let failing := labels.any (sentence.startsWith ·)
    return (← holds) != failing

/-- `value` with a source that ignores its output: it sets nothing. -/
def ignoringDirectory (value : EnvironmentApi.DirectorySource) : EnvironmentApi.DirectorySource :=
  { value with
    source := fun host => (value.source host).map fun source => { source with parse := fun _ => .ok #[] } }

/-- `value` with a lookup that ignores its output: it sets nothing. -/
def ignoringBase (value : EnvironmentApi.BaseSource) : EnvironmentApi.BaseSource :=
  { value with
    base := fun host =>
      match value.base host with
      | .lookup source directory => .lookup { source with parse := fun _ => .ok #[] } directory
      | .inherited => .inherited }

/-- A package named as the fake's that registers nothing. -/
def emptyEnvironmentPackage : Package :=
  { name := EnvironmentApiTest.fakePackage.name, setup := pure () }

/-- The checks of `environment-api`'s contract (`EnvironmentApiTest.Contract`):
its fakes keep it on the model rigs, and it bites on a package that
registers nothing and on sources that ignore their output. -/
def environmentApiChecks : List Check :=
  [{  name := "the fake directory source keeps the directory-source contract on the model rig"
      run :=
        contractHolds
          (directoryContract EnvironmentApiTest.fakePackage "fake-directory"
            (modelDirectoryRig fakeDirectory .headless linesOf)) },
    { name := "the fake base keeps the base contract on the model rig"
      run :=
        contractHolds
          (baseContract EnvironmentApiTest.fakePackage "fake-base" (modelBaseRig fakeBase .headless linesOf)) },
    { name :=
        "the directory-source contract bites: a package that registers nothing fails D1, and a source that ignores its output fails D2 and D3, the rest holding"
      run := do
        let empty ←
          contractFailsOn
            (directoryContract emptyEnvironmentPackage "fake-directory"
              (modelDirectoryRig fakeDirectory .headless linesOf))
            ["D1"]
        let ignoring ←
          contractFailsOn
            (directoryContract EnvironmentApiTest.fakePackage "fake-directory"
              (modelDirectoryRig (ignoringDirectory fakeDirectory) .headless linesOf))
            ["D2", "D3"]
        return empty && ignoring },
    { name :=
        "the base contract bites: a package that registers nothing fails B1, and a base that ignores its output fails B2 and B3, the rest holding"
      run := do
        let empty ←
          contractFailsOn
            (baseContract emptyEnvironmentPackage "fake-base" (modelBaseRig fakeBase .headless linesOf))
            ["B1"]
        let ignoring ←
          contractFailsOn
            (baseContract EnvironmentApiTest.fakePackage "fake-base"
              (modelBaseRig (ignoringBase fakeBase) .headless linesOf))
            ["B2", "B3"]
        return empty && ignoring }]

end ModelTest
