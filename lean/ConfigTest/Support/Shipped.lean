import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Key.Notation
import Editor.Package
import Editor.Test.AtPoint
import Editor.Test.Editing
import Editor.Test.Linked.Shipped
import Editor.Test.Minibuffer
import Editor.Test.Shipped
import FilesApiTest.Fake

/-!
# Config tests: support: Shipped

The packages the config tests host as the default editor's: the kit's
stand-ins for the default packages whose data the core keeps
(`Editor.Test.Shipped`, `Editor/Test/Shipped.lean`), so that a host made
of them registers what the default editor's does of that data, then the
kit's at-point package (`Editor.Test.AtPoint`, `Editor/Test/AtPoint.lean`),
so that insert state's `RET`, `TAB` and `C-g`, which the Vim scheme binds
to completion at point's commands, type and quit as the default editor's
do, then the kit's minibuffer (`Editor.Test.Minibuffer`,
`Editor/Test/Minibuffer.lean`), so that a prompt is answered, and its
candidates that answer later taken, as the default editor's are. The
core's Lake package registers no package of its own, so the list holds
none of it. And the host
of the test scheme the config tests type on (`withTestHost`, stepped, and
`withRealSyntaxTestHost`, on a loop thread of its own over the library's
syntax service), with that
scheme's leader as a key string (`schemeLeader`). Shared by
several test modules; it holds no checks of its own.
-/

namespace ConfigTest

open Editor

/-- `files-api`'s fake
(`FilesApiTest.fake`), which opens and saves files in place of the default
package `files`, then the stand-ins for the default packages `mode-line`
and `languages`, which register the shipped
segments, and the `code` mode and the shipped languages, then the kit's
implementations of the default packages `at-point`'s and `minibuffer`'s
commands. -/
def shippedPackages : Array Package :=
  #[FilesApiTest.fake] ++ Test.Shipped.packages ++ #[Test.AtPoint.package, Test.Minibuffer.package]

/-- `packages` completing at point through the core's test kit: a package
named as the kit's at-point package is left out, and the kit's
(`Test.AtPoint.package`, `Editor/Test/AtPoint.lean`) comes last, so a host
made of them registers no at-point command, source, job or use of the
package that ships, and the kit's commands. -/
def withKitAtPoint (packages : Array Package) : Array Package :=
  (packages.filter (·.name != Test.AtPoint.package.name)).push Test.AtPoint.package

/-- The test scheme's leader as a key string (`InputScheme.leaders`), read
from the scheme, so no check names its key. -/
def schemeLeader : String :=
  Key.notations TestScheme.scheme.leaders.leader

/-- Runs `check` against a host of the test scheme made as the executable's
hosts are made (`Editor.Test.Linked.withShippedHost TestScheme.scheme`,
which says what the host is made of and what each argument is), handed
`packages` and then the kit's editing commands and keys
(`Test.editingPackage`, `Editor/Test/Editing.lean`), so that a printable
key types its character and the keys that print nothing move and edit: the
host a config test whose subject is no scheme's keys runs on, over a
stepped stage (`Stage.stepped`). -/
def withTestHost (context : Test.Linked.HostContext) (files : List (String × String))
    (check : Test.Linked.Session → IO Bool) (fileModel : Option FileModel := none)
    (workingDirectory : System.FilePath := "/") (home : Option System.FilePath := none)
    (packages : Array Package := context.packages)
    (emitting : (String → IO Unit) → String → IO Unit := id) : IO Bool :=
  Test.Linked.withShippedHost TestScheme.scheme context files check fileModel workingDirectory home
    (packages.push Test.editingPackage) emitting

/-- `withRealSyntaxTestHost` is an inferred wait (`Editor/InferredWait.lean`):
its host's syntax tree is the real binding (`withRealSyntaxHost`). -/
def withRealSyntaxTestHost.inferredWait : InferredWait :=
  .realEffect []

-- inferred-waits W89: stays (A5: the library's syntax service, whose deliveries come over its own queue, is the subject of this host's checks)
set_option linter.inferredWait false in
/-- `withTestHost` with a real host, on a loop thread of its own, and the
real syntax tree binding over the library's
syntax service (`Editor.Test.Linked.withRealSyntaxHost`): for a check whose
subject is the library's syntax service (A5). -/
def withRealSyntaxTestHost (context : Test.Linked.HostContext) (files : List (String × String))
    (check : Test.Linked.RealSession → IO Bool) (fileModel : Option FileModel := none)
    (workingDirectory : System.FilePath := "/") (home : Option System.FilePath := none)
    (packages : Array Package := context.packages)
    (emitting : (String → IO Unit) → String → IO Unit := id) : IO Bool :=
  Test.Linked.withRealSyntaxHost TestScheme.scheme context files check fileModel workingDirectory
    home (packages.push Test.editingPackage) emitting

end ConfigTest
