import Editor.RealHost
import Editor.Test.Linked.Shipped
import Evil.Vim.Default

/-!
# Evil's linked tests: support: the Vim scheme's host

`withVimHost`: a host made as the executable's hosts are made
(`withShippedHost`, the linked kit's, `Editor/Test/Linked/Shipped.lean`), of
the Vim scheme that ships (`Vim.Default.scheme`), stepped on the check's own
thread; `withRealVimHost` is the same host on a loop thread of its own
(`withRealSyntaxHost`). It holds no checks of its own.

It was a module of the core's linked kit, `Editor.Test.Linked.Vim`, the one
that named a module of evil, until the features-as-packages roadmap's phase
7 moved it here with evil; its declaration keeps its namespace,
`Editor.Test.Linked`. A linked test whose subject is not evil runs on
`withShippedHost` with the test scheme.
-/

namespace Editor.Test.Linked

open Editor

/-- Runs `check` against a host of the Vim scheme that ships, stepped on the
check's own thread (`withShippedHost Vim.Default.scheme`, which says what
the host is made of and what each argument is). -/
def withVimHost (context : HostContext) (files : List (String × String)) (check : Session → IO Bool)
    (fileModel : Option FileModel := none) (workingDirectory : System.FilePath := "/")
    (home : Option System.FilePath := none) (packages : Array Package := context.packages)
    (emitting : (String → IO Unit) → String → IO Unit := id) : IO Bool :=
  withShippedHost Vim.Default.scheme context files check fileModel workingDirectory home packages
    emitting

/-- The mark of `withRealVimHost`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def withRealVimHost.realHost : Editor.RealHost :=
  .loop

-- inferred-waits W87: stays (A5: evil's real-host checks are the Vim scheme over the library's shipped Rust textObjects and indents queries, which the syntax model does not hold)
set_option linter.inferredWait false in
/-- `withVimHost` with a real host and the real syntax binding, in its
bracket (`withRealSyntaxHost Vim.Default.scheme`), which returns once its
loop has ended, declaring the test grammars of `grammars`' directory, which
the check waits to see registered (`Session.testGrammarsRegistered`) before
it opens a buffer of one. -/
def withRealVimHost (context : HostContext) (grammars : TestGrammars)
    (files : List (String × String)) (check : RealSession → IO Bool)
    (fileModel : Option FileModel := none) (workingDirectory : System.FilePath := "/")
    (home : Option System.FilePath := none) (packages : Array Package := context.packages)
    (emitting : (String → IO Unit) → String → IO Unit := id) : IO Bool :=
  withRealSyntaxHost Vim.Default.scheme context grammars files check fileModel workingDirectory home
    packages emitting

end Editor.Test.Linked
