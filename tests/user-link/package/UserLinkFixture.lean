import Editor.Api
import Editor.Config.Registry

/-!
# The one module of the user-side link's fixture package

A package as small as one can be (`mise run user-link-check`;
`docs/design/lean-runtime.md`, "A link on the user's machine, measured"):
one command, written against the editor's API as a package's would be,
compiled on the machine that links it and offered to a host as a
registration, as the editor's own compiled commands are
(`lean/Editor/Config/Registry.lean`, "Compiled commands").

It imports the editor's modules from their `.olean` files alone: nothing of
the editor is compiled when this package builds.
-/

namespace UserLinkFixture

/-- What `user-link-hello` says in the echo area. -/
def greeting : String :=
  "hello from a package linked on this machine"

/-- The package's command: it says `greeting` in the echo area. -/
def hello : Editor.EditorM Unit :=
  Editor.message greeting

/-- The command, as a host registers it for the owner `compiled`. -/
def commands : Array Editor.Config.Registration :=
  #[{ name := "user-link-hello", action := .plain hello }]

end UserLinkFixture
