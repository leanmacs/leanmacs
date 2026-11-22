import CompileApi
import Editor.Config.Packages

/-!
# The contract check of `compile-api`

What every package that registers at the interface's two extension points
runs over itself: each contribution it registers has a marker and names no
command twice, and the project commands it gives name no command twice.
`compileContribution` and `projectCommands` refuse a value that breaks
these, so a package that registers through them keeps the contract; the
check is for a package that registers a value at a point directly
(`Extension.add`), which no operation sees. It collects the package's
`setup` with the pure collector (`Package.collected`), so nothing is
registered in an editor.

It is a list of sentences, each with whether it holds, the shape the
fixture interface package `greeting-api` gives its own
(`tests/packages/greeting-api`), so that it needs nothing of an
implementation's test driver: a driver whose checks are of another type
turns each pair into one of its checks.
-/

namespace CompileApiTest

open Editor

/-- The values `package` registers at the extension point `α`, in order;
none when the package is refused. -/
def registeredAt (α : Type) [TypeName α] (package : Package) : Array α :=
  (Package.registered package).extensions.filterMap fun (key, value) =>
    if key == TypeName.typeName α then value.get? α else none

/-- The checks of the contract over `package`, each with what must hold as
a sentence. -/
def contractChecks (package : Package) : List (String × Bool) :=
  let contributions := registeredAt Compile.Contribution package
  let projects := registeredAt Compile.ProjectCommands package
  [(s!"`{package.name}` is not refused, so what it registers at `compile-api`'s points is installed",
      package.collected.toOption.isSome),
    (s!"every contribution `{package.name}` registers has a marker",
      contributions.all (!·.markers.isEmpty)),
    (s!"no contribution `{package.name}` registers names a command twice",
      contributions.all fun contribution =>
        (Compile.repeatedName? (contribution.commands.map (·.name))).isNone),
    (s!"no project commands `{package.name}` gives name a command twice",
      projects.all fun entry => (Compile.repeatedName? (entry.commands.map (·.name))).isNone)]

end CompileApiTest
