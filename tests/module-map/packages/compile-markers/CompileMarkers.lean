import Editor.Api

/-!
A package of the fixture for the module map check's reading of the sources
(tools/module-map-check.sh, with --points). It holds the one call that
asks for the settings the markers give, a reader of both of the compile
mode's points, and nothing else that reads them (the package compile-hook
says why).
-/

namespace CompileMarkers

open Workspace in
def generation : EditorM Nat := do
  let (settings, generation) ← markerSettings
  return generation

end CompileMarkers
