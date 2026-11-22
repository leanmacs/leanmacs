import ConfigTest.Check
import Editor.Test.Linked.Host
import ExtensionFixture

/-!
# Config tests: `Editor/Extension.lean`

The tests of `Editor/Extension.lean` against the real elaborator:
`extensionChecks`, config elaborated by the running editor registering at
an extension point a compiled package declares and reads
(`ExtensionFixture.lean`). The root module `ConfigTest` runs them; its
module doc says what each shows. What the model tests cannot show is that
a value made by Lean's interpreter travels through the compiled `Dynamic`
and comes back typed, with its interpreted program run by compiled code.
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- A config that imports the fixture and registers at its extension point
a greeter called `from-config`, which says `config greets`. -/
def greeterConfig : String :=
  importing ["ExtensionFixture"]
    "def setup : SetupM Unit :=\n  Extension.add ({ name := \"from-config\", greet := message \"config greets\" } : ExtensionFixture.Greeter)\n"

/-- The same config with no registration. -/
def noGreeterConfig : String :=
  importing ["ExtensionFixture"] "def setup : SetupM Unit := pure ()\n"

/-- What a host is handed: the fixture's compiled package. -/
def extensionCompiled : Compiled :=
  { packages := #[ExtensionFixture.package] }

/-- The checks of extension points with the real elaborator: config
elaborated at runtime registers at a compiled package's point, and a reload
replaces config's value and keeps the package's. -/
def extensionChecks (context : Context) : List Check :=
  [{  name :=
        "a config elaborated at runtime registers at an extension point a compiled package reads, and the compiled package runs the value's program"
      run :=
        withHost context [("init.lean", greeterConfig)]
          (fun session => do
            session.ask [.reload]
            session.ask [.run "greeter-names"]
            let names ← session.echo
            session.ask [.run "greet-config"]
            let greeted ← session.echo
            return names == "compiled, from-config".quote && greeted == "config greets".quote)
          extensionCompiled },
    { name :=
        "a reload at runtime replaces config's value at an extension point and keeps the compiled package's"
      run :=
        withHost context [("init.lean", greeterConfig)]
          (fun session => do
            session.ask [.reload]
            session.write "init.lean" noGreeterConfig
            session.ask [.reload]
            session.ask [.run "greeter-names"]
            let names ← session.echo
            session.ask [.run "greet-config"]
            let greeted ← session.echo
            return names == "compiled".quote &&
                greeted == "no greeter from-config is registered".quote)
          extensionCompiled },
    { name :=
        "a compiled package's job over an extension point is made, when it is started, from config's value, elaborated at runtime, after the package's"
      run :=
        withHost context [("init.lean", greeterConfig)]
          (fun session => do
            session.ask [.reload]
            session.ask [.spawn "greeter-job"]
            let joined ← session.join
            let named ← session.echo
            return joined == .settled && named == "job sees compiled, from-config".quote)
          extensionCompiled }]

end ConfigTest
