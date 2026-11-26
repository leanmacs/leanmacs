import Editor.Extension
import Editor.Process.Environment

/-!
# The interface library `environment-api`

The interface library `environment-api`, staged in the core's Lake package
as its own `lean_lib` with the layout and names an interface package has
(`lean/lakefile.lean`, `lean_lib EnvironmentApi`), as `files-api` is: the
contract between the core, which builds a child's environment in layers
(`Editor/Process/Environment.lean`, `Process.prepared` in
`Editor/Job.lean`), and the packages that give it sources, the default
package `mise` (`packages/mise/`) first. It imports only the core's API, and
its test library (`EnvironmentApiTest`) only that, this library and the
core's test kit. The core reads it at every reload that installs, so it is a
core interface for good: a source is a package, and the core names none.

## Its extension points

- **`DirectorySource`, a hook**: every value applies, in registration
  order, each a layer looked up for the child's directory over the layers
  before it. A later value of a name already registered replaces the
  earlier one in its place (`DirectorySource.ordered`): so config's value of
  the name `mise` (the mise package's setting, `Mise.executable`) replaces
  the package's own where the package put it. A value's source is given for
  each mode, and `none` leaves it out in that mode (mise looks nothing up in
  the headless mode).
- **`BaseSource`, a choice by name**: the base under every directory source,
  chosen by the core's setting `environmentBase` (`Editor/Setup.lean`;
  config's choice, else the latest package's default, else `inherited`,
  `Config.Registry.baseName`). The core's own base, launchd's environment
  with no lookup, answers to `inherited` (`Process.inheritedName`) unless a
  package registers a base of that name; of two values of one name the
  latest wins (`BaseSource.choose`). A name nothing answers to refuses
  the config at reload with `unknownBase`, which lists the bases there
  are, and children keep the base they had.

## Who reads them

The host, at every reload that installs (`Editor/Headless.lean`, "A
child's environment"): it reads the registry it was handed through
`ofRegistry` (the values `Config.Registry.extensionsAt` gives, the data
`RegistryRequest.extensions` is answered from) and installs the layers in
the environments every job shares (`Job.Environments.install`). A running
job cannot ask the registry (`docs/design/extension-points.md`, "To a job"),
so `Process.prepared` reads what was installed (`EnvironmentRequest.policy`).
The reload reducer reads it first (`Config.State.install`), and rejects a
config whose registry names a base nothing answers to, with `unknownBase` as
its error (`Config.Report.baseRefused`), so the host only ever installs a
known base. With nothing registered a
child gets the editor's own environment, and no lookup runs.

## Where an addition goes

- **A new directory source** (direnv, a project's `.env`): a package that
  registers a `DirectorySource`.
- **A new base** (a login shell): a package that registers a `BaseSource`,
  and, to be the default, calls `environmentBase` with its name in its
  `setup` (a package's `environmentBase` is a default, which config's
  overrides).
- **A new kind of data a source carries** (how its executable is found,
  what its lookup runs, how its output is read): a field of `Process.Source`
  in the core.
- **A new question a job asks** of the environments: a constructor of
  `EnvironmentRequest` in the core.

## Where each rule is pinned

- The reading rules (`ordered`, `choose`, `registered`, `ofRegistry`) and,
  on the process model, what nothing registered and a chosen base come to:
  `ModelTest.environmentRegistryChecks`.
- The contract every real source runs, `EnvironmentApiTest.directoryContract`
  and `EnvironmentApiTest.baseContract`: on this library's fakes by
  `ModelTest.environmentApiChecks`, and against real processes by each real
  source's own linked test (mise's: `MiseTest.Linked.Mise.Contract`).
- The host's wiring, once: `ConfigTest.environmentHostChecks`, over the
  headless host and the real elaborator.
- The default set's wiring, once: the standing fixture
  `tests/headless/environment-sources`, on the default set's fixture
  harness, reads the installed registry through `ofRegistry` (mise's
  source alone, in the window mode; none in the headless mode; config's
  `Mise.executable` in its place).

Its test library publishes the fakes (`EnvironmentApiTest.fakeDirectory`,
`fakeBase`, `fakePackage`), the contract, and model rigs a package's model
tests run the contract on (`EnvironmentApiTest.modelDirectoryRig`,
`modelBaseRig`).
-/

namespace EnvironmentApi

open Editor

/-- A directory source: a hook ("Its extension points", in the module docs).
Every value applies, in registration order; a later value of a name replaces
the earlier in its place. -/
structure DirectorySource where
  /-- The value's name, which a later value of the same name replaces it by. -/
  name : String
  /-- The source in the mode `host`, or `none` for no lookup in that mode. -/
  source : Process.Host → Option Process.Source
  deriving TypeName

/-- A base source: a choice by name (`environmentBase`), beside the core's
built-in `inherited`. -/
structure BaseSource where
  /-- The name `environmentBase` chooses it by. -/
  name : String
  /-- The base in the mode `host`: a lookup, or `.inherited` where it looks
  nothing up. -/
  base : Process.Host → Process.Base
  deriving TypeName

/-- `values` in registration order, a later value of a name already seen
replacing the earlier one in its place: the hook's rule. -/
def DirectorySource.ordered (values : Array DirectorySource) : Array DirectorySource :=
  values.foldl
    (fun kept value =>
      match kept.findIdx? (·.name == value.name) with
      | some index => kept.set! index value
      | none => kept.push value)
    #[]

/-- The names of the bases there are, for a person: `inherited` first, then
each registered name in order, each once. -/
def baseNames (values : Array BaseSource) : Array String :=
  values.foldl
    (fun names value => if names.contains value.name then names else names.push value.name)
    #[Process.inheritedName]

/-- `names`, written as a list for a person: `a`, `a and b`, `a, b and c`. -/
def listedNames (names : Array String) : String :=
  match names.toList.reverse with
  | [] => "none"
  | [only] => only
  | last :: rest => ", ".intercalate rest.reverse ++ " and " ++ last

/-- What is said of a base chosen as `wanted` that no base answers to, when
the bases there are are `names` (`baseNames`). -/
def unknownBase (wanted : String) (names : Array String) : String :=
  s!"no base environment is named {wanted}; the bases are {listedNames names}; children keep the base they had"

/-- The base named `wanted` among `values`: the latest value of that name;
the core's `inherited` when that is the name and no value has it; and
otherwise why not (`unknownBase`). -/
def BaseSource.choose (values : Array BaseSource) (wanted : String) :
    Except String (Process.Host → Process.Base) :=
  match values.findRev? (·.name == wanted) with
  | some value => .ok value.base
  | none =>
    if wanted == Process.inheritedName then .ok fun _ => .inherited
    else .error (unknownBase wanted (baseNames values))

/-- The layers `directories` and the base named `wanted` among `bases` give,
as the host installs them, and what is to be said of the base: a name no base
answers to gives no base, so the one installed before is kept, and the
message. -/
def registered (directories : Array DirectorySource) (bases : Array BaseSource) (wanted : String) :
    Process.Registered × Option String :=
  let directories := (DirectorySource.ordered directories).map (·.source)
  match BaseSource.choose bases wanted with
  | .ok base => ({ base := some base, directories }, none)
  | .error message => ({ base := none, directories }, some message)

/-- `registered` over the values a registry holds at each extension point
(`valuesAt`, as `Config.Registry.extensionsAt` gives them), with the base
named `wanted`. -/
def ofRegistry (valuesAt : Lean.Name → Array Dynamic) (wanted : String) :
    Process.Registered × Option String :=
  let directories :=
    (valuesAt (TypeName.typeName DirectorySource)).filterMap (·.get? DirectorySource)
  let bases := (valuesAt (TypeName.typeName BaseSource)).filterMap (·.get? BaseSource)
  registered directories bases wanted

end EnvironmentApi
