-- A config that calls the mise package's setting, `Mise.executable`, with an
-- absolute path, and the command `layers` of `config/init.lean`, which says
-- the base and the directory sources the installed registry gives through
-- `environment-api` (`EnvironmentApi.ofRegistry`) in the window mode (with
-- the home directory `/u`) and in the headless mode.

import Editor
import EnvironmentApi
import Mise

open Editor

/-- Where `program` runs its executable, for a person. -/
def programText : Process.Program → String
  | .at path => s!"at {path}"
  | .firstOf candidates .skip => s!"first of {", ".intercalate (candidates.toList.map toString)}, else skip"
  | .firstOf candidates .report => s!"first of {", ".intercalate (candidates.toList.map toString)}, else report"
  | .probed probes otherwise => s!"probed by {", ".intercalate (probes.toList.map fun probe => " ".intercalate (probe.command.program :: probe.command.arguments.toList))}, else {otherwise}"

/-- The base `registered` gives in the mode `host`: `inherited`, or its
source's name, where it is looked up and its program. -/
def baseText (registered : Process.Registered) (host : Process.Host) : String :=
  match (registered.sources host .inherited).base with
  | .inherited => "inherited"
  | .lookup source directory => s!"{source.name} in {directory}, {programText source.program}"

/-- The base and the directory sources `registered` gives in the mode `host`,
each source by name and program, or `none`. -/
def layersText (registered : Process.Registered) (host : Process.Host) : String :=
  let directories : String :=
    match (registered.sources host .inherited).directories.toList with
    | [] => "none"
    | sources => "; ".intercalate (sources.map fun (source : Process.Source) => s!"{source.name} {programText source.program}")
  s!"base {baseText registered host}; {directories}"

/-- Says the base and the directory sources the installed registry gives in
each mode, the base chosen as the host chooses it. -/
def layers : EditorM Unit := do
  let directories ← RegistryRequest.ask (.extensions (TypeName.typeName EnvironmentApi.DirectorySource))
  let bases ← RegistryRequest.ask (.extensions (TypeName.typeName EnvironmentApi.BaseSource))
  let valuesAt (key : Lean.Name) : Array Dynamic :=
    if key == TypeName.typeName EnvironmentApi.DirectorySource then directories
    else if key == TypeName.typeName EnvironmentApi.BaseSource then bases
    else #[]
  let wanted ← RegistryRequest.ask .environmentBase
  let (registered, _) := EnvironmentApi.ofRegistry valuesAt wanted
  message s!"window: {layersText registered (.window (some "/u"))} | headless: {layersText registered .headless}"

def setup : SetupM Unit := do
  command "layers" layers
  Mise.executable "/opt/mise"
