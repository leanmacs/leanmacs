-- A config that sets nothing of a child's environment, and its command
-- `layers`, which says the directory sources the installed registry gives
-- through `environment-api` (`EnvironmentApi.ofRegistry`), as the host
-- reads them at a reload that installs, in the window mode (with the home
-- directory `/u`) and in the headless mode. It imports no package, so on a
-- set without the mise package it still loads, and says `none` for both.

import Editor
import EnvironmentApi

open Editor

/-- Where `program` runs its executable, for a person. -/
def programText : Process.Program → String
  | .at path => s!"at {path}"
  | .firstOf candidates .skip => s!"first of {", ".intercalate (candidates.toList.map toString)}, else skip"
  | .firstOf candidates .report => s!"first of {", ".intercalate (candidates.toList.map toString)}, else report"

/-- The directory sources `registered` gives in the mode `host`, by name and
program, or `none`. -/
def layersText (registered : Process.Registered) (host : Process.Host) : String :=
  match (registered.sources host .inherited).directories.toList with
  | [] => "none"
  | sources => "; ".intercalate (sources.map fun source => s!"{source.name} {programText source.program}")

/-- Says the directory sources the installed registry gives in each mode. -/
def layers : EditorM Unit := do
  let directories ← RegistryRequest.ask (.extensions (TypeName.typeName EnvironmentApi.DirectorySource))
  let bases ← RegistryRequest.ask (.extensions (TypeName.typeName EnvironmentApi.BaseSource))
  let valuesAt (key : Lean.Name) : Array Dynamic :=
    if key == TypeName.typeName EnvironmentApi.DirectorySource then directories
    else if key == TypeName.typeName EnvironmentApi.BaseSource then bases
    else #[]
  let (registered, _) := EnvironmentApi.ofRegistry valuesAt Process.inheritedName
  message s!"window: {layersText registered (.window (some "/u"))} | headless: {layersText registered .headless}"

def setup : SetupM Unit := do
  command "layers" layers
