import ConfigTest.Check
import ConfigTest.Support.Shipped
import Editor.Test.Linked.Shipped

/-!
# Config tests: support: Syntax

The Rust objects' text the syntax checks read. The real syntax tree binding
in a host, its recorded requests, the faces of the library's shipped
highlights and a host of the Vim scheme that ships (`withVimHost`) are the
linked kit's (`Editor/Test/Linked/Shipped.lean`). Shared by several test
modules; it holds no checks of its own.
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- The Rust text of `rustObjectsConfig`: a method in an `impl`, after a
unit struct. -/
def rustObjectsText : String :=
  "struct S;\n\nimpl S {\n    fn one(&self) -> u8 {\n        let x = 1;\n        x\n    }\n}\n"

end ConfigTest
