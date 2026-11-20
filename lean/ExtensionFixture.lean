import Editor.Api
import Editor.Extension
import Editor.Package

/-!
# An extension point and its reader, linked and imported at runtime

`config-test` imports this module, so it is compiled into that executable,
and the same process imports the module's `.olean` at runtime, as part of
the base config is elaborated on. It is laid out as an interface package
and an implementation package would be (`docs/design/extension-points.md`):
the extension point `Greeter`, and a compiled package, `package`, that
registers a greeter of its own and reads every greeter registered.

The checks that use it (`ConfigTest.extensionChecks`) show that config
elaborated by the running editor registers at this compiled point, that the
compiled package reads config's value typed and runs its interpreted
program, and that a reload replaces config's value and keeps the
package's.
-/

namespace ExtensionFixture

open Editor

/-- What greets: the extension point config registers at. -/
structure Greeter where
  /-- The greeter's name, which a choice finds it by. -/
  name : String
  /-- What it does when chosen. -/
  greet : EditorM Unit
  deriving TypeName

/-- A compiled package: it registers a greeter called `compiled`, and the
commands `greeter-names`, which says the names of every greeter registered,
in order and joined with `, `, in the echo area, and `greet-config`, which
runs the greeter called `from-config`, or says none is registered. -/
def package : Package :=
  { name := "extension-fixture"
    setup := do
      Extension.add ({ name := "compiled", greet := message "compiled greets" } : Greeter)
      command "greeter-names" do
          message (", ".intercalate ((← Extension.values Greeter).map (·.name)).toList)
      command "greet-config" do
          match ← Extension.named Greeter (·.name) "from-config" with
          | some greeter =>
            greeter.greet
          | none =>
            message "no greeter from-config is registered" }

end ExtensionFixture
