import Editor.InputScheme.Vim.Default
import Editor.Test.Linked.Shipped

/-!
# The linked test kit: the Vim scheme's host

`withVimHost`: a host made as the executable's hosts are made
(`withShippedHost`, `Editor/Test/Linked/Shipped.lean`), of the Vim scheme
that ships (`Vim.Default.scheme`). It is evil's: the one module of the
linked kit that names a module of evil, apart from the rest so that the
kit's shipped host names no scheme. It holds no checks of its own.

Published for a package's linked tests, in the namespace
`Editor.Test.Linked`, as the rest of the linked kit is. It moves with evil
into that package's linked test support when evil becomes a package, and a
linked test whose subject is not evil runs on `withShippedHost` with the
test scheme.
-/

namespace Editor.Test.Linked

open Editor

/-- Runs `check` against a host of the Vim scheme that ships
(`withShippedHost Vim.Default.scheme`, which says what the host is made
of and what each argument is). -/
def withVimHost (context : HostContext) (files : List (String × String)) (check : Session → IO Bool)
    (fileModel : Option FileModel := none) (realFiles : Bool := false)
    (workingDirectory : System.FilePath := "/") (home : Option System.FilePath := none)
    (packages : Array Package := context.packages) : IO Bool :=
  withShippedHost Vim.Default.scheme context files check fileModel realFiles workingDirectory home
    packages

end Editor.Test.Linked
