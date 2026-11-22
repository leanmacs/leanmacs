import Editor.Api

/-!
A package of the fixture for the module map check's reading of the sources
(tools/module-map-check.sh, with --points). Four readers read both of the
compile mode's points, so all four count the same two reads of a package.
Each is therefore alone in a package of the fixture: this one holds the
hook's reader, and without that reader's rule the map names two reads this
package's sources lack. The packages compile-listings, compile-markers and
compile-work hold the other three.
-/

namespace CompileHook

def settings (identity : String) (mode : Name) : EditorM Settings := do
  return (← Compile.hook).settingsOf identity mode

end CompileHook
