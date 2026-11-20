import Editor.Package
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

/-- The packages of the core's Lake package, then the stand-in for the
default package `languages`, which registers the `code` mode and the
shipped languages. -/
def shippedPackages : Array Package :=
  EditorCore.EditorPackage.packages ++ #[Test.Shipped.languages]

end ConfigTest
