import Editor.Api

/-!
A package of the fixture for the module map check's reading of the sources
(tools/module-map-check.sh, with --points). It holds the one call that
checks the listings again, a reader of both of the compile mode's points,
and nothing else that reads them (the package compile-hook says why).
-/

namespace CompileListings

open Compile in
def check (place : Option Location) (modes : Array Workspace.OnMode) : EditorM Unit := do
  refreshListings place modes

end CompileListings
