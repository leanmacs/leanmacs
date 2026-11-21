import Editor.Package
import Editor.Test.AtPoint
import Editor.Test.Minibuffer
import Editor.Test.Shipped
import EditorCore.EditorPackage
import FilesApiTest.Fake

/-!
# Config tests: support: Shipped

The packages the config tests host as the default editor's: the core's
Lake package's (`EditorCore.EditorPackage.packages`), then the kit's
stand-ins for the default packages whose data the core keeps
(`Editor.Test.Shipped`, `Editor/Test/Shipped.lean`), so that a host made
of them registers what the default editor's does of that data, then the
kit's at-point package (`Editor.Test.AtPoint`, `Editor/Test/AtPoint.lean`),
so that insert state's `RET`, `TAB` and `C-g`, which the Vim scheme binds
to completion at point's commands, type and quit as the default editor's
do, then the kit's minibuffer (`Editor.Test.Minibuffer`,
`Editor/Test/Minibuffer.lean`), so that a prompt is answered, and its
candidates that answer later taken, as the default editor's are. A test
whose subject is the core's list itself hosts that list alone. Shared by
several test modules; it holds no checks of its own.
-/

namespace ConfigTest

open Editor

/-- The packages of the core's Lake package, then `files-api`'s fake
(`FilesApiTest.fake`), which opens and saves files in place of the default
package `files`, then the stand-ins for the default packages `mode-line`
and `languages`, which register the shipped
segments, and the `code` mode and the shipped languages, then the kit's
implementations of the default packages `at-point`'s and `minibuffer`'s
commands. -/
def shippedPackages : Array Package :=
  EditorCore.EditorPackage.packages ++ #[FilesApiTest.fake] ++ Test.Shipped.packages ++
    #[Test.AtPoint.package, Test.Minibuffer.package]

/-- `packages` completing at point through the core's test kit: a package
named as the kit's at-point package is left out, and the kit's
(`Test.AtPoint.package`, `Editor/Test/AtPoint.lean`) comes last, so a host
made of them registers no at-point command, source, job or use of the
package that ships, and the kit's commands. -/
def withKitAtPoint (packages : Array Package) : Array Package :=
  (packages.filter (·.name != Test.AtPoint.package.name)).push Test.AtPoint.package

end ConfigTest
