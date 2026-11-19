import Editor
import Editor.Main
import EditorCore.EditorPackage

/-!
# The executable's root

One call: `Editor.Main.run` (`Editor/Main.lean`), handed the packages of the
core's Lake package (`EditorCore/EditorPackage.lean`). It names the
packages and holds nothing of the executable's body, which is the shape of
the root the package-set build generates from a set's entry modules
(`docs/design/packages.md`, "The package set and its build"); that root
replaces this file.

It imports the config base, `Editor` (`Editor.lean`), for the link alone:
the elaborator adapter the hosts bring imports the base's modules from
their `.olean` files at runtime, and each must already be linked into the
executable (`Editor/Main.lean`, "This module names no package, and not the
config base").
-/

/-- The executable: `Editor.Main.run` with the packages of the core's Lake
package. -/
def main (args : List String) : IO UInt32 :=
  Editor.Main.run EditorCore.EditorPackage.packages args
