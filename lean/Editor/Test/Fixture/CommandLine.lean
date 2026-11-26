/-!
# The headless fixture harness: its command line

`fixture-test`, a package set's fixture harness (`lean/lakefile.lean`,
`editorFixtures`), read: the Lean toolchain's directory and the `.olean`
directories, joined with `:`, as the editor is handed them, the
repository's root, and what to do:

- `run <root>...`: discover the fixtures of each root and run each
  stepped.

Pure: model-test pins it (`ModelTest/Editor/Test/Fixture/CommandLine.lean`).
-/

namespace Editor.Test.Fixture

/-- What the harness is asked to do. -/
inductive Command where
  /-- Run the fixtures of these discovery roots. -/
  | run (roots : Array String)
  deriving DecidableEq, Repr

/-- The harness's command line, read. -/
structure Invocation where
  /-- The Lean toolchain's directory. -/
  sysroot : String
  /-- The `.olean` directories, joined with `:`. -/
  oleans : String
  /-- The repository's root. -/
  repository : String
  /-- What to do. -/
  command : Command
  deriving DecidableEq, Repr

/-- The harness's usage. -/
def usage : String :=
  "fixture-test <sysroot> <olean dirs> --repo <repository> run <root>..."

/-- The command line `arguments` read, or why it cannot be. -/
def read (arguments : List String) : Except String Invocation :=
  match arguments with
  | sysroot :: oleans :: "--repo" :: repository :: rest =>
    let command : Except String Command :=
      match rest with
      | "run" :: root :: roots => .ok (.run (root :: roots).toArray)
      | ["run"] => .error "run names no discovery root"
      | [] => .error "no command"
      | command :: _ => .error s!"{command} is no command"
    command.map ({ sysroot, oleans, repository, command := · })
  | [] => .error ""
  | _ => .error "expected <sysroot> <olean dirs> --repo <repository> first"

end Editor.Test.Fixture
