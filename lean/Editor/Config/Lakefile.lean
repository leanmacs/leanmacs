/-!
# What a config's lakefile says of a module

A config file may import only modules that are linked into the editor
(`Editor/Config/Session.lean`). When an import names a module that is not,
the diagnostic says more if the module belongs to a package the config's
lakefile requires: that package is not in the editor's package set, and
the set needs a rebuild with it. This module is the pure part of that
answer: which library a package's modules are under (`libraryRoot`), and
which of a lakefile's requires a module belongs to (`owner?`). The
`[[require]]` names themselves are read from the lakefile's text by an
adapter (`Editor/Config/Lakefile/Toml.lean`); nothing here reads a file,
so `model-test` pins it (`ModelTest.lakefileChecks`).

## The library of a package

A Lake package named `p` keeps its modules under `<P>`, `p` in upper camel
case: `greeting-loud` gives `GreetingLoud`. It is the rule the package-set
build finds a package's entry module by (`docs/design/packages.md`, "The
package set and its build"), which is Lake's own casing
(`Lake.toUpperCamelCase`): the name is cut at each `-` and `_`, and each
part's first letter is made a capital. `config-test` holds this copy to
Lake's (`ConfigTest.lakefileChecks`).
-/

namespace Editor.Config.Lakefile

/-- The library the modules of the Lake package `package` are under: the
name in upper camel case ("The library of a package", in the module
docs). -/
def libraryRoot (package : String) : String :=
  let parts := package.split fun character => character == '_' || character == '-'
  String.join (parts.map (·.copy.capitalize)).toList

/-- The first component of the module name `module`: `Greeting` of
`Greeting.Loud`. -/
def rootOf (module : String) : String :=
  (module.splitOn ".").headD ""

/-- The package of `required`, the names a lakefile requires, that
`module` belongs to: the first whose library (`libraryRoot`) is the
module's first component; none when it belongs to none. -/
def owner? (required : Array String) (module : String) : Option String :=
  required.find? fun package => libraryRoot package == rootOf module

end Editor.Config.Lakefile
