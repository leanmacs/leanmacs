import Editor.Package
import Editor.Test.AtPoint
import Editor.Test.Shipped
import EditorCore.EditorPackage

/-!
# Config tests: support: Shipped

The packages the config tests host as the default editor's: the core's
Lake package's (`EditorCore.EditorPackage.packages`), then the kit's
stand-ins for the default packages whose data the core keeps
(`Editor.Test.Shipped`, `Editor/Test/Shipped.lean`), so that a host made
of them registers what the default editor's does of that data. A test
whose subject is the core's list itself hosts that list alone. Shared by
several test modules; it holds no checks of its own.
-/

namespace ConfigTest

open Editor

/-- The packages of the core's Lake package, then the stand-ins for the
default packages `mode-line` and `languages`, which register the shipped
segments, and the `code` mode and the shipped languages. -/
def shippedPackages : Array Package :=
  EditorCore.EditorPackage.packages ++ Test.Shipped.packages

/-- `packages` completing at point through the core's test kit: a package
named as the kit's at-point package is left out, and the kit's
(`Test.AtPoint.package`, `Editor/Test/AtPoint.lean`) comes last, so a host
made of them registers no at-point command, source, job or use of the
package that ships, and the kit's commands. -/
def withKitAtPoint (packages : Array Package) : Array Package :=
  (packages.filter (·.name != Test.AtPoint.package.name)).push Test.AtPoint.package

end ConfigTest
