import Editor.Api
import Editor.Package

/-!
# The one module of the user-side link's fixture package

A package as small as one can be (`mise run user-link-check`;
`docs/design/lean-runtime.md`, "A link on the user's machine, measured"):
one command, written against the editor's API as a package's would be,
compiled on the machine that links it and offered to a host as a `Package`
(`lean/Editor/Package.lean`), as the editor's own features are.

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

/-- The package, `user-link`, as a host registers it: the one command,
`user-link-hello`, for the owner named after the package. -/
def package : Editor.Package :=
  { name := "user-link", setup := Editor.command "user-link-hello" hello }

end UserLinkFixture
